-- |
-- Module      : Network.TLS.Context
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
module Network.TLS.Context
	(
	-- * Context configuration
	  Params(..)
	, Logging(..)
	, SessionData(..)
	, Measurement(..)
	, CertificateUsage(..)
	, CertificateRejectReason(..)
	, defaultLogging
	, defaultParams

	-- * Context object and accessor
	, Backend(..)
	, Context
	, ctxParams
	, ctxConnection
	, ctxEOF
	, ctxEstablished
	, ctxLogging
	, setEOF
	, setEstablished
	, connectionFlush
	, connectionSend
	, connectionRecv
	, updateMeasure
	, withMeasure

	-- * deprecated types
	, TLSParams
	, TLSLogging
	, TLSCertificateUsage
	, TLSCertificateRejectReason
	, TLSCtx

	-- * New contexts
	, newCtxWith
	, newCtx

	-- * Using context states
	, throwCore
	, usingState
	, usingState_
	, getStateRNG
	) where

import Network.TLS.Struct
import Network.TLS.Cipher
import Network.TLS.Compression
import Network.TLS.Crypto
import Network.TLS.State
import Network.TLS.Measurement
import Data.Maybe
import Data.Certificate.X509
import Data.List (intercalate)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import Control.Concurrent.MVar
import Control.Monad.State
import Control.Exception (throwIO, Exception())
import Data.IORef
import System.IO (Handle, hSetBuffering, BufferMode(..), hFlush)
import Prelude hiding (catch)

data Logging = Logging
	{ loggingPacketSent :: String -> IO ()
	, loggingPacketRecv :: String -> IO ()
	, loggingIOSent     :: B.ByteString -> IO ()
	, loggingIORecv     :: Header -> B.ByteString -> IO ()
	}

data Params = Params
	{ pConnectVersion    :: Version             -- ^ version to use on client connection.
	, pAllowedVersions   :: [Version]           -- ^ allowed versions that we can use.
	, pCiphers           :: [Cipher]            -- ^ all ciphers supported ordered by priority.
	, pCompressions      :: [Compression]       -- ^ all compression supported ordered by priority.
	, pWantClientCert    :: Bool                -- ^ request a certificate from client.
	                                            -- use by server only.
	, pUseSecureRenegotiation :: Bool           -- notify that we want to use secure renegotation
	, pUseSession             :: Bool           -- generate new session if specified
	, pCertificates      :: [(X509, Maybe PrivateKey)] -- ^ the cert chain for this context with the associated keys if any.
	, pLogging           :: Logging             -- ^ callback for logging
	, onHandshake        :: Measurement -> IO Bool -- ^ callback on a beggining of handshake
	, onCertificatesRecv :: [X509] -> IO CertificateUsage -- ^ callback to verify received cert chain.
	, onSessionResumption :: SessionID -> IO (Maybe SessionData) -- ^ callback to maybe resume session on server.
	, onSessionEstablished :: SessionID -> SessionData -> IO ()  -- ^ callback when session have been established
	, onSessionInvalidated :: SessionID -> IO ()                 -- ^ callback when session is invalidated by error
	, sessionResumeWith   :: Maybe (SessionID, SessionData) -- ^ try to establish a connection using this session.
	}

defaultLogging :: Logging
defaultLogging = Logging
	{ loggingPacketSent = (\_ -> return ())
	, loggingPacketRecv = (\_ -> return ())
	, loggingIOSent     = (\_ -> return ())
	, loggingIORecv     = (\_ _ -> return ())
	}

defaultParams :: Params
defaultParams = Params
	{ pConnectVersion         = TLS10
	, pAllowedVersions        = [TLS10,TLS11,TLS12]
	, pCiphers                = []
	, pCompressions           = [nullCompression]
	, pWantClientCert         = False
	, pUseSecureRenegotiation = True
	, pUseSession             = True
	, pCertificates           = []
	, pLogging                = defaultLogging
	, onHandshake             = (\_ -> return True)
	, onCertificatesRecv      = (\_ -> return CertificateUsageAccept)
	, onSessionResumption     = (\_ -> return Nothing)
	, onSessionEstablished    = (\_ _ -> return ())
	, onSessionInvalidated    = (\_ -> return ())
	, sessionResumeWith       = Nothing
	}

instance Show Params where
	show p = "Params { " ++ (intercalate "," $ map (\(k,v) -> k ++ "=" ++ v)
		[ ("connectVersion", show $ pConnectVersion p)
		, ("allowedVersions", show $ pAllowedVersions p)
		, ("ciphers", show $ pCiphers p)
		, ("compressions", show $ pCompressions p)
		, ("want-client-cert", show $ pWantClientCert p)
		, ("certificates", show $ length $ pCertificates p)
		]) ++ " }"

-- | Certificate and Chain rejection reason
data CertificateRejectReason =
	  CertificateRejectExpired
	| CertificateRejectRevoked
	| CertificateRejectUnknownCA
	| CertificateRejectOther String
	deriving (Show,Eq)

-- | Certificate Usage callback possible returns values.
data CertificateUsage =
	  CertificateUsageAccept                         -- ^ usage of certificate accepted
	| CertificateUsageReject CertificateRejectReason -- ^ usage of certificate rejected
	deriving (Show,Eq)

-- |
data Backend = Backend
	{ backendFlush :: IO ()                -- ^ Flush the connection sending buffer, if any.
	, backendSend  :: ByteString -> IO ()  -- ^ Send a bytestring through the connection.
	, backendRecv  :: Int -> IO ByteString -- ^ Receive specified number of bytes from the connection.
	}

-- | A TLS Context keep tls specific state, parameters and backend information.
data Context = Context
	{ ctxConnection      :: Backend   -- ^ return the backend object associated with this context
	, ctxParams          :: Params
	, ctxState           :: MVar TLSState
	, ctxMeasurement     :: IORef Measurement
	, ctxEOF_            :: IORef Bool    -- ^ has the handle EOFed or not.
	, ctxEstablished_    :: IORef Bool    -- ^ has the handshake been done and been successful.
	}

-- deprecated types, setup as aliases for compatibility.
type TLSParams = Params
type TLSCtx = Context
type TLSLogging = Logging
type TLSCertificateUsage = CertificateUsage
type TLSCertificateRejectReason = CertificateRejectReason

updateMeasure :: MonadIO m => Context -> (Measurement -> Measurement) -> m ()
updateMeasure ctx f = liftIO $ do
    x <- readIORef (ctxMeasurement ctx)
    writeIORef (ctxMeasurement ctx) $! f x

withMeasure :: MonadIO m => Context -> (Measurement -> IO a) -> m a
withMeasure ctx f = liftIO (readIORef (ctxMeasurement ctx) >>= f)

connectionFlush :: Context -> IO ()
connectionFlush = backendFlush . ctxConnection

connectionSend :: Context -> Bytes -> IO ()
connectionSend c b = updateMeasure c (addBytesSent $ B.length b) >> (backendSend $ ctxConnection c) b

connectionRecv :: Context -> Int -> IO Bytes
connectionRecv c sz = updateMeasure c (addBytesReceived sz) >> (backendRecv $ ctxConnection c) sz

ctxEOF :: MonadIO m => Context -> m Bool
ctxEOF ctx = liftIO (readIORef $ ctxEOF_ ctx)

setEOF :: MonadIO m => Context -> m ()
setEOF ctx = liftIO $ writeIORef (ctxEOF_ ctx) True

ctxEstablished :: MonadIO m => Context -> m Bool
ctxEstablished ctx = liftIO $ readIORef $ ctxEstablished_ ctx

setEstablished :: MonadIO m => Context -> Bool -> m ()
setEstablished ctx v = liftIO $ writeIORef (ctxEstablished_ ctx) v

ctxLogging :: Context -> Logging
ctxLogging = pLogging . ctxParams

newCtxWith :: Backend -> Params -> TLSState -> IO Context
newCtxWith backend params st = do
	stvar <- newMVar st
	eof   <- newIORef False
	established <- newIORef False
	stats <- newIORef newMeasurement
	return $ Context
		{ ctxConnection   = backend
		, ctxParams       = params
		, ctxState        = stvar
		, ctxMeasurement  = stats
		, ctxEOF_         = eof
		, ctxEstablished_ = established
		}

newCtx :: Handle -> Params -> TLSState -> IO Context
newCtx handle params st =
	hSetBuffering handle NoBuffering >> newCtxWith backend params st
	where backend = Backend (hFlush handle) (B.hPut handle) (B.hGet handle)

throwCore :: (MonadIO m, Exception e) => e -> m a
throwCore = liftIO . throwIO


usingState :: MonadIO m => Context -> TLSSt a -> m (Either TLSError a)
usingState ctx f =
	liftIO $ modifyMVar (ctxState ctx) $ \st ->
		let (a, newst) = runTLSState f st
		 in newst `seq` return (newst, a)

usingState_ :: MonadIO m => Context -> TLSSt a -> m a
usingState_ ctx f = do
	ret <- usingState ctx f
	case ret of
		Left err -> throwCore err
		Right r  -> return r

getStateRNG :: MonadIO m => Context -> Int -> m Bytes
getStateRNG ctx n = usingState_ ctx (genTLSRandom n)

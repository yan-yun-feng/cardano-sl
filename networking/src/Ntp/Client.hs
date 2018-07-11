{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

-- | This module implements functionality of NTP client.

module Ntp.Client
    ( NtpClientSettings (..)
    , NtpStatus (..)
    , withNtpClient
    ) where

import           Universum hiding (Last)

import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, concurrently_, race,
                     withAsync)
import           Control.Concurrent.STM (TVar, modifyTVar', retry)
import           Control.Exception.Safe (Exception, catchAny, handleAny)
import           Control.Monad (forever)
import           Data.Binary (decodeOrFail)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.List.NonEmpty as NE
import           Data.Semigroup (Last (..))
import           Data.Time.Units (Microsecond, TimeUnit, toMicroseconds)
import           Data.Typeable (Typeable)
import           Formatting (sformat, shown, (%))
import qualified Network.Socket as Socket
import           Network.Socket.ByteString (recvFrom)
import qualified System.Wlog as Wlog

import           Ntp.Packet (NtpOffset, NtpPacket (..), clockOffset,
                     mkCliNtpPacket, ntpPacketSize)
import           Ntp.Util (Addresses, AddrFamily (..), EitherOrBoth (..),
                     WithAddrFamily (..), Sockets, createAndBindSock,
                     foldEitherOrBoth, logDebug, logInfo, logWarning, ntpTrace,
                     resolveNtpHost, sendPacket, udpLocalAddresses)
import           Pos.Util.Trace (traceWith)

data NtpStatus =
      -- | The difference between ntp time and local system time
      NtpDrift NtpOffset
      -- | NTP client has send requests to the servers
    | NtpSyncPending
      -- | NTP is not available: the client has not received any respond within
      -- `ntpResponseTimeout` or NTP was not configured.
    | NtpSyncUnavailable deriving (Eq, Show)

data NtpClientSettings = NtpClientSettings
    { ntpServers         :: [String]
      -- ^ list of servers addresses
    , ntpResponseTimeout :: Microsecond
      -- ^ delay between making requests and response collection
    , ntpPollDelay       :: Microsecond
      -- ^ how long to wait between to send requests to the servers
    , ntpSelection       :: NonEmpty NtpOffset -> NtpOffset
      -- ^ way to sumarize results received from different servers.
      -- this may accept list of lesser size than @length ntpServers@ in case
      -- some servers failed to respond in time, but never an empty list
    }

data NtpClient = NtpClient
    { ncSockets  :: TVar Sockets
      -- ^ Ntp client sockets: ipv4 / ipv6 / both.
    , ncState    :: TVar [NtpOffset]
      -- ^ List of ntp offsets and origin times (i.e. time when a request was
      -- send) received from ntp servers since last polling interval.
    , ncStatus   :: TVar NtpStatus
      -- ^ Ntp status: holds `NtpOffset` or a status of ntp client:
      -- `NtpSyncPending`, `NtpSyncUnavailable`.  It is computed from `ncState`
      -- once all responses arrived.
    , ncSettings :: NtpClientSettings
      -- ^ Ntp client configuration.
    }

mkNtpClient :: MonadIO m => NtpClientSettings -> TVar NtpStatus -> Sockets -> m NtpClient
mkNtpClient ncSettings ncStatus sock = liftIO $ do
    ncSockets <- newTVarIO sock
    ncState   <- newTVarIO []
    return NtpClient{..}

data NoHostResolved = NoHostResolved
    deriving (Show, Typeable)

instance Exception NoHostResolved

-- |
-- Update @'ncStatus'@ according to received responses.
updateStatus'
    :: NtpClient
    -> ([NtpOffset] -> (NtpStatus, (Wlog.Severity, Text)))
    -> IO ()
updateStatus' cli fn = do
    (offset, msg) <- fn <$> readTVarIO (ncState cli)
    traceWith ntpTrace msg
    atomically $ writeTVar (ncStatus cli) offset

updateStatus :: NtpClient -> IO ()
updateStatus cli = updateStatus' cli fn
    where
    fn :: [NtpOffset]
       -> (NtpStatus, (Wlog.Severity, Text))
    fn [] = ( NtpSyncUnavailable
            , (Wlog.Warning, "ntp client haven't received any response")
            )
    fn offsets = 
        let offset = ntpSelection (ncSettings cli) $ NE.fromList $ offsets
        in ( NtpDrift offset 
           , (Wlog.Info, sformat ("Evaluated clock offset "%shown%"mcs") offset)
           )

-- |
-- Every `ntpPollDelay` send request to the list of `ntpServers`.  Before
-- sending the request, fill `ncState` with `NtpSyncPending`.  After sending
-- requests wait until either all servers respond or `ntpResponseTimeout`
-- passes.  If at least one server responded `handleCollectedResponses` will
-- update `ncStatus` in `NtpClient`.
sendLoop :: NtpClient -> [Addresses] -> IO ()
sendLoop cli addrs = do
    let respTimeout = ntpResponseTimeout (ncSettings cli)
    let poll = ntpPollDelay (ncSettings cli)

    concurrently_ (threadDelay $ fromIntegral poll) $ do
        logDebug "Sending requests"
        atomically . modifyTVar' (ncState cli) $ const []

        sock <- atomically $ readTVar $ ncSockets cli
        packet <- mkCliNtpPacket
        withAsync (sendPacket sock packet addrs) $ \_ -> waitForResponses respTimeout
        logDebug "Collected responses"

        updateStatus cli

        atomically $ writeTVar (ncState cli) []

    -- reset ntp client status before next loop
    atomically $ writeTVar (ncStatus cli) NtpSyncPending

    sendLoop cli addrs
    where
        waitForResponses respTimeout = void $ timeout respTimeout $ atomically $ do
            resps <- readTVar $ ncState cli
            let svs = length $ ntpServers $ ncSettings cli
            when (length resps < svs)
                retry

-- |
-- Compute the clock offset based on current time and record it in the ntp
-- client state.   A packet will be digarded if it came after
-- @'ntpResponseTimeout'@.
handleNtpPacket
    :: NtpClient
    -> NtpPacket
    -> IO ()
handleNtpPacket cli packet = do
    logDebug $ sformat ("Got packet "%shown) packet

    clockOffset (ntpResponseTimeout $ ncSettings cli) packet >>= \case
        Nothing ->
            logWarning "Response was too late: discarding it."
        Just offset -> do
            logDebug $ sformat ("Received time delta "%shown%"mcs")
                (toMicroseconds offset)
            atomically $ modifyTVar' (ncState cli) ( offset : )


-- |
-- Start listening for responses on the socket `ncSockets
startReceive :: NtpClient -> IO ()
startReceive cli =
    atomically (readTVar $ ncSockets cli) >>= \case
        EBBoth (Last (WithAddrFamily sock_ipv6)) (Last (WithAddrFamily sock_ipv4)) ->
            loop IPv6 sock_ipv6
            `concurrently_`
            loop IPv4 sock_ipv4
        EBFirst (Last (WithAddrFamily sock_ipv6)) ->
            loop IPv6 sock_ipv6
        EBSecond (Last (WithAddrFamily sock_ipv4)) ->
            loop IPv4 sock_ipv4
    where
    -- Receive responses from the network and update ntp client state.
    loop :: AddrFamily -> Socket.Socket -> IO ()
    loop addressFamily sock
        = handleAny (handleE addressFamily) $ forever $ do
            (bs, _) <- recvFrom sock ntpPacketSize
            let eNtpPacket = decodeOrFail $ LBS.fromStrict bs
            case eNtpPacket of
                Left  (_, _, err)    ->
                    logWarning $ sformat ("Error while receiving time: "%shown) err
                Right (_, _, packet) ->
                    handleNtpPacket cli packet

    -- Restart the @loop@ in case of errors; wait 5s before recreacting the
    -- socket.
    handleE
        :: AddrFamily
        -> SomeException
        -> IO ()
    handleE addressFamily e = do
        logDebug $ sformat ("startReceive failed with reason: "%shown) e
        threadDelay 5000000
        udpLocalAddresses >>= createAndBindSock addressFamily >>= \case
            Nothing   -> logWarning "Recreating of socket failed" >> handleE addressFamily e
            Just sock -> do
                atomically $ modifyTVar' (ncSockets cli) (\s -> s <> sock)
                case sock of
                    EBFirst  (Last (WithAddrFamily sock_))
                        -> loop addressFamily sock_
                    EBSecond (Last (WithAddrFamily sock_))
                        -> loop addressFamily sock_
                    EBBoth _ _
                        -> error "impossible"

-- |
-- Spawn ntp client which will send request to ntp servers every ntpPollDelay
-- and will lisent for responses.  The `ncStatus` will be updated every
-- `ntpPollDelay` with the most recent value.  It should be run in a seprate
-- thread, since it will block infinitelly.
spawnNtpClient :: NtpClientSettings -> TVar NtpStatus -> IO ()
spawnNtpClient settings ncStatus =
    bracket (mkSockets settings) closeSockets $ \sock -> do
        cli <- mkNtpClient settings ncStatus sock

        addrs <- catMaybes <$> traverse resolveNtpHost (ntpServers settings)
        when (null addrs) $ throwM NoHostResolved
        startReceive cli
            `concurrently_` sendLoop cli addrs
            `concurrently_` logInfo "Launched NTP client"
    where
    closeSockets :: Sockets -> IO ()
    closeSockets sockets = do
        foldEitherOrBoth $ bimap fn fn sockets
        logInfo "NTP client stopped"

    fn :: Last (WithAddrFamily t Socket.Socket) -> IO ()
    fn (Last (WithAddrFamily sock)) = Socket.close sock

-- | Run Ntp client in a seprate thread, return a mutable cell which holds
-- `NtpStatus`.
withNtpClient :: MonadIO m => NtpClientSettings -> m (TVar NtpStatus)
withNtpClient ntpSettings = do
    ncStatus <- newTVarIO NtpSyncPending
    _ <- liftIO $ async (spawnNtpClient ntpSettings ncStatus)
    return ncStatus

-- Try to create IPv4 and IPv6 socket.
mkSockets :: NtpClientSettings -> IO Sockets
mkSockets settings = do
    doMkSockets `catchAny` handlerE >>= \case
        Just sock -> pure sock
        Nothing   -> do
            logWarning "Couldn't create both IPv4 and IPv6 socket, retrying in 5 sec..."
            threadDelay 5000000
            mkSockets settings
  where
    doMkSockets :: IO (Maybe Sockets)
    doMkSockets = do
        addrs <- udpLocalAddresses
        Option mSockets <-
            (<>) <$> (Option <$> createAndBindSock IPv4 addrs)
                 <*> (Option <$> createAndBindSock IPv6 addrs)
        return mSockets
    handlerE e = do
        logWarning $
            sformat ("Failed to create sockets, retrying in 5 sec... (reason: "%shown%")")
            e
        threadDelay 5000000
        doMkSockets

timeout :: TimeUnit t => t -> IO a -> IO (Maybe a)
timeout t io = rightToMaybe <$> race (threadDelay (fromIntegral (toMicroseconds t))) io

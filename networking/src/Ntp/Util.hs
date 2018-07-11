{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Ntp.Util
    ( ntpPort
    , WithAddrFamily (..)
    , AddrFamily (..)
    , Addresses
    , Sockets
    , resolveNtpHost
    , sendPacket

    , createAndBindSock
    , udpLocalAddresses

    , EitherOrBoth (..)
    , foldEitherOrBoth
    , pairEitherOrBoth

    , ntpTrace
    , logDebug
    , logInfo
    , logWarning
    ) where

import           Control.Concurrent.Async (forConcurrently_)
import           Control.Exception (IOException, catch)
import           Control.Exception.Safe (handleAny)
import           Control.Monad (void)
import           Data.Bifunctor (Bifunctor (..))
import           Data.Binary (encode)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import           Data.List (find)
import           Data.Semigroup (First (..), Last (..), Semigroup (..),
                     Option (..))
import           Data.Text (Text)
import           Formatting (sformat, shown, (%))
import           Network.Socket (AddrInfo,
                     AddrInfoFlag (AI_ADDRCONFIG, AI_PASSIVE),
                     Family (AF_INET, AF_INET6), PortNumber (..),
                     SockAddr (..), Socket, SocketOption (ReuseAddr),
                     SocketType (Datagram), aNY_PORT, addrAddress, addrFamily,
                     addrFlags, addrSocketType)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket.ByteString (sendTo)
import qualified System.Wlog as Wlog

import           Ntp.Packet (NtpPacket)
import           Pos.Util.Trace (Trace, traceWith, wlogTrace)


ntpTrace :: Trace IO (Wlog.Severity, Text)
ntpTrace = wlogTrace "NtpClient"

logWarning :: Text -> IO ()
logWarning msg = traceWith ntpTrace (Wlog.Warning, msg)

logInfo :: Text -> IO ()
logInfo msg = traceWith ntpTrace (Wlog.Info, msg)

logDebug :: Text -> IO ()
logDebug msg = traceWith ntpTrace (Wlog.Debug, msg)

data AddrFamily = IPv4 | IPv6

-- |
-- Newtype wrapper which tags the type with either IPv4 or IPv6 phantom type.
newtype WithAddrFamily (t :: AddrFamily) a  = WithAddrFamily { runWithAddrFamily :: a }
    deriving (Eq, Show, Functor)

-- |
-- Keep either of the two types or both.
data EitherOrBoth a b
    = EBFirst  !a
    | EBSecond !b
    | EBBoth   !a !b
    deriving (Show, Eq, Ord)

instance Bifunctor EitherOrBoth where
    bimap f _ (EBFirst a) = EBFirst $ f a
    bimap _ g (EBSecond b) = EBSecond $ g b
    bimap f g (EBBoth a b) = EBBoth (f a) (g b)

-- |
-- @'EitehrOrBoth'@ is a semigroup whenever both @a@ and @b@ are.
instance (Semigroup a, Semigroup b) => Semigroup (EitherOrBoth a b) where

    EBFirst  a <> EBFirst  a'  = EBFirst (a <> a')
    EBFirst  a <> EBSecond b   = EBBoth a b
    EBFirst  a <> EBBoth a' b  = EBBoth (a <> a') b

    EBSecond b <> EBFirst  a   = EBBoth a b
    EBSecond b <> EBSecond b'  = EBSecond (b <> b')
    EBSecond b <> EBBoth a b'  = EBBoth a (b <> b')

    EBBoth a b <> EBFirst a'   = EBBoth (a <> a') b
    EBBoth a b <> EBSecond b'  = EBBoth a (b <> b')
    EBBoth a b <> EBBoth a' b' = EBBoth (a <> a') (b <> b')

-- |
-- Note that the composition of `foldEitherOrBoth . bimap f g` is a proof that
-- @'EitherOrBoth a b@ is the [free
-- product](https://en.wikipedia.org/wiki/Free_product) of two semigroups @a@
-- and @b@.
foldEitherOrBoth
    :: Semigroup a
    => EitherOrBoth a a
    -> a
foldEitherOrBoth (EBFirst a)    = a
foldEitherOrBoth (EBSecond a)   = a
foldEitherOrBoth (EBBoth a1 a2) = a1 <> a2

pairEitherOrBoth :: EitherOrBoth a b -> EitherOrBoth x y -> Maybe (EitherOrBoth (a, x) (b, y))
pairEitherOrBoth (EBBoth a b) (EBBoth x y)  = Just $ EBBoth (a, x) (b, y)
pairEitherOrBoth (EBFirst a)   (EBFirst x)  = Just $ EBFirst (a, x)
pairEitherOrBoth (EBSecond b)  (EBSecond y) = Just $ EBSecond (b, y)
pairEitherOrBoth _            _             = Nothing

-- |
-- Store created sockets.  If system supports IPv6 and IPv4 we create socket for
-- IPv4 and IPv6.  Otherwise only one.
type Sockets = EitherOrBoth
    (Last (WithAddrFamily 'IPv6 Socket))
    (Last (WithAddrFamily 'IPv4 Socket))

-- |
-- A counter part of @'Ntp.Client.Sockets'@ data type.
type Addresses = EitherOrBoth
    (First (WithAddrFamily 'IPv6 SockAddr))
    (First (WithAddrFamily 'IPv4 SockAddr))

ntpPort :: PortNumber
ntpPort = 123

-- |
-- Returns a list of alternatives. At most of length two,
-- at most one ipv6 / ipv4 address.
resolveHost :: String -> IO (Maybe Addresses)
resolveHost host = do
    let hints = Socket.defaultHints
            { addrSocketType = Datagram
            , addrFlags = [AI_ADDRCONFIG]  -- since we use AF_INET family
            }
    -- TBD why catch here? Why not let 'resolveHost' throw the exception?
    addrInfos <- Socket.getAddrInfo (Just hints) (Just host) Nothing
                    `catch` (\(_ :: IOException) -> return [])

    let maddr = getOption $ foldMap fn addrInfos
    case maddr of
        Nothing ->
            logWarning $ sformat ("Host "%shown%" is not resolved") host
        Just addr ->
            let g :: First (WithAddrFamily t SockAddr) -> [SockAddr]
                g (First (WithAddrFamily a)) = [a]
                addrs :: [SockAddr]
                addrs = foldEitherOrBoth . bimap g g $ addr
            in logInfo $ sformat ("Host "%shown%" is resolved: "%shown)
                    host addrs
    return maddr
    where
        -- Return supported address: one ipv6 and one ipv4 address.
        fn :: AddrInfo -> Option Addresses
        fn addr = case Socket.addrFamily addr of
            Socket.AF_INET6 ->
                Option $ Just $ EBFirst  $ First $ (WithAddrFamily $ Socket.addrAddress addr)
            Socket.AF_INET  ->
                Option $ Just $ EBSecond $ First $ (WithAddrFamily $ Socket.addrAddress addr)
            _               -> mempty

resolveNtpHost :: String -> IO (Maybe Addresses)
resolveNtpHost host = do
    addr <- resolveHost host
    return $ fmap (bimap adjustPort adjustPort) addr
    where
        adjustPort :: First (WithAddrFamily t SockAddr) -> First (WithAddrFamily t SockAddr)
        adjustPort = fmap $ fmap (replacePort ntpPort)

replacePort :: PortNumber -> SockAddr ->  SockAddr
replacePort port (SockAddrInet  _ host)            = SockAddrInet  port host
replacePort port (SockAddrInet6 _ flow host scope) = SockAddrInet6 port flow host scope
replacePort _    sockAddr                          = sockAddr

createAndBindSock
    :: AddrFamily
    -- ^ indicates which socket family to create, either AF_INET6 or AF_INET
    -> [AddrInfo]
    -- ^ list of local addresses
    -> IO (Maybe Sockets)
createAndBindSock addressFamily addrs =
    traverse createDo (selectAddr addrs)
  where
    selectAddr :: [AddrInfo] -> Maybe AddrInfo
    selectAddr = find $ \addr ->
        case addressFamily of
            IPv6 -> addrFamily addr == AF_INET6
            IPv4 -> addrFamily addr == AF_INET
                        
    createDo addr = do
        sock <- Socket.socket (addrFamily addr) Datagram Socket.defaultProtocol
        Socket.setSocketOption sock ReuseAddr 1
        Socket.bind sock (addrAddress addr)
        logInfo $
            sformat ("Created socket (family/addr): "%shown%"/"%shown)
                    (addrFamily addr) (addrAddress addr)
        case addressFamily of
            IPv6 -> return $ EBFirst  $ Last $ (WithAddrFamily sock)
            IPv4 -> return $ EBSecond $ Last $ (WithAddrFamily sock)

udpLocalAddresses :: IO [AddrInfo]
udpLocalAddresses = do
    let hints = Socket.defaultHints
            { addrFlags = [AI_PASSIVE]
            , addrSocketType = Datagram }
    --                 Hints        Host    Service
    Socket.getAddrInfo (Just hints) Nothing (Just $ show aNY_PORT)


-- |
-- Send a request to @addr :: Addresses@ using @sock :: Sockets@.
sendTo
    :: Sockets
    -- ^ sockets to use
    -> ByteString
    -> Addresses
    -- ^ addresses to send to
    -> IO ()
sendTo sock bs addr = case fmap (foldEitherOrBoth . bimap fn fn) $ pairEitherOrBoth sock addr of
    Just io -> io
    Nothing ->
        error $ "SockAddr is " <> show addr <> ", but sockets: " <> show sock
    where
    fn :: ( Last (WithAddrFamily t Socket)
          , First (WithAddrFamily t SockAddr)
          )
        -> IO ()
    fn (Last (WithAddrFamily sock_), First (WithAddrFamily addr_)) = void $ Socket.ByteString.sendTo sock_ bs addr_

-- |
-- Low level primitive which sends a request to a single ntp server.
sendPacket
    :: Sockets
    -> NtpPacket
    -> [Addresses]
    -> IO ()
sendPacket sock packet addrs = do
    let bs = LBS.toStrict $ encode $ packet
    forConcurrently_ addrs $ \addr ->
        handleAny (handleE addr) $ void $ sendTo sock bs addr
  where
    -- just log; socket closure is handled by receiver
    handleE addr =
        logWarning . sformat ("Failed to send to "%shown%": "%shown) addr

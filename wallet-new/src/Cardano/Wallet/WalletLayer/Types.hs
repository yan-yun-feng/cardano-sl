module Cardano.Wallet.WalletLayer.Types
    ( PassiveWalletLayer (..)
    , ActiveWalletLayer (..)
    -- * Getters
    , createWallet
    , getWalletIds
    , getWallet
    , updateWallet
    , deleteWallet

    , createAccount
    , getAccounts
    , getAccount
    , updateAccount
    , deleteAccount

    , createAddress
    , getAddresses
    , applyBlocks
    , rollbackBlocks
    -- * Errors
    , CreateAddressError(..)
    ) where

import qualified Prelude
import           Universum

import           Control.Lens (makeLenses)

import           Formatting (bprint, build, formatToString, (%))
import qualified Formatting.Buildable

import           Cardano.Wallet.API.V1.Types (Account, AccountIndex,
                     AccountUpdate, Address, NewAccount, NewAddress, NewWallet,
                     Wallet, WalletId, WalletUpdate)

import qualified Cardano.Wallet.Kernel.Addresses as Kernel
import           Cardano.Wallet.WalletLayer.ExecutionTimeLimit
                     (TimeExecutionLimit)

import           Pos.Block.Types (Blund)
import           Pos.Core.Chrono (NE, NewestFirst (..), OldestFirst (..))
import           Test.QuickCheck (Arbitrary (..), oneof)

------------------------------------------------------------
-- Common errors
------------------------------------------------------------

data CreateAddressError =
      CreateAddressError Kernel.CreateAddressError
    | CreateAddressAddressDecodingFailed Text
    -- ^ Decoding the input 'Text' as an 'Address' failed.
    | CreateAddressTimeLimitReached TimeExecutionLimit
    deriving Eq

-- | Unsound show instance needed for the 'Exception' instance.
instance Show CreateAddressError where
    show = formatToString build

instance Exception CreateAddressError

instance Arbitrary CreateAddressError where
    arbitrary = oneof [ CreateAddressError <$> arbitrary
                      , pure (CreateAddressAddressDecodingFailed "Ae2tdPwUPEZ18ZjTLnLVr9CEvUEUX4eW1LBHbxxx")
                      ]

instance Buildable CreateAddressError where
    build (CreateAddressError kernelError) =
        bprint ("CreateAddressError " % build) kernelError
    build (CreateAddressAddressDecodingFailed txt) =
        bprint ("CreateAddressAddressDecodingFailed " % build) txt
    build (CreateAddressTimeLimitReached timeLimit) =
        bprint ("CreateAddressTimeLimitReached " % build) timeLimit

------------------------------------------------------------
-- Passive wallet layer
------------------------------------------------------------

-- | The passive wallet (data) layer. See @PassiveWallet@.
data PassiveWalletLayer m = PassiveWalletLayer
    {
    -- * wallets
      _pwlCreateWallet   :: NewWallet -> m Wallet
    , _pwlGetWalletIds   :: m [WalletId]
    , _pwlGetWallet      :: WalletId -> m (Maybe Wallet)
    , _pwlUpdateWallet   :: WalletId -> WalletUpdate -> m Wallet
    , _pwlDeleteWallet   :: WalletId -> m Bool
    -- * accounts
    , _pwlCreateAccount  :: WalletId -> NewAccount -> m Account
    , _pwlGetAccounts    :: WalletId -> m [Account]
    , _pwlGetAccount     :: WalletId -> AccountIndex -> m (Maybe Account)
    , _pwlUpdateAccount  :: WalletId -> AccountIndex -> AccountUpdate -> m Account
    , _pwlDeleteAccount  :: WalletId -> AccountIndex -> m Bool
    -- * addresses
    , _pwlCreateAddress  :: NewAddress -> m (Either CreateAddressError Address)
    , _pwlGetAddresses   :: WalletId -> m [Address]
    -- * core API
    , _pwlApplyBlocks    :: OldestFirst NE Blund -> m ()
    , _pwlRollbackBlocks :: NewestFirst NE Blund -> m ()
    }

makeLenses ''PassiveWalletLayer

------------------------------------------------------------
-- Passive wallet layer getters
------------------------------------------------------------

createWallet :: forall m. PassiveWalletLayer m -> NewWallet -> m Wallet
createWallet pwl = pwl ^. pwlCreateWallet

getWalletIds :: forall m. PassiveWalletLayer m -> m [WalletId]
getWalletIds pwl = pwl ^. pwlGetWalletIds

getWallet :: forall m. PassiveWalletLayer m -> WalletId -> m (Maybe Wallet)
getWallet pwl = pwl ^. pwlGetWallet

updateWallet :: forall m. PassiveWalletLayer m -> WalletId -> WalletUpdate -> m Wallet
updateWallet pwl = pwl ^. pwlUpdateWallet

deleteWallet :: forall m. PassiveWalletLayer m -> WalletId -> m Bool
deleteWallet pwl = pwl ^. pwlDeleteWallet


createAccount :: forall m. PassiveWalletLayer m -> WalletId -> NewAccount -> m Account
createAccount pwl = pwl ^. pwlCreateAccount

getAccounts :: forall m. PassiveWalletLayer m -> WalletId -> m [Account]
getAccounts pwl = pwl ^. pwlGetAccounts

getAccount :: forall m. PassiveWalletLayer m -> WalletId -> AccountIndex -> m (Maybe Account)
getAccount pwl = pwl ^. pwlGetAccount

updateAccount :: forall m. PassiveWalletLayer m -> WalletId -> AccountIndex -> AccountUpdate -> m Account
updateAccount pwl = pwl ^. pwlUpdateAccount

deleteAccount :: forall m. PassiveWalletLayer m -> WalletId -> AccountIndex -> m Bool
deleteAccount pwl = pwl ^. pwlDeleteAccount

createAddress :: forall m. PassiveWalletLayer m -> NewAddress -> m (Either CreateAddressError Address)
createAddress pwl = pwl ^. pwlCreateAddress

getAddresses :: forall m. PassiveWalletLayer m -> WalletId -> m [Address]
getAddresses pwl = pwl ^. pwlGetAddresses


applyBlocks :: forall m. PassiveWalletLayer m -> OldestFirst NE Blund -> m ()
applyBlocks pwl = pwl ^. pwlApplyBlocks

rollbackBlocks :: forall m. PassiveWalletLayer m -> NewestFirst NE Blund -> m ()
rollbackBlocks pwl = pwl ^. pwlRollbackBlocks

------------------------------------------------------------
-- Active wallet layer
------------------------------------------------------------

-- An active wallet layer. See @ActiveWallet@.
data ActiveWalletLayer m = ActiveWalletLayer {
      -- | The underlying passive wallet layer
      walletPassiveLayer :: PassiveWalletLayer m
    }

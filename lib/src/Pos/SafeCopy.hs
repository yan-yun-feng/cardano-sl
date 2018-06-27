{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | SafeCopy serialization of the world, required for wallet. ☕

module Pos.SafeCopy
       (
       ) where

import           Universum

import qualified Crypto.Math.Edwards25519 as ED25519
import           Data.SafeCopy (SafeCopy (..), base, contain, deriveSafeCopySimple, safeGet,
                     safePut)
import qualified Data.Serialize as Cereal
import qualified PlutusCore.Program as PLCore
import qualified PlutusCore.Term as PLCore
import           Serokell.AcidState.Instances ()
import           Serokell.Data.Memory.Units (Byte, fromBytes, toBytes)

import           Pos.Binary.Class (Bi)
import           Pos.Binary.SafeCopy (getCopyBi, putCopyBi)
import           Pos.Core.Block
import           Pos.Core.Common (AddrAttributes (..), AddrSpendingData (..),
                     AddrStakeDistribution (..), AddrType (..), Address (..), Address' (..),
                     BlockCount (..), ChainDifficulty (..), Coeff (..), Coin, CoinPortion (..),
                     Script (..), SharedSeed (..), TxFeePolicy (..), TxSizeLinear (..))
import           Pos.Core.Delegation (DlgPayload (..), HeavyDlgIndex (..), LightDlgIndices (..))
import           Pos.Core.Slotting (EpochIndex (..), EpochOrSlot (..), LocalSlotIndex (..),
                     SlotCount (..), SlotId (..))
import           Pos.Core.Ssc (Commitment (..), CommitmentsMap, Opening (..), SscPayload (..),
                     SscProof (..), VssCertificate (..), VssCertificatesMap)
import           Pos.Core.Txp (Tx (..), TxIn (..), TxInWitness (..), TxOut (..), TxOutAux (..),
                     TxPayload (..), TxProof (..))
import           Pos.Core.Update (ApplicationName (..), BlockVersion (..), BlockVersionData (..),
                     BlockVersionModifier (..), SoftforkRule (..), SoftwareVersion (..),
                     SystemTag (..), UpdateData (..), UpdatePayload (..), UpdateProposal (..),
                     UpdateVote (..))
import           Pos.Crypto (ProtocolMagic (..))
import           Pos.Crypto.HD (HDAddressPayload (..))
import           Pos.Crypto.SafeCopy ()
import           Pos.Crypto.SecretSharing (SecretProof)
import           Pos.Data.Attributes (Attributes (..), UnparsedFields)
import           Pos.Merkle (MerkleNode (..), MerkleRoot (..), MerkleTree (..))
import qualified Pos.Util.Modifier as MM
import           Pos.Util.Util (cerealError)

----------------------------------------------------------------------------
-- Core types
----------------------------------------------------------------------------

deriveSafeCopySimple 0 'base ''ProtocolMagic

deriveSafeCopySimple 0 'base ''Script
deriveSafeCopySimple 0 'base ''ApplicationName
deriveSafeCopySimple 0 'base ''BlockVersion
deriveSafeCopySimple 0 'base ''SoftwareVersion

deriveSafeCopySimple 0 'base ''ED25519.PointCompressed
deriveSafeCopySimple 0 'base ''ED25519.Scalar
deriveSafeCopySimple 0 'base ''ED25519.Signature

instance Bi SecretProof => SafeCopy SecretProof where
    getCopy = getCopyBi
    putCopy = putCopyBi

----------------------------------------------------------------------------
-- SSC
----------------------------------------------------------------------------

deriveSafeCopySimple 0 'base ''VssCertificate
deriveSafeCopySimple 0 'base ''Opening
deriveSafeCopySimple 0 'base ''Commitment
deriveSafeCopySimple 0 'base ''CommitmentsMap
deriveSafeCopySimple 0 'base ''VssCertificatesMap

deriveSafeCopySimple 0 'base ''SscPayload
deriveSafeCopySimple 0 'base ''SscProof

----------------------------------------------------------------------------
-- Base types
----------------------------------------------------------------------------

deriveSafeCopySimple 0 'base ''CoinPortion
deriveSafeCopySimple 0 'base ''EpochIndex
deriveSafeCopySimple 0 'base ''LocalSlotIndex
deriveSafeCopySimple 0 'base ''SlotId
deriveSafeCopySimple 0 'base ''EpochOrSlot
deriveSafeCopySimple 0 'base ''UnparsedFields
deriveSafeCopySimple 0 'base ''BlockCount
deriveSafeCopySimple 0 'base ''SlotCount
deriveSafeCopySimple 0 'base ''Coin
deriveSafeCopySimple 0 'base ''HDAddressPayload
deriveSafeCopySimple 0 'base ''AddrType -- ☃
deriveSafeCopySimple 0 'base ''AddrStakeDistribution
deriveSafeCopySimple 0 'base ''AddrSpendingData
deriveSafeCopySimple 0 'base ''AddrAttributes
deriveSafeCopySimple 0 'base ''Address'
deriveSafeCopySimple 0 'base ''Address
deriveSafeCopySimple 0 'base ''TxInWitness
deriveSafeCopySimple 0 'base ''TxIn
deriveSafeCopySimple 0 'base ''TxOut
deriveSafeCopySimple 0 'base ''TxOutAux
deriveSafeCopySimple 0 'base ''Tx
deriveSafeCopySimple 0 'base ''TxProof
deriveSafeCopySimple 0 'base ''TxPayload
deriveSafeCopySimple 0 'base ''SharedSeed

deriveSafeCopySimple 0 'base ''DlgPayload

deriveSafeCopySimple 0 'base ''MainExtraBodyData
deriveSafeCopySimple 0 'base ''MainExtraHeaderData
deriveSafeCopySimple 0 'base ''GenesisExtraHeaderData
deriveSafeCopySimple 0 'base ''GenesisExtraBodyData

deriveSafeCopySimple 0 'base ''SystemTag
deriveSafeCopySimple 0 'base ''UpdateData
deriveSafeCopySimple 0 'base ''Coeff
deriveSafeCopySimple 0 'base ''TxSizeLinear
deriveSafeCopySimple 0 'base ''TxFeePolicy
deriveSafeCopySimple 0 'base ''SoftforkRule -- 💋
deriveSafeCopySimple 0 'base ''BlockVersionData
deriveSafeCopySimple 0 'base ''BlockVersionModifier
deriveSafeCopySimple 0 'base ''UpdateProposal
deriveSafeCopySimple 0 'base ''UpdateVote
deriveSafeCopySimple 0 'base ''UpdatePayload

-- Manually written instances can't be derived because
-- 'deriveSafeCopySimple' is not clever enough to add
-- “SafeCopy (Whatever a) =>” constraints.
-- Written by hand, because @deriveSafeCopySimple@ generates redundant
-- constraint (SafeCopy w) though it's phantom.
----------------------------------------------------------------------------
-- Manual instances
----------------------------------------------------------------------------

instance ( SafeCopy (BHeaderHash b)
         , SafeCopy (BodyProof b)
         , SafeCopy (ConsensusData b)
         , SafeCopy (ExtraHeaderData b)
         ) =>
         SafeCopy (GenericBlockHeader b) where
    getCopy =
        contain $
        do _gbhProtocolMagic <- safeGet
           _gbhPrevBlock <- safeGet
           _gbhBodyProof <- safeGet
           _gbhConsensus <- safeGet
           _gbhExtra <- safeGet
           return $! UnsafeGenericBlockHeader {..}
    putCopy UnsafeGenericBlockHeader {..} =
        contain $
        do safePut _gbhProtocolMagic
           safePut _gbhPrevBlock
           safePut _gbhBodyProof
           safePut _gbhConsensus
           safePut _gbhExtra

instance ( SafeCopy (BHeaderHash b)
         , SafeCopy (BodyProof b)
         , SafeCopy (ConsensusData b)
         , SafeCopy (ExtraHeaderData b)
         , SafeCopy (Body b)
         , SafeCopy (ExtraBodyData b)
         ) =>
         SafeCopy (GenericBlock b) where
    getCopy =
        contain $
        do _gbHeader <- safeGet
           _gbBody <- safeGet
           _gbExtra <- safeGet
           return $! UnsafeGenericBlock {..}
    putCopy UnsafeGenericBlock {..} =
        contain $
        do safePut _gbHeader
           safePut _gbBody
           safePut _gbExtra

deriveSafeCopySimple 0 'base ''ChainDifficulty

instance SafeCopy SscProof =>
         SafeCopy MainProof where
    getCopy = contain $ do
        mpTxProof <- safeGet
        mpMpcProof      <- safeGet
        mpProxySKsProof <- safeGet
        mpUpdateProof   <- safeGet
        return $! MainProof{..}
    putCopy MainProof {..} = contain $ do
        safePut mpTxProof
        safePut mpMpcProof
        safePut mpProxySKsProof
        safePut mpUpdateProof

instance SafeCopy GenesisProof where
    getCopy =
        contain $
        do x <- safeGet
           return $! GenesisProof x
    putCopy (GenesisProof x) =
        contain $
        do safePut x

instance SafeCopy BlockSignature where
    getCopy = contain $ Cereal.getWord8 >>= \case
        0 -> BlockSignature <$> safeGet
        1 -> BlockPSignatureLight <$> safeGet
        2 -> BlockPSignatureHeavy <$> safeGet
        t -> cerealError $ "getCopy@BlockSignature: couldn't read tag: " <> show t
    putCopy (BlockSignature sig)            = contain $ Cereal.putWord8 0 >> safePut sig
    putCopy (BlockPSignatureLight proxySig) = contain $ Cereal.putWord8 1 >> safePut proxySig
    putCopy (BlockPSignatureHeavy proxySig) = contain $ Cereal.putWord8 2 >> safePut proxySig

instance SafeCopy MainConsensusData where
    getCopy =
        contain $
        do _mcdSlot <- safeGet
           _mcdLeaderKey <- safeGet
           _mcdDifficulty <- safeGet
           _mcdSignature <- safeGet
           return $! MainConsensusData {..}
    putCopy MainConsensusData {..} =
        contain $
        do safePut _mcdSlot
           safePut _mcdLeaderKey
           safePut _mcdDifficulty
           safePut _mcdSignature

instance SafeCopy GenesisConsensusData where
    getCopy =
        contain $
        do _gcdEpoch <- safeGet
           _gcdDifficulty <- safeGet
           return $! GenesisConsensusData {..}
    putCopy GenesisConsensusData {..} =
        contain $
        do safePut _gcdEpoch
           safePut _gcdDifficulty

instance SafeCopy SscPayload =>
         SafeCopy MainBody where
    getCopy = contain $ do
        _mbTxPayload     <- safeGet
        _mbSscPayload    <- safeGet
        _mbDlgPayload    <- safeGet
        _mbUpdatePayload <- safeGet
        return $! MainBody{..}
    putCopy MainBody {..} = contain $ do
        safePut _mbTxPayload
        safePut _mbSscPayload
        safePut _mbDlgPayload
        safePut _mbUpdatePayload

instance SafeCopy GenesisBody where
    getCopy =
        contain $
        do _gbLeaders <- safeGet
           return $! GenesisBody {..}
    putCopy GenesisBody {..} =
        contain $
        do safePut _gbLeaders

instance (Bi (MerkleRoot a), Typeable a) => SafeCopy (MerkleRoot a) where
    getCopy = getCopyBi
    putCopy = putCopyBi

instance (Bi (MerkleNode a), Typeable a) => SafeCopy (MerkleNode a) where
    getCopy = getCopyBi
    putCopy = putCopyBi

instance (Bi (MerkleTree a), Typeable a) => SafeCopy (MerkleTree a) where
    getCopy = getCopyBi
    putCopy = putCopyBi

instance SafeCopy h => SafeCopy (Attributes h) where
    getCopy =
        contain $
        do attrData <- safeGet
           attrRemain <- safeGet
           return $! Attributes {..}
    putCopy Attributes {..} =
        contain $
        do safePut attrData
           safePut attrRemain

instance Cereal.Serialize Byte where
    get = fromBytes <$> Cereal.get
    put = Cereal.put . toBytes

instance SafeCopy Byte

instance (SafeCopy k, SafeCopy v, Eq k, Hashable k) => SafeCopy (MM.MapModifier k v) where
    getCopy = contain $ MM.fromHashMap <$> safeGet
    putCopy mm = contain $ safePut (MM.toHashMap mm)

instance SafeCopy HeavyDlgIndex where
    getCopy = contain $ HeavyDlgIndex <$> safeGet
    putCopy x = contain $ safePut $ getHeavyDlgIndex x

instance SafeCopy LightDlgIndices where
    getCopy = contain $ LightDlgIndices <$> safeGet
    putCopy x = contain $ safePut $ getLightDlgIndices x

----------------------------------------------------------------------------
-- Plutus
----------------------------------------------------------------------------

instance Bi PLCore.Term => SafeCopy PLCore.Term where
    getCopy = getCopyBi
    putCopy = putCopyBi

instance Bi PLCore.Program => SafeCopy PLCore.Program where
    getCopy = getCopyBi
    putCopy = putCopyBi

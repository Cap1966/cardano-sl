{-|
Module      : Delegation
Description : Delegation Executable Model
Stability   : experimental

This is a stand-alone executable model for the delegation design.
-}

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PackageImports    #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Delegation
  ( SKey(..)
  , VKey(..)
  , HashKey(..)
  , hashKey
  , Sig(..)
  , StakePool(..)
  , Delegation(..)
  , Cert(..)
  , WitTxin(..)
  , WitCert(..)
  , Wits(..)
  , TxBody(..)
  , Tx(..)
  , Ledger(..)
  , ValidationError(..)
  , Validity(..)
  , LedgerState(..)
  , genesisState
  , genesisId
  , txid
  , asStateTransition
  , delegatedStake
  , retirePools
  ) where


import           Crypto.Hash           (Digest, SHA256, hash)
import qualified Data.ByteArray        as BA
import qualified Data.ByteString.Char8 as BS
import           Data.Foldable         (all)
import           Data.List             (find)
import           Data.Map              (Map)
import qualified Data.Map              as Map
import           Data.Maybe            (isJust, mapMaybe)
import           Data.Monoid           (Monoid)
import           Data.Semigroup        (Semigroup, (<>))
import           Data.Set              (Set)
import qualified Data.Set              as Set

import Delegation.UTxO


newtype SKey = SKey Owner deriving (Show, Eq, Ord)
newtype VKey = VKey Owner deriving (Show, Eq, Ord)
newtype HashKey = HashKey (Digest SHA256) deriving (Show, Eq, Ord)

hashKey :: VKey -> HashKey
hashKey key = HashKey $ hash key

data Sig a = Sig a Owner deriving (Show, Eq, Ord)

data StakePool = StakePool
                   { poolPubKey  :: VKey
                   , poolPledges :: Map VKey Coin
                   , poolCost    :: Coin
                   , poolMargin  :: Float -- TODO is float okay?
                   , poolAltAcnt :: Maybe HashKey
                   } deriving (Show, Eq, Ord)

data Delegation = Delegation { delegator :: VKey
                             , delegatee :: VKey }
                             deriving (Show, Eq, Ord)

data Cert = RegKey VKey
          | DeRegKey VKey --TODO this is actually HashKey on page 13, is that what we want?
          | RegPool StakePool
          | RetirePool VKey Int
          | Delegate Delegation
  deriving (Show, Eq, Ord)

getRequiredSigningKey :: Cert -> VKey
getRequiredSigningKey (RegKey key)          = key
getRequiredSigningKey (DeRegKey key)        = key
getRequiredSigningKey (RegPool pool)        = poolPubKey pool
getRequiredSigningKey (RetirePool key _)    = key
getRequiredSigningKey (Delegate delegation) = delegator delegation

data WitTxin = WitTxin VKey (Sig TxBody) deriving (Show, Eq, Ord)
data WitCert = WitCert VKey (Sig TxBody) deriving (Show, Eq, Ord)
data Wits = Wits { txinWits :: (Set WitTxin)
                 , certWits :: (Set WitCert)
                 } deriving (Show, Eq, Ord)

data TxBody = TxBody { inputs  :: Set TxIn
                     , outputs :: [TxOut]
                     , certs   :: Set Cert
                     } deriving (Show, Eq, Ord)
data Tx = Tx { body :: TxBody
             , wits :: Wits
             } deriving (Show, Eq)

instance BA.ByteArrayAccess Tx where
  length        = BA.length . BS.pack . show
  withByteArray = BA.withByteArray . BS.pack  . show

instance BA.ByteArrayAccess VKey where
  length        = BA.length . BS.pack . show
  withByteArray = BA.withByteArray . BS.pack . show

instance BA.ByteArrayAccess SKey where
  length        = BA.length . BS.pack . show
  withByteArray = BA.withByteArray . BS.pack . show

instance BA.ByteArrayAccess String where
  length        = BA.length . BS.pack
  withByteArray = BA.withByteArray . BS.pack

-- TODO how do I remove these boilerplate instances?

txid :: Tx -> TxId
txid = TxId . hash

txins :: Tx -> Set TxIn
txins = inputs . body

txouts :: Tx -> UTxO
txouts tx = UTxO $
  Map.fromList [(TxIn transId idx, out) | (out, idx) <- zip (outs tx) [0..]]
  where
    outs = outputs . body
    transId = txid tx

sign :: SKey -> a -> Sig a
sign (SKey k) d = Sig d k

verify :: Eq a => VKey -> a -> Sig a -> Bool
verify (VKey vk) vd (Sig sd sk) = vk == sk && vd == sd

type Ledger = [Tx]

data ValidationError = UnknownInputs
                     | IncreasedTotalBalance
                     | InsuffientTxWitnesses
                     | InsuffientCertWitnesses
                     | BadRegistration
                     | BadDeregistration
                     | BadDelegation
                     | BadPoolRegistration
                     | BadPoolRetirement
                     deriving (Show, Eq)
data Validity = Valid | Invalid [ValidationError] deriving (Show, Eq)

instance Semigroup Validity where
  Valid <> b                 = b
  a <> Valid                 = a
  (Invalid a) <> (Invalid b) = Invalid (a ++ b)

instance Monoid Validity where
  mempty = Valid
  mappend = (<>)

data LedgerState =
  LedgerState
  { getUtxo        :: UTxO
  , getAccounts    :: Map HashKey Coin
  , getStKeys      :: Set HashKey
  , getDelegations :: Map HashKey HashKey
  , getStPools     :: Set HashKey
  , getRetiring    :: Map HashKey Int
  , getEpoch       :: Int
  } deriving (Show, Eq)

genesisId :: TxId
genesisId = TxId $ hash "in the begining"

genesisState :: [TxOut] -> LedgerState
genesisState outs = LedgerState
  (UTxO (Map.fromList
    [((TxIn genesisId idx), out) | (idx, out) <- zip [0..] outs]
  ))
  Map.empty
  Set.empty
  Map.empty
  Set.empty
  Map.empty
  0

validInputs :: Tx -> LedgerState -> Validity
validInputs tx l =
  if (txins tx) `Set.isSubsetOf` unspentInputs (getUtxo l)
    then Valid
    else Invalid [UnknownInputs]
  where unspentInputs (UTxO utxo) = Map.keysSet utxo

preserveBalance :: Tx -> LedgerState -> Validity
preserveBalance tx l =
  if balance (txouts tx) <= balance (txins tx <| (getUtxo l))
    then Valid
    else Invalid [IncreasedTotalBalance]

authTxin :: VKey -> TxIn -> UTxO -> Bool
authTxin key txin (UTxO utxo) =
  case Map.lookup txin utxo of
    Just (TxOut (AddrTxin pay _) _) -> hash key == pay
    _                               -> False

witnessTxin :: Tx -> LedgerState -> Validity
witnessTxin (Tx txBody (Wits ws _)) l =
  if (Set.size ws) == (Set.size ins) && all (hasWitness ws) ins
    then Valid
    else Invalid [InsuffientTxWitnesses]
  where
    utxo = getUtxo l
    ins = inputs txBody
    hasWitness witnesses input =
      isJust $ find (isWitness txBody input utxo) witnesses
    isWitness tb inp unspent (WitTxin key sig) =
      verify key tb sig && authTxin key inp unspent

authCert :: VKey -> Cert -> Bool
authCert key cert = getRequiredSigningKey cert == key

witnessCert :: Tx -> Validity
witnessCert (Tx txBody (Wits _ ws)) =
  if (Set.size ws) == (Set.size cs) && all (hasWitness ws) cs
    then Valid
    else Invalid [InsuffientTxWitnesses]
  where
    cs = certs txBody
    hasWitness witnesses cert = isJust $ find (isWitness txBody cert) witnesses
    isWitness txBdy cert (WitCert key sig) =
      verify key txBdy sig && authCert key cert
--TODO combine with witnessTxin?

maxEpochRetirement :: Int
maxEpochRetirement = 100 -- TODO based on k? find a realistic value

validCert :: LedgerState -> Cert -> Validity

validCert ls (RegKey key) =
  if Set.notMember (hashKey key) (getStPools ls)
  then Valid
  else Invalid [BadRegistration]
  -- TODO spec mentions signing the public stake key. needed?

validCert ls (DeRegKey key) =
  if Set.member (hashKey key) (getStKeys ls)
  then Valid
  else Invalid [BadDeregistration]
  -- TODO spec mentions signing the public stake key. needed?

validCert ls (Delegate (Delegation _ poolKey)) =
  if Set.member (hashKey poolKey) (getStPools ls)
  then Valid
  else Invalid [BadDelegation]

validCert _ (RegPool _) =
  if True -- What exactly is being signed?
  then Valid
  else Invalid [BadPoolRegistration]

validCert ls (RetirePool _ epoch) =
  if (getEpoch ls) < epoch && epoch < maxEpochRetirement
  then Valid
  else Invalid [BadPoolRetirement]
  -- TODO What exactly is being signed?

validCerts :: Tx -> LedgerState -> Validity
validCerts (Tx (TxBody _ _ cs) _) ls = foldMap (validCert ls) cs

valid :: Tx -> LedgerState -> Validity
valid tx l =
  validInputs tx l
    <> preserveBalance tx l
    <> validCerts tx l
    <> witnessTxin tx l
    <> witnessCert tx

applyCert :: Cert -> LedgerState -> LedgerState
applyCert (RegKey key) ls = ls
  { getStKeys = (Set.insert (hashKey key) (getStKeys ls))
  , getAccounts = (Map.insert (hashKey key) (Coin 0) (getAccounts ls))}
applyCert (DeRegKey key) ls = ls
  { getStKeys = (Set.delete (hashKey key) (getStKeys ls))
  , getAccounts = Map.delete (hashKey key) (getAccounts ls)
  , getDelegations = Map.delete (hashKey key) (getDelegations ls)
    }
applyCert (Delegate (Delegation source target)) ls =
  ls {getDelegations =
    Map.insert (hashKey source) (hashKey target) (getDelegations ls)}
applyCert (RegPool sp) ls = ls
  { getStPools = (Set.insert hsk (getStPools ls))
  , getRetiring = Map.delete hsk (getRetiring ls)}
  where hsk = hashKey $ poolPubKey sp
applyCert (RetirePool key epoch) ls = ls {getRetiring = retiring}
  where retiring = Map.insert (hashKey key) epoch (getRetiring ls)

retirePools :: LedgerState -> Int -> LedgerState
retirePools ls epoch = ls
  { getStPools = Set.difference (getStPools ls) (Map.keysSet retiring)
  , getRetiring = active }
  where (active, retiring) = Map.partition ((/=) epoch) (getRetiring ls)

applyTxBody :: LedgerState -> Tx -> LedgerState
applyTxBody ls tx = ls { getUtxo = newUTxOs }
  where newUTxOs = (txins tx !<| (getUtxo ls) `union` txouts tx)

applyCerts :: LedgerState -> Set Cert -> LedgerState
applyCerts = Set.fold applyCert

applyTransaction :: LedgerState -> Tx -> LedgerState
applyTransaction ls tx = applyTxBody (applyCerts ls cs) tx
  where cs = (certs . body) tx

asStateTransition :: Tx -> LedgerState -> Either [ValidationError] LedgerState
asStateTransition tx ls =
  case valid tx ls of
    Invalid errors -> Left errors
    Valid          -> Right $ applyTransaction ls tx

delegatedStake :: LedgerState -> Map HashKey Coin
delegatedStake ls = Map.fromListWith mappend delegatedOutputs
  where
    getOutputs (UTxO utxo) = Map.elems utxo
    addStake delegations (TxOut (AddrTxin _ hsk) c) = do
      pool <- Map.lookup (HashKey hsk) delegations
      return (pool, c)
    addStake _ _ = Nothing
    outs = getOutputs . getUtxo $ ls
    delegatedOutputs = mapMaybe (addStake (getDelegations ls)) outs

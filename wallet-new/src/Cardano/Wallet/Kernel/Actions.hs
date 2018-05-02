
module Cardano.Wallet.Kernel.Actions
  ( WalletActions
  , WalletAction(..)
  , WalletActionInterp(..)
  , forkWalletWorker
  , walletWorker
  , interp
  , interpList
  ) where

import           Universum
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.Chan
import           Control.Lens (makeLenses, (%=), (.=), (+=), (-=), (<>=))

import           Pos.Block.Types
import           Pos.Util.Chrono

{-------------------------------------------------------------------------------
  Workers and helpers for performing wallet state updates
-------------------------------------------------------------------------------}

-- | Actions that can be invoked on a wallet, via a worker.
--   Workers may not respond directly to each action; for example,
--   a `RollbackBlocks` followed by several `ApplyBlocks` may be
--   batched into a single operation on the actual wallet.
data WalletAction b
  = ApplyBlocks    (OldestFirst NE b)
  | RollbackBlocks (NewestFirst NE b)
  | LogMessage Text

-- | Interface abstraction for the wallet worker.
--   The caller provides these primitive wallet operations;
--   the worker uses these to invoke changes to the
--   underlying wallet.
data WalletActionInterp m b = WalletActionInterp
  { applyBlocks :: OldestFirst NE b -> m ()
  , switchToFork :: Int -> OldestFirst [] b -> m ()
  , emit :: Text -> m ()
  }

-- | A channel for communicating with a wallet worker.
type WalletActions = Chan (WalletAction Blund)

-- | Internal state of the wallet worker.
data WalletWorkerState b = WalletWorkerState
  { _pendingRollbacks    :: !Int
  , _pendingBlocks       :: !(NewestFirst [] b)
  , _lengthPendingBlocks :: !Int
  }

makeLenses ''WalletWorkerState

-- A helper function for lifting a `WalletActionInterp` through a monad transformer.
lifted :: (Monad m, MonadTrans t) => WalletActionInterp m b -> WalletActionInterp (t m) b
lifted i = WalletActionInterp
  { applyBlocks  = lift . applyBlocks i
  , switchToFork = \n bs -> lift (switchToFork i n bs)
  , emit         = lift . emit i
  }

-- | `interp` is the main interpreter for converting a wallet action to a concrete
--   transition on the wallet worker's state, perhaps combined with some effects on
--   the concrete wallet.
interp :: Monad m => WalletActionInterp m b -> WalletAction b -> StateT (WalletWorkerState b) m ()
interp walletInterp action = do

  numPendingRollbacks <- use pendingRollbacks
  numPendingBlocks    <- use lengthPendingBlocks
  
  -- Respond to the incoming action
  case action of 

    -- If we are not in the midst of a rollback, just apply the blocks.
    ApplyBlocks bs | numPendingRollbacks == 0 -> do
                       emit "applying some blocks (non-rollback)"
                       applyBlocks bs

    -- Otherwise, add the blocks to the pending list. If the resulting
    -- list of pending blocks is longer than the number of pending rollbacks,
    -- then perform a `switchToFork` operation on the wallet.
    ApplyBlocks bs -> do

      -- Add the blocks
      pendingBlocks <>= toNewestFirst (toListChrono bs)
      lengthPendingBlocks += length bs

      -- If we have seen more blocks than rollbacks, switch to the new fork.
      when (numPendingBlocks + length bs > numPendingRollbacks) $ do

        pb <- toOldestFirst <$> use pendingBlocks
        switchToFork numPendingRollbacks pb
        
        -- Reset state to "no fork in progress"
        pendingRollbacks    .= 0
        lengthPendingBlocks .= 0
        pendingBlocks       .= NewestFirst []

    -- If we are in the midst of a fork and have seen some new blocks,
    -- roll back some of those blocks. If there are more rollbacks requested
    -- than the number of new blocks, see the next case below.
    RollbackBlocks bs | length bs <= numPendingBlocks -> do
                          lengthPendingBlocks -= length bs
                          pendingBlocks %= NewestFirst . drop (length bs) . getNewestFirst
              
    -- If we are in the midst of a fork and are asked to rollback more than
    -- the number of new blocks seen so far, clear out the list of new
    -- blocks and add any excess to the number of pending rollback operations.
    RollbackBlocks bs -> do
      pendingRollbacks    += length bs - numPendingBlocks
      lengthPendingBlocks .= 0
      pendingBlocks       .= NewestFirst []

    LogMessage txt -> emit txt

 where
   WalletActionInterp{..} = lifted walletInterp

-- | Connect a wallet action interpreter to a channel of actions.
walletWorker :: Chan (WalletAction b) -> WalletActionInterp IO b -> IO ()
walletWorker chan ops = do
  emit ops "Starting wallet worker."
  void $ (`evalStateT` initialWorkerState) $ forever $ 
    lift (readChan chan) >>= interp ops
  emit ops "Finishing wallet worker."

-- | Connect a wallet action interpreter to a stream of actions.
interpList :: Monad m => WalletActionInterp m b -> [WalletAction b] -> m ()
interpList ops actions = void $
  evalStateT (forM_ actions $ interp ops) initialWorkerState

initialWorkerState :: WalletWorkerState b
initialWorkerState = WalletWorkerState
                     { _pendingRollbacks    = 0
                     , _pendingBlocks       = NewestFirst []
                     , _lengthPendingBlocks = 0
                     }

-- | Start up a wallet worker; the worker will respond to actions issued over the
--   returned channel.
forkWalletWorker :: (MonadIO m, MonadIO m') => WalletActionInterp IO b -> m (WalletAction b -> m' ())
forkWalletWorker ops = liftIO $ do
  c <- newChan
  link =<< async (walletWorker c ops)
  return (liftIO . writeChan c)
             

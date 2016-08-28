module EventSourcing.Store.Memory
  ( MemoryEventStore (..)
  , memoryEventStoreTVar
  , memoryEventStoreIORef
  ) where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Data.Dynamic
import Data.Foldable (toList)
import Data.IORef
import Data.Maybe (mapMaybe)
import Data.Sequence (Seq, (><))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Safe (maximumDef)

import EventSourcing.Projection
import EventSourcing.Store.Class
import EventSourcing.UUID

data MemoryEventStore
  = MemoryEventStore { unMemoryEventStore :: Seq (DynamicStoredEvent Dynamic)}
  deriving (Show)

memoryEventStoreTVar :: IO (TVar MemoryEventStore)
memoryEventStoreTVar = newTVarIO (MemoryEventStore Seq.empty)

memoryEventStoreIORef :: IO (IORef MemoryEventStore)
memoryEventStoreIORef = newIORef (MemoryEventStore Seq.empty)

lookupMemoryEventStoreRaw :: MemoryEventStore -> UUID -> [DynamicStoredEvent Dynamic]
lookupMemoryEventStoreRaw (MemoryEventStore seq') uuid =
  filter ((==) uuid . dynamicStoredEventAggregateId) $ toList seq'

latestEventVersion' :: MemoryEventStore -> UUID -> EventVersion
latestEventVersion' store uuid = maximumDef (-1) $ dynamicStoredEventVersion <$> lookupMemoryEventStoreRaw store uuid

lookupMemoryEventStore :: (Typeable (Event proj)) => MemoryEventStore -> UUID -> [StoredEvent proj]
lookupMemoryEventStore store uuid =
  mapMaybe (dynamicEventToStored fromDynamic) $ lookupMemoryEventStoreRaw store uuid

lookupMemoryEventStoreSeq :: (Typeable event) => MemoryEventStore -> SequenceNumber -> [DynamicStoredEvent event]
lookupMemoryEventStoreSeq (MemoryEventStore seq') (SequenceNumber i) =
  mapMaybe dynamicEventFromDyn . toList $ Seq.drop i seq'

dynamicEventFromDyn :: (Typeable event) => DynamicStoredEvent Dynamic -> Maybe (DynamicStoredEvent event)
dynamicEventFromDyn (DynamicStoredEvent uuid version seqNum dynEvent) =
  DynamicStoredEvent uuid version seqNum <$> fromDynamic dynEvent

storeMemoryEventStore
  :: (Typeable (Event proj))
  => MemoryEventStore -> UUID -> [Event proj] -> (MemoryEventStore, [StoredEvent proj])
storeMemoryEventStore store@(MemoryEventStore seq') uuid events =
  let versStart = latestEventVersion' store uuid + 1
      seqStart = SequenceNumber (Seq.length seq') + 1
      dynEvents = zipWith3 (DynamicStoredEvent uuid) [versStart..] [seqStart..] events
      storedEvents = zipWith3 (StoredEvent (AggregateId uuid)) [versStart..] [seqStart..] events
      newSeq = seq' >< Seq.fromList (map (fmap toDyn) dynEvents)
  in (MemoryEventStore newSeq, storedEvents)

instance (MonadIO m, Typeable (Event proj)) => EventStore m (TVar MemoryEventStore) proj where
  getEvents tvar (AggregateId uuid) = liftIO $ flip lookupMemoryEventStore uuid <$> readTVarIO tvar
  storeEvents tvar (AggregateId uuid) events = liftIO . atomically $ do
    store <- readTVar tvar
    let (newMap, storedEvents) = storeMemoryEventStore store uuid events
    writeTVar tvar newMap
    return storedEvents
  latestEventVersion tvar (AggregateId uuid) = liftIO $ flip latestEventVersion' uuid <$> readTVarIO tvar

instance (MonadIO m) => SequencedEventStore m (TVar MemoryEventStore) Dynamic where
  getSequencedEvents tvar seqNum = liftIO $ do
    store <- readTVarIO tvar
    return $ lookupMemoryEventStoreSeq store seqNum

instance (MonadIO m) => EventStoreInfo m (TVar MemoryEventStore) where
  getAllUuids tvar = liftIO $ toList . Set.fromList . map dynamicStoredEventAggregateId . toList . unMemoryEventStore <$> readTVarIO tvar

instance (MonadIO m, Typeable (Event proj)) => EventStore m (IORef MemoryEventStore) proj where
  getEvents ref (AggregateId uuid) = liftIO $ flip lookupMemoryEventStore uuid <$> readIORef ref
  storeEvents ref (AggregateId uuid) events = liftIO $ do
    store <- readIORef ref
    let (newMap, storedEvents) = storeMemoryEventStore store uuid events
    writeIORef ref newMap
    return storedEvents
  latestEventVersion ref (AggregateId uuid) = liftIO $ flip latestEventVersion' uuid <$> readIORef ref

instance (MonadIO m) => SequencedEventStore m (IORef MemoryEventStore) Dynamic where
  getSequencedEvents ref seqNum = liftIO $ do
    store <- readIORef ref
    return $ lookupMemoryEventStoreSeq store seqNum

instance (MonadIO m) => EventStoreInfo m (IORef MemoryEventStore) where
  getAllUuids ref = liftIO $ toList . Set.fromList . map dynamicStoredEventAggregateId . toList . unMemoryEventStore <$> readIORef ref
{-# LANGUAGE QuasiQuotes #-}  -- This is here so Hlint doesn't choke

-- | Defines an Sqlite event store.

module EventSourcing.Store.Sqlite
  ( SqliteEvent (..)
  , SqliteEventId
  , migrateSqliteEvent
  , getAggregateIds
  , bulkInsert
  , sqliteMaxVariableNumber
  , SqliteEventStore
  , sqliteEventStore
  ) where

import Control.Monad.Reader
import Data.Aeson
import Data.List.Split (chunksOf)
import Data.Maybe (listToMaybe, mapMaybe, maybe)
import Database.Persist
import Database.Persist.Sql
import Database.Persist.TH

import EventSourcing.Aeson
import EventSourcing.Projection
import EventSourcing.Store.Class
import EventSourcing.UUID

share [mkPersist sqlSettings, mkMigrate "migrateSqliteEvent"] [persistLowerCase|
SqliteEvent sql=events
    Id SequenceNumber sql=sequence_number
    aggregateId UUID
    version EventVersion
    data JSONString
    UniqueAggregateVersion aggregateId version
    deriving Show
|]

sqliteEventToStored :: Entity SqliteEvent -> DynamicStoredEvent JSONString
sqliteEventToStored (Entity (SqliteEventKey seqNum) (SqliteEvent uuid version data')) =
  DynamicStoredEvent uuid version seqNum data'

-- sqliteEventFromSequenced :: StoredEvent event -> Entity SqliteEvent
-- sqliteEventFromSequenced (StoredEvent uuid version seqNum event) =
--   Entity (SqliteEventKey seqNum) (SqliteEvent uuid data' version)
--   where data' = toStrict (encode event)

getAggregateIds :: (MonadIO m) => ReaderT SqlBackend m [UUID]
getAggregateIds =
  fmap unSingle <$> rawSql "SELECT DISTINCT aggregate_id FROM events" []

getSqliteAggregateEvents :: (MonadIO m) => UUID -> ReaderT SqlBackend m [DynamicStoredEvent JSONString]
getSqliteAggregateEvents uuid = do
  entities <- selectList [SqliteEventAggregateId ==. uuid] [Asc SqliteEventVersion]
  return $ sqliteEventToStored <$> entities

getAllEventsFromSequence :: (MonadIO m) => SequenceNumber -> ReaderT SqlBackend m [DynamicStoredEvent JSONString]
getAllEventsFromSequence seqNum = do
  entities <- selectList [SqliteEventId >=. SqliteEventKey seqNum] [Asc SqliteEventId]
  return $ sqliteEventToStored <$> entities

maxEventVersion :: (MonadIO m) => UUID -> ReaderT SqlBackend m EventVersion
maxEventVersion uuid =
  let rawVals = rawSql "SELECT IFNULL(MAX(version), -1) FROM events WHERE aggregate_id = ?" [toPersistValue uuid]
  in maybe 0 unSingle . listToMaybe <$> rawVals

-- | Insert all items but chunk so we don't hit SQLITE_MAX_VARIABLE_NUMBER
bulkInsert
  :: ( MonadIO m
     , PersistStore (PersistEntityBackend val)
     , PersistEntityBackend val ~ SqlBackend
     , PersistEntity val
     )
  => [val]
  -> ReaderT (PersistEntityBackend val) m [Key val]
bulkInsert items = concat <$> forM (chunksOf sqliteMaxVariableNumber items) insertMany

-- | Search for SQLITE_MAX_VARIABLE_NUMBER here:
-- https://www.sqlite.org/limits.html
sqliteMaxVariableNumber :: Int
sqliteMaxVariableNumber = 999


data SqliteEventStore
  = SqliteEventStore
  { _sqliteEventStoreConnectionPool :: ConnectionPool
  }

sqliteEventStore :: (MonadIO m) => ConnectionPool -> m SqliteEventStore
sqliteEventStore pool = do
  -- Run migrations
  _ <- liftIO $ runSqlPool (runMigrationSilent migrateSqliteEvent) pool

  -- Create index on aggregate_id so retrieval is very fast
  liftIO $ runSqlPool
    (rawExecute "CREATE INDEX IF NOT EXISTS aggregate_id_index ON events (aggregate_id)" [])
    pool

  return $ SqliteEventStore pool

instance (MonadIO m, FromJSON (Event proj), ToJSON (Event proj)) => EventStore m SqliteEventStore proj where
  getEvents store (AggregateId uuid) = do
    rawEvents <- sqliteEventStoreGetEvents store uuid
    return $ mapMaybe (dynamicEventToStored decodeJSON) rawEvents
  storeEvents = sqliteEventStoreStoreEvents

  latestEventVersion store (AggregateId uuid) = sqliteEventStoreLatestEventVersion store uuid

instance (MonadIO m) => SequencedEventStore m SqliteEventStore JSONString where
  getSequencedEvents = sqliteEventStoreGetSequencedEvents

instance (MonadIO m) => EventStoreInfo m SqliteEventStore where
  getAllUuids = sqliteEventStoreGetUuids

sqliteEventStoreGetUuids :: (MonadIO m) => SqliteEventStore -> m [UUID]
sqliteEventStoreGetUuids (SqliteEventStore pool) =
  liftIO $ runSqlPool getAggregateIds pool

sqliteEventStoreGetEvents :: (MonadIO m) => SqliteEventStore -> UUID -> m [DynamicStoredEvent JSONString]
sqliteEventStoreGetEvents (SqliteEventStore pool) uuid =
  liftIO $ runSqlPool (getSqliteAggregateEvents uuid) pool

sqliteEventStoreGetSequencedEvents :: (MonadIO m) => SqliteEventStore -> SequenceNumber -> m [DynamicStoredEvent JSONString]
sqliteEventStoreGetSequencedEvents (SqliteEventStore pool) seqNum =
  liftIO $ runSqlPool (getAllEventsFromSequence seqNum) pool

sqliteEventStoreStoreEvents
  :: (MonadIO m, ToJSON (Event proj))
  => SqliteEventStore -> AggregateId proj -> [Event proj] -> m [StoredEvent proj]
sqliteEventStoreStoreEvents (SqliteEventStore pool) (AggregateId uuid) events =
  liftIO $ runSqlPool doInsert pool
  where
    doInsert = do
      versionNum <- maxEventVersion uuid
      let serialized = encodeJSON <$> events
          entities = zipWith (SqliteEvent uuid) [versionNum + 1..] serialized
      sequenceNums <- bulkInsert entities
      return $ zipWith3 (\(SqliteEventKey seqNum) vers event -> StoredEvent (AggregateId uuid) vers seqNum event)
        sequenceNums [versionNum + 1..] events

sqliteEventStoreLatestEventVersion
  :: (MonadIO m)
  => SqliteEventStore -> UUID -> m EventVersion
sqliteEventStoreLatestEventVersion (SqliteEventStore pool) uuid =
  liftIO $ runSqlPool (maxEventVersion uuid) pool

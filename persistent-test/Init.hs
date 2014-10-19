{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
module Init (
  (@/=), (@==), (==@)
  , assertNotEqual
  , assertNotEmpty
  , assertEmpty
  , isTravis
  , BackendMonad
  , runConn

  , MonadIO
  , persistSettings
  , MkPersistSettings (..)
#ifdef WITH_MONGODB
  , dbName
  , db'
  , setupMongo
  , mkPersistSettings
  , Action
  , MongoDB.MongoContext
#elif WITH_ZOOKEEPER
  , dbName
  , db'
  , setupZoo
  , mkPersistSettings
  , ZookeeperT
  , ZooStat
#else
  , db
  , sqlite_database
#endif
  , BackendKey(..)
  , generateKey

   -- re-exports
  , module Database.Persist
  , module Test.Hspec
  , module Test.HUnit
  , liftIO
  , mkPersist, mkMigrate, share, sqlSettings, persistLowerCase, persistUpperCase
  , Int32, Int64
  , Text
  , module Control.Monad.Trans.Reader
  , module Control.Monad
#ifndef WITH_MONGODB || WITH_ZOOKEEPER
  , module Database.Persist.Sql
#endif
) where

-- re-exports
import Control.Monad.Trans.Reader
import Test.Hspec
import Database.Persist.TH (mkPersist, mkMigrate, share, sqlSettings, persistLowerCase, persistUpperCase, MkPersistSettings(..))

-- testing
import Test.HUnit ((@?=),(@=?), Assertion, assertFailure, assertBool)
import Test.QuickCheck

import Database.Persist
import Database.Persist.TH ()
import Data.Text (Text, unpack)
import System.Environment (getEnvironment)

#ifdef WITH_MONGODB
import qualified Database.MongoDB as MongoDB
import Database.Persist.MongoDB (Action, withMongoPool, runMongoDBPool, defaultMongoConf, applyDockerEnv, BackendKey(..))
import Language.Haskell.TH.Syntax (Type(..))
import Database.Persist.TH (mkPersistSettings)
import qualified Data.ByteString as BS

import Control.Monad (void, replicateM, liftM)

#elif WITH_ZOOKEEPER
import qualified Database.Zookeeper as Z
import Database.Persist.Zookeeper (ZooStat, ZookeeperT, withZookeeperConn, runZookeeperPool, defaultZookeeperConf, BackendKey(..))
import Language.Haskell.TH.Syntax (Type(..))
import Database.Persist.TH (mkPersistSettings)
import Control.Monad (replicateM)
import qualified Data.ByteString as BS

import Control.Monad (void)

#else
import Control.Monad (liftM)
import Database.Persist.Sql
import Control.Monad.Trans.Resource (ResourceT, runResourceT)
import Control.Monad.Logger

#  if WITH_POSTGRESQL
import Database.Persist.Postgresql
#  else
#    ifndef WITH_MYSQL
import Database.Persist.Sqlite
#    endif
#  endif
#  if WITH_MYSQL
import Database.Persist.MySQL
#  endif
import Data.IORef (newIORef, IORef, writeIORef, readIORef)
import System.IO.Unsafe (unsafePerformIO)
#endif

import Control.Monad (unless, (>=>))
import Control.Monad.Trans.Control (MonadBaseControl)

-- Data types
import Data.Int (Int32, Int64)

import Control.Monad.IO.Class

(@/=), (@==), (==@) :: (Eq a, Show a, MonadIO m) => a -> a -> m ()
infix 1 @/= --, /=@
actual @/= expected = liftIO $ assertNotEqual "" expected actual

infix 1 @==, ==@
expected @== actual = liftIO $ expected @?= actual
expected ==@ actual = liftIO $ expected @=? actual

{-
expected /=@ actual = liftIO $ assertNotEqual "" expected actual
-}


assertNotEqual :: (Eq a, Show a) => String -> a -> a -> Assertion
assertNotEqual preface expected actual =
  unless (actual /= expected) (assertFailure msg)
  where msg = (if null preface then "" else preface ++ "\n") ++
             "expected: " ++ show expected ++ "\n to not equal: " ++ show actual

assertEmpty :: (Monad m, MonadIO m) => [a] -> m ()
assertEmpty xs    = liftIO $ assertBool "" (null xs)

assertNotEmpty :: (Monad m, MonadIO m) => [a] -> m ()
assertNotEmpty xs = liftIO $ assertBool "" (not (null xs))

isTravis :: IO Bool
isTravis = do
  env <- liftIO getEnvironment
  return $ case lookup "TRAVIS" env of
    Just "true" -> True
    _ -> False

#ifdef WITH_MONGODB
persistSettings :: MkPersistSettings
persistSettings = (mkPersistSettings $ ConT ''MongoDB.MongoContext) { mpsGeneric = True }

dbName :: Text
dbName = "persistent"

type BackendMonad = MongoDB.MongoContext
runConn :: (MonadIO m, MonadBaseControl IO m) => Action m backend -> m ()
runConn f = do
  conf <- liftIO $ applyDockerEnv $ defaultMongoConf dbName -- { mgRsPrimary = Just "replicaset" }
  void $ withMongoPool conf $ runMongoDBPool MongoDB.master f

setupMongo :: Action IO ()
setupMongo = void $ MongoDB.dropDatabase dbName


db' :: Action IO () -> Action IO () -> Assertion
db' actions cleanDB = do
  r <- runConn (actions >> cleanDB)
  return r

instance Arbitrary PersistValue where
    arbitrary = PersistObjectId `fmap` BS.pack `fmap` replicateM 12 arbitrary

#elif WITH_ZOOKEEPER
persistSettings :: MkPersistSettings
persistSettings = (mkPersistSettings $ ConT ''ZoosSat) { mpsGeneric = True }

dbName :: Text
dbName = "persistent"

type BackendMonad = MongoDB.MongoContext
runConn :: (MonadIO m, MonadBaseControl IO m) => ZookeeperT m backend -> m ()
runConn f = do
  conf <- liftIO $ applyDockerEnv $ defaultMongoConf dbName -- { mgRsPrimary = Just "replicaset" }
  void $ withMongoPool conf $ runMongoDBPool MongoDB.master f

setupZookeeper :: Action IO ()
setupZookeeper = void $ MongoDB.dropDatabase dbName


db' :: Action IO () -> Action IO () -> Assertion
db' actions cleanDB = do
  r <- runConn (actions >> cleanDB)
  return r

instance Arbitrary PersistValue where
    arbitrary = PersistObjectId `fmap` BS.pack `fmap` replicateM 12 arbitrary

#else
persistSettings :: MkPersistSettings
persistSettings = sqlSettings { mpsGeneric = True }
type BackendMonad = SqlBackend
sqlite_database :: Text
sqlite_database = "test/testdb.sqlite3"
-- sqlite_database = ":memory:"
runConn :: (MonadIO m, MonadBaseControl IO m) => SqlPersistT (NoLoggingT m) t -> m ()
runConn f = runNoLoggingT $ do
#  if WITH_POSTGRESQL
    travis <- liftIO isTravis
    _ <- if travis
      then withPostgresqlPool "host=localhost port=5432 user=postgres dbname=persistent" 1 $ runSqlPool f
      else withPostgresqlPool "host=localhost port=5432 user=test dbname=test password=test" 1 $ runSqlPool f
#  else
#    if WITH_MYSQL
    travis <- liftIO isTravis
    _ <- if not travis
      then withMySQLPool defaultConnectInfo
                        { connectHost     = "localhost"
                        , connectUser     = "test"
                        , connectPassword = "test"
                        , connectDatabase = "test"
                        } 1 $ runSqlPool f
      else withMySQLPool defaultConnectInfo
                        { connectHost     = "localhost"
                        , connectUser     = "travis"
                        , connectPassword = ""
                        , connectDatabase = "persistent"
                        } 1 $ runSqlPool f
#    else
    _<-withSqlitePool sqlite_database 1 $ runSqlPool f
#    endif
#  endif
    return ()

db :: SqlPersistT (NoLoggingT (ResourceT IO)) () -> Assertion
db actions = do
  runResourceT $ runConn $ actions >> transactionUndo

#if !MIN_VERSION_random(1,0,1)
instance Random Int32 where
    random g =
        let ((i::Int), g') = random g in
        (fromInteger $ toInteger i, g')
    randomR (lo, hi) g =
        let ((i::Int), g') = randomR (fromInteger $ toInteger lo, fromInteger $ toInteger hi) g in
        (fromInteger $ toInteger i, g')

instance Random Int64 where
    random g =
        let ((i0::Int32), g0) = random g
            ((i1::Int32), g1) = random g0 in
        (fromInteger (toInteger i0) + fromInteger (toInteger i1) * 2 ^ (32::Int), g1)
    randomR (lo, hi) g = -- TODO : generate on the whole range, and not only on a part of it
        let ((i::Int), g') = randomR (fromInteger $ toInteger lo, fromInteger $ toInteger hi) g in
        (fromInteger $ toInteger i, g')
#endif

instance Arbitrary PersistValue where
    arbitrary = PersistInt64 `fmap` choose (0, maxBound)
#endif

instance PersistStore backend => Arbitrary (BackendKey backend) where
  arbitrary = (errorLeft . fromPersistValue) `fmap` arbitrary
    where
      errorLeft x = case x of
          Left e -> error $ unpack e
          Right r -> r

#ifdef WITH_MONGODB
generateKey :: IO (BackendKey MongoDB.MongoContext)
generateKey = MongoKey `liftM` MongoDB.genObjectId
#else
keyCounter :: IORef Int64
keyCounter = unsafePerformIO $ newIORef 1
{-# NOINLINE keyCounter #-}

generateKey :: IO (BackendKey SqlBackend)
generateKey = do
    i <- readIORef keyCounter
    writeIORef keyCounter (i + 1)
    return $ SqlBackendKey $ i
#endif

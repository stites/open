{-# language OverloadedStrings, TupleSections #-}
module Dampf.Monitor where

import Dampf.Docker.Free (runDockerT)
import Dampf.Docker.Types (run)
import Dampf.Types

import Control.Lens
import Control.Monad            ((<=<))
import Control.Monad.Catch      (MonadThrow)
import Control.Monad.IO.Class   (MonadIO, liftIO)
import Control.Applicative      (pure, liftA2)

import System.Exit (exitFailure)
import Network.Wreq
import Data.Text (Text, unpack)
import Data.Monoid ((<>))
import Data.Maybe (catMaybes)
import Data.Map.Strict (Map)

import Text.Regex.Posix
import qualified Data.Map.Strict as Map

type Tests = [Text]

runMonitor :: (MonadIO m, MonadThrow m) => Tests -> DampfT m ()
runMonitor = mapM_ runUnits <=< tests_to_run where

  runUnits :: (MonadIO m, MonadThrow m) => (Text, TestSpec) -> DampfT m ()
  runUnits (test_name, TestSpec units _) = do
    reportLn $ "running " <> show test_name<> ": "
    mapM_ go units


  go :: (MonadIO m, MonadThrow m) => TestUnit -> DampfT m ()
  go (TestRun img cmd) = do
    report $ show cmd
    containers_to_run <- view $ app . containers . to (Map.filter (^. image . to (==img)))
    runDockerT $ mapM_ (run cmd) containers_to_run

  go (TestGet uri mb_pattern) = liftIO (get . unpack $ uri) >>= \res ->
    let res_code = view (responseStatus . statusCode) res

    in  report ("  " ++ unpack uri) *>
        if res_code /= 200
          then reportLn (" [FAIL] response code: " <> show res_code) *> liftIO exitFailure
          else case mb_pattern of
            Nothing -> reportLn " [OK]"
            Just pattern -> if view responseBody res =~ unpack pattern
              then reportLn " [OK]"
              else reportLn (" [FAIL] pattern " <> show pattern <> " didn't match") *> liftIO exitFailure

report :: (MonadIO m) => String -> DampfT m ()
report = liftIO . putStr

reportLn :: (MonadIO m) => String -> DampfT m ()
reportLn = liftIO . putStrLn


tests_to_run :: Monad m => Tests -> DampfT m [(Text, TestSpec)]
tests_to_run [] = all_tests <&> Map.toList
tests_to_run xs = all_tests <&> catMaybes . liftA2 (\k -> fmap (k,) . Map.lookup k) xs . pure

all_tests :: Monad m => DampfT m (Map Text TestSpec)
all_tests = view $ app . tests . to (Map.filter $ not . isOnlyAtBuild)

isOnlyAtBuild :: TestSpec -> Bool
isOnlyAtBuild (TestSpec _ whens) = [AtBuild] == whens

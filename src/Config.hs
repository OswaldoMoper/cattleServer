{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Config where

import           Control.Exception        (IOException, try)
import           Data.Aeson
import           Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy     as B
import           Data.Maybe               (fromMaybe)
import           GHC.Generics             (Generic)
import           System.Directory         (doesFileExist)
import           System.Environment       (getArgs, lookupEnv)
import           Time

data Host = Host
  { hostName :: String
  , userName :: String
  , userHome :: String
  } deriving (Generic, Show, Read)

instance FromJSON Host
instance ToJSON Host

data Route = Route
  { name      :: String
  , structure :: String
  } deriving (Generic, Show, Read)

instance FromJSON Route
instance ToJSON Route

data Config = Config
  { remoteHost      :: Host
  , keyDirectory    :: Route
  , portNumber      :: Integer
  , backupFrequency :: UnitTime
  , deleteFrequency :: UnitTime
  } deriving (Generic, Show, Read)

instance FromJSON Config
instance ToJSON Config

data App = App
  { appConfig      :: Route
  , databaseConfig :: Route
  , serviceConfig  :: Config
  } deriving (Generic, Show, Read)

instance FromJSON App
instance ToJSON App

data Service = Service
  { localHost  :: Host
  , knownHosts :: String
  , logDir     :: Maybe FilePath
  , apps       :: [App]
  }deriving (Generic, Show, Read)

instance FromJSON Service
instance ToJSON Service

-- | Where the configuration is read from when nothing else says otherwise.
-- Relative to the working directory, which is what makes it convenient for
-- development and unusable for a system service.
defaultConfigPath :: FilePath
defaultConfigPath = "./config/cattleServer.json"

-- | Path of the configuration file.
--
-- Resolution order:
--
--   1. the first non-empty command line argument;
--   2. the @CATTLESERVER_CONFIG@ environment variable;
--   3. 'defaultConfigPath'.
--
-- The argument is for running the service by hand against a scratch file; the
-- environment variable is for the systemd unit, which keeps @ExecStart@ clean.
resolveConfigPath :: IO FilePath
resolveConfigPath = do
  args <- getArgs
  case filter (not . null) args of
    (path:_) -> return path
    []       -> do
      m_env <- lookupEnv "CATTLESERVER_CONFIG"
      return $ case m_env of
        Just path | not (null path) -> path
        _                           -> defaultConfigPath

-- | Directory holding the service log and the per-application logs.
--
-- The default is the directory the log /reader/ has always used, so that
-- 'getLastBackup' keeps finding what the service writes. Those two agreed
-- only because the working directory happened to be a child of the local
-- user's home; now they are the same value.
resolveLogDir :: Service -> FilePath
resolveLogDir service =
  fromMaybe
    (userHome (localHost service) <> "/" <> defaultLogDirName)
    (logDir service)

readJSONconfig :: IO (Maybe Service)
readJSONconfig = resolveConfigPath >>= readJSONconfigFrom

readJSONconfigFrom :: FilePath -> IO (Maybe Service)
readJSONconfigFrom path = do
  fileExistance <- doesFileExist path
  case fileExistance of
    False -> do
      _ <- writeJSONconfigTo path
      return Nothing
    True -> do
      jsons <- B.readFile path
      return (decode jsons)

-- | Write the placeholder configuration.
--
-- Returns 'False' when the path is not writable, which is the normal case
-- once the configuration is managed out of band: a Nix store path, an agenix
-- secret, a systemd credential. The daemon must not die because it could not
-- write a template it does not need.
writeJSONconfigTo :: FilePath -> IO Bool
writeJSONconfigTo path = do
  attempt <- try (B.writeFile path (encodePretty exampleService))
  return $ case attempt of
    Right ()                -> True
    Left (_ :: IOException) -> False

-- | The placeholder configuration written when none is found.
exampleService :: Service
exampleService =
  let local =
        Host
        { hostName = "<localhost>"
        , userName = "<user>"
        , userHome = "/home/<user>"
        }
      appconfig =
        Route
        { name      = "Example"
        , structure = "/loads"
        }
      remote =
        Host
        { hostName = "0.0.0.0"
        , userName = "<remote-user>"
        , userHome = "/home/<remote-user>"
        }
      keys =
        Route
        { name      = "exampleKey-ed25519"
        , structure = "/home/<user>/.ssh"
        }
      database =
        Route
        { name      = "postgres"
        , structure = "yesod-project"
        }
      frequency =
        UnitTime
        { unit  = "Hours"
        , times = 8
        }
      delete =
        UnitTime
        { unit  = "Days"
        , times = 10
        }
      serviceconfig =
        Config
        { remoteHost      = remote
        , keyDirectory    = keys
        , portNumber      = 22
        , backupFrequency = frequency
        , deleteFrequency = delete
        }
      app =
        App
        { appConfig      = appconfig
        , databaseConfig = database
        , serviceConfig  = serviceconfig
        }
  in Service
     { localHost  = local
     , knownHosts = "/home/<user>/.ssh/known_hosts"
     , logDir     = Nothing
     , apps       = app : app : []
     }

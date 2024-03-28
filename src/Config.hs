{-# LANGUAGE DeriveGeneric #-}

module Config where

import           Data.Aeson
import           Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy     as B
import           GHC.Generics             (Generic)
import           System.Directory         (doesFileExist)
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
  , apps       :: [App]
  }deriving (Generic, Show, Read)

instance FromJSON Service
instance ToJSON Service

readJSONconfig :: IO (Maybe Service)
readJSONconfig = do
  fileExistance <- doesFileExist "./config/cattleServer.json"
  case fileExistance of
    False -> do
      writeJSONconfig
      return Nothing
    True -> do
      jsons <- B.readFile "./config/cattleServer.json"
      return (decode jsons)

writeJSONconfig :: IO ()
writeJSONconfig = do
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
      software =
        Service
        { localHost  = local
        , knownHosts = "/home/<user>/.ssh/known_hosts"
        , apps       = app : app : []
        }
  B.writeFile "./config/cattleServer.json" (encodePretty software)

{-# LANGUAGE DeriveGeneric #-}

module Config where

import           Data.Aeson
import           Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy     as B
import           GHC.Generics             (Generic)
import           System.Directory         (doesFileExist)

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
  { remoteHost     :: Host
  , localHost      :: Host
  , knownHosts     :: String
  , keyDirectory   :: Route
  , backupDatabase :: Route
  , portNumber     :: Integer
  -- , backupTime      :: Time
  } deriving (Generic, Show, Read)

instance FromJSON Config
instance ToJSON Config

data App = App
  { appConfig     :: Route
  , serviceConfig :: Config
  } deriving (Generic, Show, Read)

instance FromJSON App
instance ToJSON App

readJSONconfig :: IO (Maybe [App])
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
  let remote =
        Host
        { hostName = "0.0.0.0"
        , userName = "<remote-user>"
        , userHome = "/home/<remote-user>"
        }
      local =
        Host
        { hostName = "<localhost>"
        , userName = "<user>"
        , userHome = "/home/<user>"
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
      serviceconfig =
        Config
        { remoteHost      = remote
        , localHost       = local
        , knownHosts      = "/home/<user>/.ssh/known_hosts"
        , keyDirectory    = keys
        , backupDatabase  = database
        , portNumber      = 22
        }
      appconfig =
        Route
        { name      = "Example"
        , structure = "/loads"
        }
      app =
        App
        { appConfig     = appconfig
        , serviceConfig = serviceconfig
        }
  B.writeFile "./config/cattleServer.json" (encodePretty app)

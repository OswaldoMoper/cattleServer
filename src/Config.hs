{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Config where

import           Control.Exception        (IOException, try)
import           Data.Aeson
import           Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy     as B
import           Data.Maybe               (fromMaybe)
import qualified Data.Text                as T
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

-- | What to do when the remote host is not in the @known_hosts@ file.
--
-- The spellings mirror OpenSSH's @StrictHostKeyChecking@. Its @no@ is
-- deliberately not accepted: there it means "append and ignore conflicts",
-- which is not a state a typo should be able to reach.
data HostKeyPolicy
  = StrictHostKey
  -- ^ Never write to the file. An unknown host is refused.
  | AcceptNewHostKey
  -- ^ Trust on first use: add an unknown host, but never replace an entry
  -- that is already there.
  deriving (Eq, Show, Read)

-- | Parsed by hand rather than derived, so that an unrecognised value is an
-- error instead of a silent fallback. Getting this one wrong would either
-- disable the trust the operator asked for or grant trust they did not.
instance FromJSON HostKeyPolicy where
  parseJSON = withText "HostKeyPolicy" $ \t ->
    case T.toLower (T.strip t) of
      "strict"     -> pure StrictHostKey
      "yes"        -> pure StrictHostKey
      "accept-new" -> pure AcceptNewHostKey
      other        -> fail $ "expected \"strict\" or \"accept-new\", got "
                          <> show (T.unpack other)

instance ToJSON HostKeyPolicy where
  toJSON StrictHostKey    = String "strict"
  toJSON AcceptNewHostKey = String "accept-new"

data Config = Config
  { remoteHost         :: Host
  , keyDirectory       :: Route
  , portNumber         :: Integer
  , backupFrequency    :: UnitTime
  , deleteFrequency    :: UnitTime
  , hostKeys           :: Maybe [String]
  -- ^ Public keys of the remote host, as @known_hosts@ lines or bare
  -- @\<type\> \<base64\>@ pairs. Installed as they are, without asking the
  -- network what the host claims to be.
  , hostKeyFingerprint :: Maybe String
  -- ^ A @SHA256:@ fingerprint that a scanned key must match to be trusted.
  , keepAtLeast        :: Maybe Int
  -- ^ How many backups must survive whatever 'deleteFrequency' would remove.
  , remoteRsyncPath    :: Maybe String
  -- ^ Where @rsync@ lives on the remote, for when it is not on the @PATH@ a
  -- non-interactive @ssh host command@ gets -- which on NixOS is a short one.
  , alertAfter         :: Maybe Int
  -- ^ Hours without a successful backup before the alert command is run.
  -- Absent never alerts.
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
  { localHost     :: Host
  , knownHosts    :: String
  , logDir        :: Maybe FilePath
  , hostKeyPolicy :: Maybe HostKeyPolicy
  -- ^ Governs the @known_hosts@ file, which is why it sits here rather than
  -- on each application: there is one file for the whole service.
  , checkEvery    :: Maybe Int
  -- ^ Minutes between two passes over the applications.
  , startupDelay  :: Maybe Int
  -- ^ Minutes to wait before the first pass.
  , progressEvery :: Maybe Int
  -- ^ Seconds between two progress lines while a transfer runs.
  , verifyEvery   :: Maybe Int
  -- ^ Hours between re-reading a backup and checking it against its own
  -- manifest. Absent means never.
  , alertCommand  :: Maybe String
  -- ^ Shell command run when an application has gone too long without a
  -- successful backup, with the detail on its standard input.
  , apps          :: [App]
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

-- | The host key policy in force.
--
-- Defaults to 'AcceptNewHostKey' so a fresh deployment can establish trust
-- without anyone logging in by hand. Declare 'hostKeys' when the host's
-- identity is already known, which makes 'StrictHostKey' usable.
resolveHostKeyPolicy :: Service -> HostKeyPolicy
resolveHostKeyPolicy = fromMaybe AcceptNewHostKey . hostKeyPolicy

-- | Host keys declared for a connection, if any.
resolveHostKeys :: Config -> [String]
resolveHostKeys = fromMaybe [] . hostKeys

-- | How many backups have to survive a deletion.
--
-- 'deleteFrequency' removes by date and runs whether or not the backup that
-- preceded it succeeded, so on its own it will happily empty the directory
-- while backups have been failing for a week. This is the floor that stops
-- that: two, so that a corrupt newest backup still leaves one behind it.
resolveKeepAtLeast :: Config -> Int
resolveKeepAtLeast = max 0 . fromMaybe defaultKeepAtLeast . keepAtLeast

defaultKeepAtLeast :: Int
defaultKeepAtLeast = 2

-- | Minutes between two passes over the applications.
--
-- This is what bounds how /late/ a backup can be: an application due at some
-- point in its window is picked up on the next pass, so the interval is the
-- worst case delay. A pass only reads a log file when nothing is due, so
-- checking often is cheap. Clamped to a minute to rule out a busy loop.
resolveCheckEvery :: Service -> Int
resolveCheckEvery = max 1 . fromMaybe defaultCheckEvery . checkEvery

-- | Minutes to wait before the first pass.
--
-- Zero means the first pass happens at startup. Note what that implies on a
-- machine with no log yet: 'getLastBackup' reports the last backup as long
-- ago, so every application is due, and the service backs up as soon as it
-- starts.
resolveStartupDelay :: Service -> Int
resolveStartupDelay = max 0 . fromMaybe defaultStartupDelay . startupDelay

-- | Seconds between two progress lines while a transfer is running.
--
-- rsync reports several times a second; this is what turns that into
-- something a person can read without it burying everything else.
resolveProgressEvery :: Service -> Int
resolveProgressEvery = max 1 . fromMaybe defaultProgressEvery . progressEvery

defaultProgressEvery :: Int
defaultProgressEvery = 30

defaultCheckEvery :: Int
defaultCheckEvery = 30

defaultStartupDelay :: Int
defaultStartupDelay = 30

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
        { remoteHost         = remote
        , keyDirectory       = keys
        , portNumber         = 22
        , backupFrequency    = frequency
        , deleteFrequency    = delete
        , hostKeys           = Nothing
        , hostKeyFingerprint = Nothing
        , keepAtLeast        = Just defaultKeepAtLeast
        , remoteRsyncPath    = Nothing
        , alertAfter         = Nothing
        }
      app =
        App
        { appConfig      = appconfig
        , databaseConfig = database
        , serviceConfig  = serviceconfig
        }
  in Service
     { localHost     = local
     , knownHosts    = "/home/<user>/.ssh/known_hosts"
     , logDir        = Nothing
     , hostKeyPolicy = Just AcceptNewHostKey
     , checkEvery    = Just defaultCheckEvery
     , startupDelay  = Just defaultStartupDelay
     , progressEvery = Just defaultProgressEvery
     , verifyEvery   = Nothing
     , alertCommand  = Nothing
     , apps          = app : app : []
     }

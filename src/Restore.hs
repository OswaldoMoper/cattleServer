{-# LANGUAGE ScopedTypeVariables #-}

-- | Putting part of a copy back on the host it came from.
--
-- The two parts are restored separately because they are lost separately: a
-- database that came back new after a deploy, and uploads that went missing.
-- Neither ever replaces something the host still holds.
module Restore
  ( runRestore
  , restorePrelude
  , newEntry
  ) where

import           Control.Exception     (IOException, try)
import qualified Data.ByteString.Char8 as BC
import           Data.IORef            (modifyIORef', newIORef, readIORef)
import           Data.List             (intercalate)
import           Data.Maybe            (fromMaybe)
import           System.Directory      (canonicalizePath, doesDirectoryExist,
                                        getTemporaryDirectory, removeFile)
import           System.Exit           as E
import           System.IO             (hClose, hPutStrLn, openTempFile,
                                        stderr)

import           Config
import           Manifest              (verifyManifest)
import           Proc                  (runTool, runToolStreaming, shellQuote)
import           Time
import           Transport             (rsyncDiagnosis, rsyncSucceeded,
                                        sshArgs, sshCommand)

-- | Restore what was asked, and say how it went in the exit code: 0 it went
-- back, 1 it was attempted and did not, 2 it was never attempted.
--
-- The copy is checked against its own manifest first, so a copy that rotted
-- on this side is refused before anything is sent.
runRestore :: RestoreRequest -> Either String Service -> IO E.ExitCode
runRestore _ (Left err) = notAttempted err
runRestore request (Right service) =
  case filter ((== appName) . name . appConfig) (apps service) of
    []        -> notAttempted ("no application named " <> appName
                   <> "; configured: " <> intercalate ", " (map (name . appConfig) (apps service)))
    (app : _) -> do
      let logDirPath = resolveLogDir service
      _ <- ensureLogDir logDirPath
      found <- findCopy service request
      case found of
        Left err   -> notAttempted err
        Right copy -> do
          verified <- verifyManifest copy
          case verified of
            Left err -> notAttempted (copy <> " has no readable manifest: " <> err)
            Right (_, bad@(firstBad:_)) -> notAttempted
              (copy <> ": " <> show (length bad) <> " file(s) no longer match the manifest, first "
                <> firstBad)
            Right _ -> do
              let config = serviceConfig app
              case sshCommand (portNumber config) (knownHosts service) (keyDirectory config) (resolveConnectTimeout config) of
                Left err  -> notAttempted err
                Right ssh -> do
                  let logFilePath = appLogPath logDirPath appName
                  outcome <- case restorePart request of
                    RestoreDatabase guard  -> restoreDatabase service app ssh copy guard
                    RestoreUploads         -> restoreUploads app ssh copy
                  case outcome of
                    Right done -> do
                      writeLog logFilePath "Restored" done
                      putStrLn (appName <> ": " <> done)
                      return E.ExitSuccess
                    Left (code, err) -> do
                      writeLog logFilePath "Error" ("restore from " <> copy <> ": " <> err)
                      hPutStrLn stderr ("cattleServer: " <> appName <> ": " <> err)
                      return code
  where
    appName = restoreApp request

notAttempted :: String -> IO E.ExitCode
notAttempted err = do
  hPutStrLn stderr ("cattleServer: nothing was restored: " <> err)
  return (E.ExitFailure 2)

failed, refused :: String -> Either (E.ExitCode, String) a
failed err  = Left (E.ExitFailure 1, err)
refused err = Left (E.ExitFailure 2, err)

-- | The backup directory to restore from, with any link resolved so the log
-- names the copy that was actually used rather than @latest@.
findCopy :: Service -> RestoreRequest -> IO (Either String FilePath)
findCopy service request = do
  let given = fromMaybe
        (userHome (localHost service) <> "/backup/" <> restoreApp request <> "/" <> latestLinkName)
        (restoreFrom request)
  exists <- doesDirectoryExist given
  case exists of
    False -> return (Left ("there is no backup directory at " <> given))
    True  -> Right <$> canonicalizePath given

-- | Replace the database with the copy's dump, in one transaction that first
-- checks the guard allows it.
--
-- The check, the drop and the load are one transaction, so a database that
-- turns out not to be new is refused with nothing changed, and a dump that
-- fails halfway leaves the database as it was.
restoreDatabase :: Service -> App -> String -> FilePath -> DatabaseGuard -> IO (Either (E.ExitCode, String) String)
restoreDatabase service app ssh copy guard = do
  let config    = serviceConfig app
      database  = databaseConfig app
      remote    = remoteHost config
      target    = userName remote <> "@" <> hostName remote
      dump      = copy <> "/" <> structure database <> ".sql"
      remoteDir = userHome remote <> "/backup"
      staged    = remoteDir <> "/" <> structure database <> ".sql.restore"
  whole <- dumpLooksComplete dump
  case whole of
    Left err -> return (refused (dump <> ": " <> err))
    Right () -> do
      (mkExit, _, mkErr) <- runTool "ssh" (sshArgsOf service config ++ [target, "mkdir -p " <> shellQuote remoteDir]) ""
      case mkExit of
        E.ExitSuccess -> do
          (upExit, upErr) <- runToolStreaming "rsync"
            ([ "--times", "--compress", "--timeout=1800", "-e", ssh ]
               ++ rsyncPathArgs Nothing config
               ++ [ dump, target <> ":" <> staged ])
            (\_ -> return ())
          case rsyncSucceeded upExit of
            False -> return (failed ("sending the dump: " <> rsyncDiagnosis upExit upErr))
            True  -> do
              let script =
                    "{ printf '%s\\n' " <> shellQuote (restorePrelude guard)
                      <> "; cat " <> shellQuote staged
                      <> "; } | psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "
                      <> shellQuote (name database) <> " -d " <> shellQuote (structure database)
                      <> "; rc=$?; rm -f " <> shellQuote staged <> "; exit $rc"
              (loadExit, _, loadErr) <- runTool "ssh" (sshArgsOf service config ++ [target, script]) ""
              return $ case loadExit of
                E.ExitSuccess -> Right (structure database <> " restored from " <> copy)
                _             -> failed ("loading the dump: " <> lastLines loadErr)
        _ -> return (failed ("preparing " <> remoteDir <> ": " <> lastLines mkErr))

-- | The SQL run ahead of the dump, inside the same transaction.
--
-- A table that does not exist yet counts as empty: an application that has
-- not started has not created it. Table names are checked to be plain before
-- they get here, which is what lets them be spliced in.
restorePrelude :: DatabaseGuard -> String
restorePrelude guard = unlines $
  (case guard of
     OnlyIfEmpty tables ->
       [ "DO $cattle$ DECLARE n bigint; BEGIN"
       , concatMap guardTable tables
       , "END $cattle$;"
       ]
     ReplaceWhatIsThere -> [])
  ++
  [ "DROP SCHEMA IF EXISTS public CASCADE;"
  , "CREATE SCHEMA public;"
  ]
  where
    guardTable t =
      "IF to_regclass('public." <> t <> "') IS NOT NULL THEN "
        <> "EXECUTE 'SELECT count(*) FROM public." <> t <> "' INTO n; "
        <> "IF n > 0 THEN RAISE EXCEPTION 'public." <> t
        <> " has % row(s), so this database is not new; nothing was restored', n; END IF; "
        <> "END IF;\n"

-- | Put back the uploads the host does not have, and only those.
--
-- Two passes. The first asks rsync, without changing anything, which entries
-- would be created; the second sends exactly that list. One pass is not
-- enough: @--ignore-existing@ still updates the directories that exist, so an
-- owner or a mode meant for the restored files would land on the directories
-- the host already has, the top one included.
restoreUploads :: App -> String -> FilePath -> IO (Either (E.ExitCode, String) String)
restoreUploads app ssh copy = do
  let config  = serviceConfig app
      uploads = structure (appConfig app)
      remote  = remoteHost config
      target  = userName remote <> "@" <> hostName remote
      source  = copy <> "/" <> uploadDirName uploads <> "/"
      dest    = target <> ":" <> stripSlash uploads <> "/"
      common  = [ "--links", "--timeout=1800", "-e", ssh ]
                ++ rsyncPathArgs (uploadsOwner config) config
  present <- doesDirectoryExist source
  case present of
    False -> return (refused ("the copy holds no uploads at " <> source))
    True  -> do
      found <- newIORef []
      (dryExit, dryErr) <- runToolStreaming "rsync"
        (common ++ [ "--recursive", "--ignore-existing", "--dry-run", "--8-bit-output"
                   , "--out-format=%i %n", source, dest ])
        (\record -> maybe (return ()) (\p -> modifyIORef' found (p :)) (newEntry record))
      case rsyncSucceeded dryExit of
        False -> return (failed ("listing what is missing: " <> rsyncDiagnosis dryExit dryErr))
        True  -> do
          missing <- reverse <$> readIORef found
          case missing of
            [] -> return (Right ("nothing is missing from " <> uploads))
            _  -> do
              tmp <- getTemporaryDirectory
              (listPath, h) <- openTempFile tmp "cattleServer-restore.list"
              BC.hPutStr h (BC.pack (unlines missing))
              hClose h
              (sendExit, sendErr) <- runToolStreaming "rsync"
                (common ++ [ "--files-from=" <> listPath, "--no-implied-dirs", "--times" ]
                        ++ concat [ ["--chown=" <> o] | Just o <- [uploadsOwner config] ]
                        ++ concat [ ["--perms", "--chmod=" <> m] | Just m <- [uploadsMode config] ]
                        ++ [ source, dest ])
                (\_ -> return ())
              _ <- try (removeFile listPath) :: IO (Either IOException ())
              return $ case rsyncSucceeded sendExit of
                True  -> Right (show (length missing) <> " missing entr(ies) put back into "
                                  <> uploads <> " from " <> copy)
                False -> failed ("putting them back: " <> rsyncDiagnosis sendExit sendErr)

-- | The path of an entry the dry run would create, or 'Nothing' for anything
-- it would only update. Created entries have every attribute column set to
-- @+@: @>f+++++++++ name@, @cd+++++++++ dir/@.
newEntry :: String -> Maybe FilePath
newEntry record = case break (== ' ') record of
  (flags, ' ' : path)
    | length flags == 11, drop 2 flags == replicate 9 '+', not (null path) -> Just path
  _ -> Nothing

-- | Where rsync runs on the remote. Giving files away takes root, so an owner
-- routes it through @sudo -n@, which fails rather than waits for a password.
rsyncPathArgs :: Maybe String -> Config -> [String]
rsyncPathArgs owner config = case owner of
  Just _  -> [ "--rsync-path", "sudo -n " <> fromMaybe "rsync" (remoteRsyncPath config) ]
  Nothing -> concat [ ["--rsync-path", p] | Just p <- [remoteRsyncPath config] ]

sshArgsOf :: Service -> Config -> [String]
sshArgsOf service config =
  sshArgs (portNumber config) (knownHosts service) (keyDirectory config) (resolveConnectTimeout config)

stripSlash :: FilePath -> FilePath
stripSlash = reverse . dropWhile (== '/') . reverse

lastLines :: String -> String
lastLines s = case reverse (filter (not . null) (lines s)) of
  []    -> "no message"
  ls    -> intercalate " / " (reverse (take 3 ls))

-- | How cattleServer reaches a remote host with the external tools: the
-- @ssh@ command line it hands to rsync, and what rsync's exit says.
module Transport
  ( sshArgs
  , sshCommand
  , rsyncSucceeded
  , rsyncDiagnosis
  ) where

import           Config      (Route (..))
import           Data.Char   (isSpace)
import           System.Exit as E

-- | Whether an rsync run counts as having produced a backup.
--
-- 24 means files disappeared on the remote while it was copying. That is
-- ordinary for an uploads directory belonging to a live application, and does
-- not make what was copied wrong.
rsyncSucceeded :: ExitCode -> Bool
rsyncSucceeded E.ExitSuccess      = True
rsyncSucceeded (E.ExitFailure 24) = True
rsyncSucceeded _                  = False

-- | What an rsync exit code means, in words rather than as a number.
rsyncDiagnosis :: ExitCode -> String -> String
rsyncDiagnosis code err = case code of
  E.ExitFailure 127 ->
    "rsync is not on PATH here; the Nix wrapper and the unit's path are what "
      <> "put it there. " <> err
  E.ExitFailure 12  ->
    "the remote end did not speak rsync -- usually it is not installed there, "
      <> "or not on the short PATH a non-interactive ssh gets, which "
      <> "remoteRsyncPath exists to fix. " <> err
  E.ExitFailure 23  -> "some files could not be transferred: " <> err
  E.ExitFailure 30  -> "the transfer timed out: " <> err
  _                 -> err


-- | The arguments that identify this connection to @ssh@, without the host.
sshArgs :: Integer -> FilePath -> Route -> Int -> [String]
sshArgs port knownHost keys connectSecs =
  [ "-i", structure keys <> "/" <> name keys, "-p", show port
  , "-o", "IdentitiesOnly=yes"
  , "-o", "BatchMode=yes"
  , "-o", "StrictHostKeyChecking=yes"
  , "-o", "UserKnownHostsFile=" <> knownHost
  , "-o", "ConnectTimeout=" <> show connectSecs
  ]

-- | The @ssh@ command line rsync is told to use.
--
-- rsync splits this on whitespace and gives no way to quote, where @scp@ took
-- the same values as separate arguments. Refuse rather than emit a command
-- line that means something other than what the configuration says. Every
-- option value here is free of whitespace by construction, so only the two
-- paths need checking.
sshCommand :: Integer -> FilePath -> Route -> Int -> Either String String
sshCommand port knownHost keys connectSecs
  | any hasSpace [privateKey, knownHost] =
      Left ("rsync cannot be given a path containing whitespace: "
             <> unwords (filter hasSpace [privateKey, knownHost]))
  | otherwise = Right (unwords ("ssh" : sshArgs port knownHost keys connectSecs))
  where
    privateKey = structure keys <> "/" <> name keys
    hasSpace   = any isSpace

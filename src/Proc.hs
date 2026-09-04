{-# LANGUAGE ScopedTypeVariables #-}

-- | Total wrappers around "System.Process".
module Proc (runTool, shellQuote) where

import           Control.Exception (IOException, try)
import           System.Exit       (ExitCode (..))
import           System.Process    (readProcessWithExitCode)

-- | Run an external program, reporting a missing one as a failing exit code.
--
-- 'readProcessWithExitCode' /throws/ when the program is not on @PATH@ rather
-- than returning a non-zero code. Nothing in this service catches that, so a
-- missing @openssh@ would take the whole daemon down instead of failing one
-- backup. The exit code is the one a shell uses for a command it cannot find.
runTool :: String -> [String] -> String -> IO (ExitCode, String, String)
runTool prog args input = do
  attempt <- try (readProcessWithExitCode prog args input)
  return $ case attempt of
    Right result            -> result
    Left (e :: IOException) -> (ExitFailure 127, "", show e)

-- | Quote a string for interpolation into a POSIX shell command line.
shellQuote :: String -> String
shellQuote s = "'" <> concatMap escape s <> "'"
  where
    escape '\'' = "'\\''"
    escape c    = [c]

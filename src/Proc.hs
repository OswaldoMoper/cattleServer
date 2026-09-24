{-# LANGUAGE ScopedTypeVariables #-}

-- | Total wrappers around "System.Process".
module Proc (runTool, runToolStreaming, runAlert, shellQuote) where

import           Control.Concurrent      (forkIO)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import           Control.Exception       (IOException, try)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Char8   as BC
import           System.Exit             (ExitCode (..))
import           System.IO               (BufferMode (NoBuffering), Handle,
                                          hSetBinaryMode, hSetBuffering)
import           System.Process          (CreateProcess (..), StdStream (..),
                                          proc, readProcessWithExitCode,
                                          waitForProcess, withCreateProcess)

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

-- | Run an external program, handing each record of its output to a callback
-- as it arrives.
--
-- 'runTool' cannot do this: 'readProcessWithExitCode' returns once, at the
-- end, so a transfer that takes ten minutes says nothing for ten minutes.
--
-- Three things have to be right or a long run hangs. Records are split on
-- carriage returns as well as newlines, because that is how a program
-- overwrites a progress line in place and a line-oriented read would sit
-- there until it finished. Standard error is drained on its own thread,
-- because a child that fills the stderr pipe blocks while we are still
-- waiting on stdout and neither side moves again. And the exit status is
-- collected only once both are drained.
--
-- Output is decoded as bytes rather than through the locale, so an odd byte
-- in a filename cannot throw where the whole point is to keep reporting.
-- A missing program is reported the way 'runTool' reports it.
runToolStreaming :: String -> [String] -> (String -> IO ()) -> IO (ExitCode, String)
runToolStreaming prog args onRecord = do
  attempt <- try (withCreateProcess spec collect)
  return $ case attempt of
    Right result            -> result
    Left (e :: IOException) -> (ExitFailure 127, show e)
  where
    spec = (proc prog args) { std_in  = NoStream
                            , std_out = CreatePipe
                            , std_err = CreatePipe
                            }

    collect _ (Just out) (Just err) ph = do
      hSetBinaryMode out True
      hSetBuffering  out NoBuffering
      errVar <- newEmptyMVar
      _ <- forkIO (BS.hGetContents err >>= putMVar errVar)
      pump out ""
      errBytes <- takeMVar errVar
      code     <- waitForProcess ph
      return (code, BC.unpack errBytes)
    collect _ _ _ ph = do
      code <- waitForProcess ph
      return (code, "")

    pump :: Handle -> String -> IO ()
    pump h pending = do
      chunk <- BS.hGetSome h 4096
      case BS.null chunk of
        True  -> mapM_ onRecord (filter (not . null) [pending])
        False -> do
          let (records, pending') = splitRecords (pending <> BC.unpack chunk)
          mapM_ onRecord records
          pump h pending'

-- | Split a stream into records on carriage returns and newlines alike,
-- keeping whatever trailing fragment has not been terminated yet.
splitRecords :: String -> ([String], String)
splitRecords s =
  case break isRecordEnd s of
    (chunk, [])       -> ([], chunk)
    (chunk, _ : rest) ->
      let (records, pending) = splitRecords rest
      in  (filter (not . null) [chunk] <> records, pending)
  where
    isRecordEnd c = c == '\n' || c == '\r'

-- | Quote a string for interpolation into a POSIX shell command line.
shellQuote :: String -> String
shellQuote s = "'" <> concatMap escape s <> "'"
  where
    escape '\'' = "'\\''"
    escape c    = [c]

-- | Run an alert command in @sh@, with the detail on its standard input and
-- each pair exported to it as an environment variable, so a command can put
-- the application and what failed in a subject line rather than only in the
-- body.
runAlert :: String -> [(String, String)] -> String -> IO (ExitCode, String, String)
runAlert command vars body = runTool "sh" ["-c", exports <> command] body
  where
    exports = concat [ "export " <> k <> "=" <> shellQuote v <> "; " | (k, v) <- vars ]

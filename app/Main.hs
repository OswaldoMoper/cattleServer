module Main where

-- import           Data.Text
import           Data.Time.Clock              (getCurrentTime)
import           Data.Time.Format.ISO8601     (iso8601Show)
import           Network.SSH.Client.SimpleSSH
import           System.Exit                  hiding (ExitFailure)
import           System.IO
import           System.Process

path :: String
path = "/home/<remote-user>"

localPath :: String
localPath = "/home/<user>/backup"

sqlBackup :: String
sqlBackup = "/backup/yesod-project.sql"

host :: String
host = "0.0.0.0"

logFile :: String
logFile = "/cattleServer.log"

main :: IO ()
main = do
  loginResponse <- runSimpleSSH loginToServer
  case loginResponse of
    Left err      -> do
      writeLog $ ": Error\n" <> "Description: Fail to " <> show err <> "\n\n"
    Right session -> do
      putStrLn "SSH connection started"
      commandResponse <- runSimpleSSH $ databaseBackupInServer session
      case commandResponse of
        Left err     -> do
          hPutStrLn stderr $ "Error: " ++ show err
        Right result -> do
          printResponse result "yesod-project.sql created successfully"
          closeResponse <- runSimpleSSH $ closeSession session
          case closeResponse of
            Left err -> do
              hPutStrLn stderr $ "Error: " ++ show err
              exitFailure
            Right () -> do
              putStrLn "SSH connection closed"
              callCommand $ "scp -r admin@" <> host <> ":" <> path <> sqlBackup <> " " <> localPath
              callCommand $ "scp -r admin@" <> host <> ":" <> "/upload " <> localPath <> "/upload"

loginToServer :: SimpleSSH Session
loginToServer = do
  session <- openSession host 22 "/home/<user>/.ssh/known_hosts"
  auth_session <- authenticateWithKey session "<remote-user>" "/home/<user>/.ssh/exampleKey-ed25519.pub" "/home/<user>/.ssh/exampleKey-ed25519" ""
  return auth_session

databaseBackupInServer :: Session -> SimpleSSH Result
databaseBackupInServer session = do
  response <- execCommand session $ "pg_dump -U postgres yesod-project > " <> path <> sqlBackup
  return response

printResponse :: Result -> String -> IO ()
printResponse res success = do
  case resultExit res of
    ExitFailure 1 -> putStrLn $ show (resultErr res)
    _               -> do
      putStrLn $ show (resultExit res) <> ": " <> success -- resultExit must not print an error

writeLog :: String -> IO ()
writeLog message = do
  logs <- openFile (localPath <> logFile) AppendMode
  utcTime <- getCurrentTime
  hPutStr logs (iso8601Show utcTime <> message)
  hClose logs

{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Asking whether a site is up, in a way that says which part of it is not.
--
-- A name and the machine behind it fail separately, and only comparing them
-- says which. Everything here answers that question and nothing else: it takes
-- no backups and reads no configuration.
module Watch
  ( Verdict (..)
  , verdictTag
  , verdictKey
  , verdictDescription
  , isTrouble
  , checkSite
  , withCertificate
  , daysLeft
  ) where

import           Control.Exception        (IOException, SomeException,
                                           bracket, displayException, try)
import qualified Data.ByteString.Char8    as C8
import           Data.Default.Class       (def)
import           Data.Hourglass           (Elapsed (..), Seconds (..),
                                           timeGetElapsed)
import           Data.IORef               (newIORef, readIORef, writeIORef)
import           Data.List                (intercalate, isPrefixOf, nub)
import           Data.Maybe               (catMaybes)
import           Data.Time.Clock          (UTCTime, diffUTCTime)
import           Data.Time.Clock.POSIX    (posixSecondsToUTCTime)
import           Data.X509                (CertificateChain (..), certValidity,
                                           getCertificate)
import           Network.HTTP.Client      (HttpException (..), Manager, Request,
                                           httpNoBody, parseRequest,
                                           redirectCount, requestHeaders,
                                           responseStatus)
import           Network.HTTP.Types       (statusCode)
import           Network.Socket           (AddrInfo (..), NameInfoFlag (..),
                                           SockAddr, SocketType (Stream), close,
                                           connect, defaultHints, getAddrInfo,
                                           getNameInfo, openSocket)
import qualified Network.TLS              as TLS
import           Network.TLS.Extra.Cipher (ciphersuite_default)
import           System.IO.Error          (ioeGetErrorString)
import           System.Timeout           (timeout)

-- | What the site turned out to be doing. One constructor per person who
-- would have to act on it.
data Verdict
  = NameDoesNotResolve String
  -- ^ The name is out of its zone: expired, suspended, or the zone is gone.
  -- Whoever holds the registrar account.
  | ResolvesElsewhere [String] [String]
  -- ^ Expected addresses, then the ones it actually answers with. The zone
  -- changed, or something was put in front. Whoever holds the DNS.
  | NameDoesNotAnswer String
  -- ^ It resolves and the machine answers, but the name does not. The edge:
  -- a proxy, a certificate, a firewall.
  | AddressDoesNotAnswer String
  -- ^ Not the machine either. Whoever operates it.
  | CertificateExpiresSoon Int Integer
  -- ^ It answered, with this status, on a certificate this many days from
  -- expiry. The renewal has been failing unseen. Whoever operates the machine.
  | CertificateNotRead Int String
  -- ^ It answered, with this status, but its certificate could not be read,
  -- so its expiry is unknown. Not trouble: the visitor got through.
  | SiteIsUp Int
  -- ^ The status the name returned.
  deriving (Eq, Show)

-- | Whether a verdict is one somebody has to do something about.
isTrouble :: Verdict -> Bool
isTrouble (SiteIsUp code)           = code >= 400
isTrouble (CertificateNotRead _ _)  = False
isTrouble _                         = True

-- | A stable name for what a verdict found, for a command that sorts or files
-- alerts: the same string across releases, unlike the prose of the description.
verdictKey :: Verdict -> String
verdictKey verdict = case verdict of
  NameDoesNotResolve _       -> "name-does-not-resolve"
  ResolvesElsewhere _ _      -> "resolves-elsewhere"
  NameDoesNotAnswer _        -> "name-does-not-answer"
  AddressDoesNotAnswer _     -> "address-does-not-answer"
  CertificateExpiresSoon _ _ -> "certificate-expires-soon"
  CertificateNotRead _ _     -> "certificate-not-read"
  SiteIsUp code
    | code >= 400            -> "status-" <> show code
    | otherwise              -> "up"

verdictTag :: Verdict -> String
verdictTag (SiteIsUp code) | code < 400 = "Site up"
verdictTag (CertificateNotRead _ _)     = "Site up"
verdictTag _                            = "Site error"

verdictDescription :: String -> String -> Verdict -> String
verdictDescription url addr verdict = case verdict of
  NameDoesNotResolve err ->
    url <> " does not resolve: " <> err
      <> " -- the name is out of its zone, which is the registrar's to fix"
  ResolvesElsewhere want got ->
    url <> " resolves to " <> list got <> ", not to " <> list want
      <> " -- the zone changed, or something was put in front of it"
  NameDoesNotAnswer err ->
    url <> " resolves but does not answer: " <> err
      <> " -- the machine does, so this is the edge"
  AddressDoesNotAnswer err ->
    addr <> " does not answer either: " <> err <> " -- this one is the machine"
  CertificateExpiresSoon code days ->
    url <> " answered " <> show code <> ", but its certificate expires in "
      <> show days <> " day(s) -- the renewal is failing on the machine"
  CertificateNotRead code err ->
    url <> " answered " <> show code
      <> "; its certificate could not be read, so its expiry is unknown: " <> err
  SiteIsUp code ->
    url <> " answered " <> show code
  where
    list [] = "nothing"
    list xs = intercalate ", " xs

-- | Ask the name, then ask the address, and say which of the two failed.
--
-- The address has to be the machine that serves this URL, or the half of the
-- verdict that talks about the machine is about a different one.
checkSite :: Manager -> String -> String -> Maybe [String] -> IO Verdict
checkSite manager url addr expected = do
  resolved <- addressesOf (hostOf url)
  case resolved of
    Left err -> return (NameDoesNotResolve err)
    Right [] -> return (NameDoesNotResolve "no addresses")
    Right got -> case expected of
      Just want | not (any (`elem` want) got) -> return (ResolvesElsewhere want got)
      _ -> do
        byName <- getStatus manager url id
        case byName of
          Right code -> return (SiteIsUp code)
          Left nameErr -> do
            byAddr <- machineAnswers manager addr (hostOf url)
            return $ case byAddr of
              Right _      -> NameDoesNotAnswer nameErr
              Left addrErr -> AddressDoesNotAnswer addrErr

-- | Whether the machine itself answers, asked without TLS.
--
-- A certificate is issued to the name and never to the address, so asking the
-- address over HTTPS fails however healthy the machine is, and would blame it
-- for whatever the edge is doing. Plain HTTP asks the one thing this needs to
-- know. Redirects are not followed: a 301 to the name is the machine
-- answering, and following it would put the name back under test.
--
-- Its limit: a machine that serves only 443 is reported as not answering.
machineAnswers :: Manager -> String -> String -> IO (Either String Int)
machineAnswers manager addr host =
  getStatus manager ("http://" <> addr <> "/") (noRedirects . withHost host)

-- | Refine a site that answered over https with how long its certificate has
-- left. Every other verdict passes through unchanged.
--
-- The certificate is read on a connection of its own. The request that
-- answered already validated the chain, so this one trusts whatever it is
-- shown: it reads a date, it does not decide whether to believe the site.
withCertificate :: UTCTime -> Int -> String -> Verdict -> IO Verdict
withCertificate now minDays url verdict = case verdict of
  SiteIsUp code | code < 400, "https://" `isPrefixOf` url -> do
    expiry <- certificateExpiry (hostOf url) (portOf url)
    return $ case expiry of
      Left err -> CertificateNotRead code err
      Right notAfter
        | left < fromIntegral minDays -> CertificateExpiresSoon code left
        | otherwise                   -> verdict
        where left = daysLeft now notAfter
  _ -> return verdict

-- | Whole days from one instant to another, rounded down.
daysLeft :: UTCTime -> UTCTime -> Integer
daysLeft now later = floor (diffUTCTime later now / 86400)

-- | When the certificate a host presents stops being valid.
certificateExpiry :: String -> String -> IO (Either String UTCTime)
certificateExpiry host port = do
  seen <- newIORef Nothing
  let hooks = def
        { TLS.onServerCertificate = \_ _ _ chain -> writeIORef seen (Just chain) >> return [] }
      params = (TLS.defaultParamsClient host "")
        { TLS.clientHooks     = hooks
        , TLS.clientSupported = def { TLS.supportedCiphers = ciphersuite_default }
        }
      hints = defaultHints { addrSocketType = Stream }
      handshake = do
        infos <- getAddrInfo (Just hints) (Just host) (Just port)
        case infos of
          []       -> ioError (userError "no addresses")
          (info:_) -> bracket (openSocket info) close $ \sock -> do
            connect sock (addrAddress info)
            ctx <- TLS.contextNew sock params
            TLS.handshake ctx
            TLS.bye ctx
  attempt <- try (timeout (10 * 1000000) handshake)
  chain <- readIORef seen
  return $ case (attempt, chain) of
    (_, Just (CertificateChain (leaf:_))) ->
      let Elapsed (Seconds s) = timeGetElapsed (snd (certValidity (getCertificate leaf)))
      in Right (posixSecondsToUTCTime (fromIntegral s))
    (Right Nothing, _)                   -> Left "timed out after 10 seconds"
    (Left (e :: SomeException), _)       -> Left (firstLine (displayException e))
    (Right (Just ()), _)                 -> Left "the server presented no certificate"

-- | The addresses a name answers with, or why it answers with none.
addressesOf :: String -> IO (Either String [String])
addressesOf host = do
  let hints = defaultHints { addrSocketType = Stream }
  attempt <- try (getAddrInfo (Just hints) (Just host) Nothing)
  case attempt of
    Left e      -> return (Left (ioeGetErrorString (e :: IOException)))
    Right infos -> Right . nub . catMaybes <$> mapM (numeric . addrAddress) infos

-- | One socket address written the way people write addresses.
numeric :: SockAddr -> IO (Maybe String)
numeric sockAddr = do
  named <- try (getNameInfo [NI_NUMERICHOST] True False sockAddr)
  return $ case named of
    Right (host, _)         -> host
    Left (_ :: IOException) -> Nothing

-- | The status a request comes back with, or why it did not come back.
getStatus :: Manager -> String -> (Request -> Request) -> IO (Either String Int)
getStatus manager url adjust = do
  attempt <- try (parseRequest url >>= \req -> httpNoBody (adjust req) manager)
  return $ case attempt of
    Left e         -> Left (describeHttp e)
    Right response -> Right (statusCode (responseStatus response))

-- | Ask the address for a named site, rather than for whichever it serves by
-- default.
withHost :: String -> Request -> Request
withHost host req =
  req { requestHeaders = ("Host", C8.pack host) : requestHeaders req }

noRedirects :: Request -> Request
noRedirects req = req { redirectCount = 0 }

-- | The part of an HTTP failure worth putting in an alert: the exception's own
-- rendering carries the whole request with it, which buries the reason.
describeHttp :: HttpException -> String
describeHttp (HttpExceptionRequest _ content) = firstLine (show content)
describeHttp (InvalidUrlException url why)    = url <> ": " <> why

hostOf :: String -> String
hostOf = takeWhile (\c -> c /= '/' && c /= ':') . dropScheme

-- | The port a URL names, or the one its scheme implies.
portOf :: String -> String
portOf u = case dropWhile (/= ':') (takeWhile (/= '/') (dropScheme u)) of
  ':' : p@(_:_)                 -> p
  _ | "http://" `isPrefixOf` u -> "80"
    | otherwise                -> "443"

dropScheme :: String -> String
dropScheme s
  | take 8 s == "https://" = drop 8 s
  | take 7 s == "http://"  = drop 7 s
  | otherwise              = s

firstLine :: String -> String
firstLine s = case filter (not . null) (lines s) of
  (l:_) -> take 200 l
  []    -> "no message"

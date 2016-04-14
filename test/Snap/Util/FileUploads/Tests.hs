{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snap.Util.FileUploads.Tests
  ( tests ) where

------------------------------------------------------------------------------
import           Control.Applicative            (Alternative ((<|>)))
import           Control.DeepSeq                (deepseq)
import           Control.Exception              (ErrorCall (..), evaluate, throwIO)
import           Control.Exception.Lifted       (Exception (fromException, toException), Handler (Handler), catch, catches, finally, throw)
import           Control.Monad                  (Monad (return, (>>), (>>=)), liftM, void)
import           Control.Monad.IO.Class         (MonadIO (liftIO))
import           Data.ByteString                (ByteString)
import qualified Data.ByteString.Char8          as S
import           Data.IORef                     (atomicModifyIORef, newIORef, readIORef, writeIORef)
import           Data.List                      (foldl', length)
import qualified Data.Map                       as Map
import           Data.Maybe                     (Maybe (..), fromJust, maybe)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.Typeable                  (Typeable)
import           Prelude                        (Bool (..), Either (..), Eq (..), FilePath, IO, Int, Num (..), Show (..), const, either, error, filter, map, print, seq, snd, ($), ($!), (&&), (++), (.))
import           Snap.Internal.Core             (EscapeSnap (TerminateConnection), Snap, getParam, getPostParam, getQueryParam, runSnap)
import           Snap.Internal.Http.Types       (Request (rqBody), Response, setHeader)
import           Snap.Internal.Util.FileUploads (BadPartException (..), FileUploadException (..), PartDisposition (..), PartInfo (..), PolicyViolationException (..), allowWithMaximumSize, defaultUploadPolicy, disallow, doProcessFormInputs, fileUploadExceptionReason, getMaximumNumberOfFormInputs, getMinimumUploadRate, getMinimumUploadSeconds, getUploadTimeout, handleFileUploads, setMaximumFormInputSize, setMaximumNumberOfFormInputs, setMinimumUploadRate, setMinimumUploadSeconds, setProcessFormInputs, setUploadTimeout, toPartDisposition)
import qualified Snap.Test                      as Test
import           Snap.Test.Common               (coverEqInstance, coverShowInstance, coverTypeableInstance, eatException, expectExceptionH, seconds, waitabit)
import qualified Snap.Types.Headers             as H
import           System.Directory               (createDirectoryIfMissing, getDirectoryContents, removeDirectoryRecursive)
import           System.IO.Streams              (RateTooSlowException)
import qualified System.IO.Streams              as Streams
import           System.Mem                     (performGC)
import           System.Timeout                 (timeout)
import           Test.Framework                 (Test)
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit                     (assertBool, assertEqual)
------------------------------------------------------------------------------


------------------------------------------------------------------------------
data TestException = TestException
  deriving (Show, Typeable)

instance Exception TestException

------------------------------------------------------------------------------
tests :: [Test]
tests = [ testSuccess1
        , testSuccess2
        , testRfc2231
        , testBadParses
        , testPerPartPolicyViolation1
        , testPerPartPolicyViolation2
        , testFormInputsPolicyViolation
        , testFormSizePolicyViolation
        , testNoFileName
        , testNoFileNameTooBig
        , testTooManyHeaders
        , testNoBoundary
        , testNoMixedBoundary
        , testWrongContentType
        , testSlowEnumerator
        , testSlowEnumerator2
        , testAbortedBody
        , testTrivials
        , testDisconnectionCleanup
        ]


------------------------------------------------------------------------------
testSuccess1 :: Test
testSuccess1 = testCase "fileUploads/success1" $
               harness tmpdir hndl mixedTestBody

  where
    tmpdir = "tempdir1"

    hndl = do
        xs <- handleFileUploads tmpdir
                                defaultUploadPolicy
                                (const $ allowWithMaximumSize 300000)
                               hndl'

        let fileMap = foldl' f Map.empty xs
        p1  <- getParam "field1"
        p1P <- getPostParam "field1"
        p1Q <- getQueryParam "field1"
        p2  <- getParam "field2"

        liftIO $ do
            let Just (a1, a2, a3) = Map.lookup "file1.txt" fileMap
            let Just (b1, b2, b3) = Map.lookup "file2.gif" fileMap
            assertEqual "file1 contents"
                        ("text/plain", file1Contents)
                        (a1, a2)
            assertEqual "file1 header 1"
                        (Just "text/plain")
                        (H.lookup "content-type" a3)
            assertEqual "file1 header 2"
                        (Just "attachment; filename=\"file1.txt\"")
                        (H.lookup "content-disposition" a3)

            assertEqual "file2 contents"
                        ("image/gif", file2Contents)
                        (b1, b2)
            assertEqual "file2 header 1"
                        (Just "image/gif")
                        (H.lookup "content-type" b3)
            assertEqual "file2 header 2"
                        (Just "attachment; filename=\"file2.gif\"")
                        (H.lookup "content-disposition" b3)

            assertEqual "field1 contents"
                        (Just formContents1)
                        p1

            assertEqual "field1 POST contents" (Just formContents1) p1P
            assertEqual "field1 query contents" Nothing p1Q
            assertEqual "field2 contents" (Just formContents2) p2

    f mp (fn, ct, x, hdrs) = Map.insert fn (ct,x,hdrs) mp

    hndl' partInfo =
        either throw
               (\fp -> do
                    x <- liftIO $ S.readFile fp
                    let fn = fromJust $ partFileName partInfo
                    let ct = partContentType partInfo
                    let hdrs = partHeaders partInfo
                    return (fn, ct, x, hdrs))


------------------------------------------------------------------------------
testSuccess2 :: Test
testSuccess2 = testCase "fileUploads/success2" $
               harness tmpdir hndl mixedTestBody

  where
    tmpdir = "tempdir2"

    policy = setProcessFormInputs False defaultUploadPolicy

    hndl = do
        ref <- liftIO $ newIORef (0::Int)
        _ <- handleFileUploads tmpdir
                               policy
                               (const $ allowWithMaximumSize 300000)
                               (hndl' ref)

        n <- liftIO $ readIORef ref
        liftIO $ assertEqual "num params" 4 n

    hndl' !ref !_ !_ = atomicModifyIORef ref (\x -> (x+1, ()))


------------------------------------------------------------------------------
testRfc2231 :: Test
testRfc2231 = testCase "fileUploads/rfc2231" $
               harness tmpdir hndl rfc2231TestBody

  where
    tmpdir = "tempdir1"

    hndl = do
        xs <- handleFileUploads tmpdir
                                defaultUploadPolicy
                                (const $ allowWithMaximumSize 300000)
                               hndl'
        liftIO $ print xs
        liftIO $ assertEqual "Returned all files" 1 (length xs)
        let [(fn, _, _, hdrs)] = xs

        liftIO $ do
            assertEqual "File name decoded from utf" fn rfc2231FileNameUtf8

    f mp (fn, ct, x, hdrs) = Map.insert fn (ct,x,hdrs) mp

    hndl' partInfo =
        either throw
               (\fp -> do
                    x <- liftIO $ S.readFile fp
                    let fn = fromJust $ partFileName partInfo
                    let ct = partContentType partInfo
                    let hdrs = partHeaders partInfo
                    return (fn, ct, x, hdrs))


------------------------------------------------------------------------------
testBadParses :: Test
testBadParses = testCase "fileUploads/badParses" $ do
                harness tmpdir hndl mixedTestBodyWithBadTypes
  where
    tmpdir = "tempdir_bad_types"

    hndl = do
        xs <- handleFileUploads tmpdir
                                defaultUploadPolicy
                                (const $ allowWithMaximumSize 300000)
                                hndl'

        let fileMap = foldl' f Map.empty xs
        p1   <- getParam "field1"
        p1P  <- getPostParam "field1"
        p1Q  <- getQueryParam "field1"
        p2   <- getParam "field2"
        pBoo <- getParam "boo"

        liftIO $ do
            assertEqual "file1 contents"
                        (Just ("text/plain", file1Contents))
                        (Map.lookup "file1.txt" fileMap)

            assertEqual "file2 contents"
                        (Just ("text/plain", file2Contents))
                        (Map.lookup "file2.gif" fileMap)

            assertEqual "field1 param contents" (Just formContents1) p1
            assertEqual "field1 POST contents" (Just formContents1) p1P
            assertEqual "field1 query contents" Nothing p1Q
            assertEqual "field2 contents" Nothing p2
            assertEqual "boo contents" (Just "boo") pBoo

    f mp (fn, ct, x) = Map.insert fn (ct,x) mp

    hndl' partInfo =
        either throw
               (\fp -> do
                    x <- liftIO $ S.readFile fp
                    let fn = fromJust $ partFileName partInfo
                    let ct = partContentType partInfo
                    return (fn, ct, x))



------------------------------------------------------------------------------
testPerPartPolicyViolation1 :: Test
testPerPartPolicyViolation1 = testCase "fileUploads/perPartPolicyViolation1" $
                              harness tmpdir hndl mixedTestBody
  where
    tmpdir = "tempdir_pol1"

    hndl = do
        _ <- handleFileUploads tmpdir defaultUploadPolicy
                               (const disallow)
                               hndl'

        p1 <- getParam "field1"
        p2 <- getParam "field2"


        liftIO $ do
            assertEqual "field1 contents"
                        (Just formContents1)
                        p1

            assertEqual "field2 contents"
                        (Just formContents2)
                        p2

    hndl' !_ e = either (\i -> show i `deepseq` return $! ())
                        (const $ error "expected policy violation")
                        e


------------------------------------------------------------------------------
testPerPartPolicyViolation2 :: Test
testPerPartPolicyViolation2 = testCase "fileUploads/perPartPolicyViolation2" $
                              harness tmpdir hndl mixedTestBody
  where
    tmpdir = "tempdir_pol2"

    hndl = handleFileUploads tmpdir defaultUploadPolicy
                             (const $ allowWithMaximumSize 4)
                             hndl'

    hndl' partInfo e = (if partFileName partInfo == Just "file1.txt"
                          then ePass
                          else eFail) e

    eFail = either (\i -> show i `deepseq` return ())
                   (const $ error "expected policy violation")

    ePass = either (throw)
                   (\i -> show i `deepseq` return ())



------------------------------------------------------------------------------
testNoFileName :: Test
testNoFileName = testCase "fileUploads/noFileName" $
                 (harness tmpdir hndl noFileNameTestBody)
  where
    tmpdir = "tempdir_noname"

    hndl = handleFileUploads tmpdir defaultUploadPolicy
                             (const $ allowWithMaximumSize 400000)
                             hndl'

    hndl' pinfo !_ = do
        assertEqual "filename" Nothing $ partFileName pinfo
        assertEqual "disposition" DispositionFile $ partDisposition pinfo


------------------------------------------------------------------------------
testNoFileNameTooBig :: Test
testNoFileNameTooBig = testCase "fileUploads/noFileNameTooBig" $
                       (harness tmpdir hndl noFileNameTestBody `catch` h)
  where
    h !(e :: FileUploadException) = do
        let r = fileUploadExceptionReason e
        assertBool "correct exception"
                   (T.isInfixOf "form input" r &&
                    T.isInfixOf "exceeded maximum permissible" r)

    tmpdir = "tempdir_noname_toobig"

    hndl = handleFileUploads tmpdir defaultUploadPolicy
                             (const $ allowWithMaximumSize 1)
                             hndl'

    hndl' pinfo !e = do
        let (Left !x) = e
        coverShowInstance x
        assertEqual "filename" Nothing $ partFileName pinfo
        assertEqual "disposition" DispositionFile $ partDisposition pinfo


------------------------------------------------------------------------------
testFormSizePolicyViolation :: Test
testFormSizePolicyViolation = testCase "fileUploads/formSizePolicy" $
                              (harness tmpdir hndl mixedTestBody `catch` h)
  where
    h !(e :: FileUploadException) = do
        let r = fileUploadExceptionReason e
        assertBool "correct exception"
                   (T.isInfixOf "form input" r &&
                    T.isInfixOf "exceeded maximum permissible" r)

    tmpdir = "tempdir_formpol"

    policy = setMaximumFormInputSize 2 defaultUploadPolicy

    hndl = handleFileUploads tmpdir policy
                             (const $ allowWithMaximumSize 4)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testFormInputsPolicyViolation :: Test
testFormInputsPolicyViolation = testCase "fileUploads/formInputsPolicy" $
                                (harness tmpdir hndl mixedTestBody `catch` h)
  where
    h !(e :: FileUploadException) = do
        let r = fileUploadExceptionReason e
        assertBool "correct exception"
                   (T.isInfixOf "number of form inputs" r &&
                    T.isInfixOf "exceeded maximum" r)

    tmpdir = "tempdir_formpol2"

    policy = setMaximumNumberOfFormInputs 0 defaultUploadPolicy

    hndl = handleFileUploads tmpdir policy
                             (\x -> x `seq` allowWithMaximumSize 4000)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testNoBoundary :: Test
testNoBoundary = testCase "fileUploads/noBoundary" $
                 expectExceptionH $
                 harness' goBadContentType tmpdir hndl mixedTestBody
  where
    tmpdir = "tempdir_noboundary"

    hndl = handleFileUploads tmpdir
                             defaultUploadPolicy
                             (const $ allowWithMaximumSize 300000)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testNoMixedBoundary :: Test
testNoMixedBoundary = testCase "fileUploads/noMixedBoundary" $
                      expectExceptionH $
                      harness' go tmpdir hndl badMixedBody
  where
    tmpdir = "tempdir_mixednoboundary"

    hndl = handleFileUploads tmpdir
                             defaultUploadPolicy
                             (const $ allowWithMaximumSize 300000)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testWrongContentType :: Test
testWrongContentType = testCase "fileUploads/wrongContentType" $
                       expectExceptionH $
                       harness' goWrongContentType tmpdir hndl mixedTestBody
  where
    tmpdir = "tempdir_noboundary"

    hndl = handleFileUploads tmpdir
                             defaultUploadPolicy
                             (const $ allowWithMaximumSize 300000)
                             hndl'
           <|> error "expect fail here"

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testTooManyHeaders :: Test
testTooManyHeaders = testCase "fileUploads/tooManyHeaders" $
                     (harness tmpdir hndl bigHeadersBody `catch` h)
  where
    h (e :: BadPartException) = show e `deepseq` return ()

    tmpdir = "tempdir_tooManyHeaders"

    hndl = handleFileUploads tmpdir defaultUploadPolicy
                             (const $ allowWithMaximumSize 4)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testAbortedBody :: Test
testAbortedBody = testCase "fileUploads/abortedBody" $
                  expectExceptionH $
                  harness' goAndAbort tmpdir hndl abortedTestBody
  where
    tmpdir = "tempdir_abort"

    hndl = handleFileUploads tmpdir defaultUploadPolicy
                             (const $ allowWithMaximumSize 400000)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()



------------------------------------------------------------------------------
testSlowEnumerator :: Test
testSlowEnumerator = testCase "fileUploads/tooSlow" $
                     ((harness' goSlowEnumerator tmpdir hndl mixedTestBody
                        >> error "shouldn't get here")
                               `catches` [Handler h0])
  where
    h0 (e :: EscapeSnap) = do
        let (TerminateConnection se) = e
            (me :: Maybe RateTooSlowException) = fromException se
        maybe (throw e) h me

    h (e :: RateTooSlowException) = coverShowInstance e

    tmpdir = "tempdir_tooslow"

    policy = setMinimumUploadRate 200000 $
             setMinimumUploadSeconds 2 $
             defaultUploadPolicy

    hndl = handleFileUploads tmpdir policy
                             (const $ allowWithMaximumSize 400000)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testSlowEnumerator2 :: Test
testSlowEnumerator2 = testCase "fileUploads/tooSlow2" $
                      (harness' goSlowEnumerator tmpdir hndl mixedTestBody
                                    `catches` [Handler h0])
  where
    h0 (e :: EscapeSnap) = do
        let (TerminateConnection se) = e
            (me :: Maybe RateTooSlowException) = fromException se
        maybe (throw e) h me

    h (e :: RateTooSlowException) = e `seq` return ()

    tmpdir = "tempdir_tooslow2"

    policy = setUploadTimeout 2 defaultUploadPolicy

    hndl = handleFileUploads tmpdir policy
                             (const $ allowWithMaximumSize 400000)
                             hndl'

    hndl' xs _ = show xs `deepseq` return ()


------------------------------------------------------------------------------
testTrivials :: Test
testTrivials = testCase "fileUploads/trivials" $ do
    assertEqual "" False $ doProcessFormInputs policy
    assertEqual "" 1000  $ getMinimumUploadRate policy
    assertEqual "" 1000  $ getMinimumUploadRate defaultUploadPolicy
    assertEqual "" 5     $ getMinimumUploadSeconds policy
    assertEqual "" 9     $ getUploadTimeout policy

    let pvi = PolicyViolationException ""
    coverTypeableInstance pvi
    evaluate $ ((fromJust $
                 fromException (toException pvi)) :: PolicyViolationException)
    evaluate $ ((fromJust $
                 fromException (toException pvi)) :: FileUploadException)
    let !_ = policyViolationExceptionReason pvi

    let bpi = BadPartException ""
    coverTypeableInstance bpi
    let !_ = badPartExceptionReason bpi

    coverShowInstance $ WrappedFileUploadException $ BadPartException ""
    coverShowInstance $ PartInfo "" Nothing "" DispositionFile (H.empty)
    coverShowInstance $ toPartDisposition ""
    coverEqInstance $ DispositionOther ""

    let !gfui = WrappedFileUploadException $ BadPartException ""
    evaluate $ fileUploadExceptionReason gfui

    void $ evaluate
         $ getMaximumNumberOfFormInputs
         $ setMaximumNumberOfFormInputs 2 policy

  where
    policy = setProcessFormInputs False $
             setMinimumUploadRate 1000 $
             setMinimumUploadSeconds 5 $
             setUploadTimeout 9 $
             defaultUploadPolicy


------------------------------------------------------------------------------
testDisconnectionCleanup :: Test
testDisconnectionCleanup = testCase "fileUploads/disconnectionCleanup" $ do
    runTest `finally` removeDirectoryRecursive tmpdir
  where
    runTest = do
        eatException $ removeDirectoryRecursive tmpdir
        createDirectoryIfMissing True tmpdir
        rq <- mkDamagedRequest mixedTestBody
        eatException $ liftM snd (runIt hndl rq)
        performGC
        dirs <- liftM (filter (\x -> x /= "." && x /= "..")) $
                getDirectoryContents tmpdir
        assertEqual "files should be cleaned up" [] dirs


    tmpdir = "tempdirC"
    hndl = handleFileUploads tmpdir
                             defaultUploadPolicy
                             (const $ allowWithMaximumSize 300000)
                             hndl'

    hndl' _ _ = return ()


------------------------------------------------------------------------------
harness :: FilePath -> Snap a -> ByteString -> IO ()
harness = harness' go


------------------------------------------------------------------------------
harness' :: (Snap a -> ByteString -> IO Response)
         -> FilePath
         -> Snap a
         -> ByteString
         -> IO ()
harness' g tmpdir hndl body = (do
    createDirectoryIfMissing True tmpdir
    !_ <- g hndl body
    return ()) `finally` removeDirectoryRecursive tmpdir


------------------------------------------------------------------------------
mkRequest :: ByteString -> IO Request
mkRequest body = Test.buildRequest $ Test.postRaw "/" ct body
  where
    ct = S.append "multipart/form-data; boundary=" boundaryValue


------------------------------------------------------------------------------
mkDamagedRequest :: ByteString -> IO Request
mkDamagedRequest body = do
    req <- Test.buildRequest $ Test.postRaw "/" ct ""

    e <- newIORef False >>= Streams.makeInputStream . enum

    return $! req { rqBody = e }

  where
    ct = S.append "multipart/form-data; boundary=" boundaryValue
    enum ref = do
        x <- readIORef ref
        if x
           then throw TestException
           else do writeIORef ref True
                   return $! Just $! S.take (S.length body - 1) body


------------------------------------------------------------------------------
go :: Snap a -> ByteString -> IO Response
go m s = do
    rq <- mkRequest s
    liftM snd (runIt m rq)


------------------------------------------------------------------------------
goBadContentType :: Snap a -> ByteString -> IO Response
goBadContentType m s = do
    rq <- mkRequest s
    let rq' = setHeader "Content-Type" "multipart/form-data" rq
    liftM snd (runIt m rq')


------------------------------------------------------------------------------
goWrongContentType :: Snap a -> ByteString -> IO Response
goWrongContentType m s = do
    rq <- mkRequest s
    let rq' = setHeader "Content-Type" "text/plain" rq
    liftM snd (runIt m rq')


------------------------------------------------------------------------------
goSlowEnumerator :: Snap a -> ByteString -> IO Response
goSlowEnumerator m s = do
    rq <- mkRequest s
    e  <- Streams.fromGenerator slowInput
    let rq' = rq { rqBody = e }
    mx <- timeout (20*seconds) (liftM snd (runIt m rq'))
    maybe (error "timeout") return mx

  where
    body = S.unpack s

    slowInput = f body
      where
        f []     = return ()
        f (x:xs) = do
            liftIO waitabit
            Streams.yield $ S.singleton x
            f xs


------------------------------------------------------------------------------
goAndAbort :: Snap a -> ByteString -> IO Response
goAndAbort m s = do
    rq <- mkRequest s
    e  <- Streams.fromGenerator generator
    let rq' = rq { rqBody = e }
    mx <- timeout (20*seconds) (liftM snd (runIt m rq'))
    maybe (error "timeout") return mx

  where
    generator = do
        Streams.yield s
        liftIO $ throwIO
               $ ErrorCall "For in that sleep of death what dreams may come."


------------------------------------------------------------------------------
runIt :: Snap a -> Request -> IO (Request, Response)
runIt m rq = runSnap m d bump rq
  where
    bump !f = let !_ = f 1 in return $! ()

    d :: forall a . Show a => a -> IO ()
    d = \x -> show x `deepseq` return ()


------------------------------------------------------------------------------
-- TEST DATA

formContents1 :: ByteString
formContents1 = "form contents 1"

formContents2 :: ByteString
formContents2 = "form contents 2 zzzzzzzzzzzzzzzzzzzz"

file1Contents :: ByteString
file1Contents = "foo"

file2Contents :: ByteString
file2Contents = "... contents of file2.gif ..."

boundaryValue :: ByteString
boundaryValue = "fkjldsakjfdlsafldksjf"

subBoundaryValue :: ByteString
subBoundaryValue = "zjkzjjfjskzjzjkz"

crlf :: ByteString
crlf = "\r\n"


------------------------------------------------------------------------------
mixedTestBody :: ByteString
mixedTestBody =
    S.concat
         [ "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"field1\"\r\n"
         , crlf
         , formContents1
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"field2\"\r\n"
         , crlf
         , formContents2
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"files\"\r\n"
         , "Content-type: multipart/mixed; boundary="
         , subBoundaryValue
         , crlf
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: attachment; filename=\"file1.txt\"\r\n"
         , "Content-Type: text/plain\r\n"
         , crlf
         , file1Contents
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: attachment; filename=\"file2.gif\"\r\n"
         , "Content-type: image/gif\r\n"
         , "Content-Transfer-Encoding: binary\r\n"
         , crlf
         , file2Contents
         , crlf
         , "--"
         , subBoundaryValue
         , "--\r\n"
         , "--"
         , boundaryValue
         , "--\r\n"
         ]

------------------------------------------------------------------------------
rfc2231FileNameUtf8 :: ByteString
rfc2231FileNameUtf8 = "\208\191\209\128\208\184\208\178\208\181\209\130 \
                      \\228\184\150\231\149\140.txt"

rfc2231FileName :: Text
rfc2231FileName = "привет 世界.txt"

rfc2231TestBody :: ByteString
rfc2231TestBody =
    S.concat
         [ "--"
         , boundaryValue
         , crlf
         , "Content-disposition: form-data; name=upload; filename*=UTF-8''"
         , "%d0%bf%d1%80%d0%b8%d0%b2%d0%b5%d1%82+%e4%b8%96%e7%95%8c.txt\r\n"
         , "Content-Type: text/plain\r\n"
         , crlf
         , file1Contents
         , crlf
         , "--"
         , boundaryValue
         , "--\r\n"
         ]

------------------------------------------------------------------------------
mixedTestBodyWithBadTypes :: ByteString
mixedTestBodyWithBadTypes =
    S.concat
         [ "--"
         , boundaryValue
         , crlf
         , "content-type: ;\x01;\x01;\x01;\r\n"
         , "content-disposition: form-data; name=\"field1\"\r\n\r\n"
         , formContents1
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data;\x01;;;\x01 name=\"field2\"\r\n"
         , crlf
         , formContents2
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: \x01\x01\x01\x01\r\n"
         , "Content-type: multipart/mixed; boundary="
         , subBoundaryValue
         , crlf
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: attachment; filename=\"file1.txt\"\r\n"
         , "Content-Type: ;\x01;\x01;\x01;\r\n"
         , crlf
         , file1Contents
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: attachment; filename=\"file2.gif\"\r\n"
         , "Content-type: ;\x01;\x01;\x01\r\n"
         , "Content-Transfer-Encoding: binary\r\n"
         , crlf
         , file2Contents
         , crlf
         , "--"
         , subBoundaryValue
         , "--\r\n"
         , "--"
         , boundaryValue
         , crlf
         , "Content-type: multipart/mixed; \x01\x01;;\x01;\r\n"
         , "Content-disposition: form-data; name=boo\r\n"
         , crlf
         , "boo"
         , crlf
         , "--"
         , boundaryValue
         , "--\r\n"
         ]


------------------------------------------------------------------------------
badMixedBody :: ByteString
badMixedBody =
    S.concat
         [ crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"field1\"\r\n"
         , crlf
         , formContents1
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"field2\"\r\n"
         , crlf
         , formContents2
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"files\"\r\n"
         , "Content-type: multipart/mixed"
         , crlf
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: attachment; filename=\"file1.txt\"\r\n"
         , "Content-Type: text/plain\r\n"
         , crlf
         , file1Contents
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: attachment; filename=\"file2.gif\"\r\n"
         , "Content-type: image/gif\r\n"
         , "Content-Transfer-Encoding: binary\r\n"
         , crlf
         , file2Contents
         , crlf
         , "--"
         , subBoundaryValue
         , "--\r\n"
         , "--"
         , boundaryValue
         , "--\r\n"
         ]


------------------------------------------------------------------------------
bigHeadersBody :: ByteString
bigHeadersBody =
    S.concat (
         [ "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"field1\"\r\n" ]
         ++
         map (\i -> S.pack ("field_" ++ show i ++ ": bar\r\n")) [1..40000::Int]
         ++
         [ crlf
         , formContents1
         , crlf
         , "--"
         , boundaryValue
         , "--\r\n"
         ])


------------------------------------------------------------------------------
noFileNameTestBody :: ByteString
noFileNameTestBody =
    S.concat
         [ "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"field1\"\r\n"
         , crlf
         , formContents1
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"field2\"\r\n"
         , crlf
         , formContents2
         , crlf
         , "--"
         , boundaryValue
         , crlf
         , "content-disposition: form-data; name=\"files\"\r\n"
         , "Content-type: multipart/mixed; boundary="
         , subBoundaryValue
         , crlf
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: file\r\n"
         , "Content-Type: text/plain\r\n"
         , crlf
         , file1Contents
         , crlf
         , "--"
         , subBoundaryValue
         , crlf
         , "Content-disposition: file\r\n"
         , "Content-type: image/gif\r\n"
         , "Content-Transfer-Encoding: binary\r\n"
         , crlf
         , file2Contents
         , crlf
         , "--"
         , subBoundaryValue
         , "--\r\n"
         , "--"
         , boundaryValue
         , "--\r\n"
         ]


------------------------------------------------------------------------------
abortedTestBody :: ByteString
abortedTestBody =
 S.concat [ "--"
          , boundaryValue
          , crlf
          , "content-disposition: form-data; name=\"field1\"\r\n"
          , crlf
          , formContents1
          , crlf
          , "--"
          , boundaryValue
          , crlf
          , "content-disposition: form-data; name=\"field2\"\r\n"
          , "fdjkljflsdkjfsd"
          ]

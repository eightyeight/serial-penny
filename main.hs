import qualified Data.ByteString.Char8 as B
import Data.Word (Word8)
import System.Hardware.Serialport
    (SerialPort, CommSpeed(..), Parity(..), StopBits(..), SerialPortSettings(..),
     openSerial, send, recv, closeSerial, defaultSerialSettings)

import Data.List (foldl')
import Data.Maybe (isJust, fromJust)

import System.Info (os)
import System.Environment (getArgs)
import Text.Regex.Posix ((=~))
import Data.IORef (newIORef, writeIORef, readIORef)

import Control.Monad (void, forever, when)
import Control.Exception (handle, IOException(..))
import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.Chan
    (Chan, newChan, dupChan, readChan, writeChan)

import qualified Graphics.UI.Threepenny as UI
import Graphics.UI.Threepenny.Core hiding (text)

main = do
    args <- fmap parseArgs getArgs
    putStrLn "Using settings:"

    let guiConfig = defaultConfig {
            tpPort = 10000,
            tpStatic = Just "static",
            tpLog  = const $ return ()
         }

    bus <- newChan

    serialFileRef <- newIORef Nothing
    settingsRef   <- newIORef args

    serialTask <- forkIO $ serialMonitor bus serialFileRef

    putStrLn "Press ENTER to exit."
    ui <- forkIO $ startGUI guiConfig $ clientSetup bus
    void getLine

    killThread ui
    killThread serialTask

data Args = Args {
    filePath :: FilePath,
    stopSize :: StopBits,
    dataSize :: Word8,
    paren    :: Parity,
    baud     :: CommSpeed
 }

defaultArgs = Args file One 8 NoParity CS9600
    where file = case os of
        "mingw32" -> "COM4"
        _         -> "/dev/ttyS0"

type Bus = Chan Message

data Message
    = Connect Args
    | ConnectFailed Args Reason
    | Disconnect
    | Disconnected
    | Received B.ByteString
    | Send B.ByteString

type Reason = String

serialMonitor mainBus handleRef = do
    bus <- dupChan mainBus
    readerRef <- newIORef Nothing
    writerRef <- newIORef Nothing

    forever $ do
        e <- readChan bus
        let ioException :: Args -> IOException -> IO ()
            ioException args = const $ writeChan bus
                $ ConnectFailed args
                $ "Could not open file " ++ filePath args
        case e of
            Connect args -> handle (ioException args) $ do
                serial <- openSerial (filePath args) defaultSerialSettings {
                    commSpeed = baud args,
                    bitsPerWord = dataSize args,
                    stopb = stopSize args,
                    parity = paren args
                 }

                writeIORef handleRef (Just serial)

                reader <- forkIO $ forever $ do
                    ln <- recvLn serial
                    writeChan bus $ Received ln
                writeIORef readerRef (Just reader)

                writer <- forkIO $ forever $ do
                    ev <- readChan bus
                    case ev of
                        Send ln -> send serial ln >> print ln
                        _ -> return ()
                writeIORef writerRef (Just writer)

            Disconnect -> do
                serial <- readIORef handleRef
                case serial of
                    Nothing -> return ()
                    Just h  -> do
                        closeSerial h
                        vff killThread $ readIORef readerRef
                        vff killThread $ readIORef writerRef
                        writeChan bus $ Disconnected
                        where vff x y = void (fmap (fmap x) y)

            _ -> return ()

clientSetup :: Bus -> Window -> UI ()
clientSetup mainBus window = void $ do
    liftIO $ putStrLn "Accepting new connection"
    return window # set title "Serial"
    addStyleSheets window ["bootstrap.min.css", "console.css"]

    bus <- liftIO $ dupChan mainBus

    console    <- UI.new #. "console"
    connect    <- mkButton "success" "Connect"
    disconnect <- mkButton "danger" "Disconnect"
    input      <- UI.input
    navbar     <- mkNavbar "Serial console" [] [mkNavbarRightForm [element connect, element disconnect]]
    getBody window #+ [element navbar, mkContainer [element console, element input]]

    let update c u = void $ atomic window $ runUI window
            $ element console #+ [UI.div #. "line" #. c #+ [string u]]

    reader <- liftIO $ forkIO $ forever $ do
        e <- readChan bus
        case e of
            Received m        -> update "received" (B.unpack m)
            ConnectFailed a r -> update "msg" r
            Disconnected      -> update "msg" "Disconnected from serial"
            _                 -> return ()

    on UI.disconnect window $ const $ liftIO $ killThread reader

    on UI.click connect $ const $ do
        liftIO $ writeChan bus $ Connect defaultArgs
    on UI.click disconnect $ const $ do
        liftIO $ writeChan bus $ Disconnect

    on UI.sendValue input $ \content -> do
        element input # set value ""
        when (not (null content)) $ liftIO $ do
            writeChan bus (Send $ B.pack content)

recvLn :: SerialPort -> IO B.ByteString
recvLn s = do
    first <- recv s 1
    rest <- if first == B.pack "\n"
        then return $ B.pack ""
        else recvLn s
    return $ first `B.append` rest

mkNavbar title left right = UI.div #.
    "navbar navbar-inverse navbar-fixed-top" #+
    [mkContainer $
        [ UI.div #. "navbar-header" #+ [UI.span # set UI.text title] #. "navbar-brand" ]
        ++ left ++ right
    ]

mkNavbarRightForm contents = UI.div #. "navbar-form navbar-right" #+ contents

mkContainer contents = UI.div #. "container" #+ contents

mkButton cls text = UI.button #. ("btn btn-" ++ cls) # set UI.text text

addStyleSheets w = mapM $ UI.addStyleSheet w

parseArgs :: [String] -> Args
parseArgs = foldl' go defaultArgs
    where go acc arg
            | isCommSpeed = acc { baud = bd }
            | isBits      = acc { stopSize = sb, dataSize = db, paren = pb }
            | otherwise   = acc { filePath = arg }
            where isCommSpeed = isJust $ maybeReadCS arg
                  isBits = arg =~ "[0-9](E|O|N)[12]" :: Bool
                  bd = fromJust $ maybeReadCS arg
                  db = read [arg !! 0] :: Word8
                  pb = case (arg !! 1) of
                    'N' -> NoParity
                    'E' -> Even
                    'O' -> Odd
                  sb = case (arg !! 2) of
                    '1' -> One
                    '2' -> Two
          maybeReadCS s = case s of
            "CS110" -> Just CS110
            "CS300" -> Just CS300
            "CS600" -> Just CS600
            "CS1200" -> Just CS1200
            "CS2400" -> Just CS2400
            "CS4800" -> Just CS4800
            "CS9600" -> Just CS9600
            "CS19200" -> Just CS19200
            "CS38400" -> Just CS38400
            "CS57600" -> Just CS57600
            "CS115200" -> Just CS115200
            "110" -> Just CS110
            "300" -> Just CS300
            "600" -> Just CS600
            "1200" -> Just CS1200
            "2400" -> Just CS2400
            "4800" -> Just CS4800
            "9600" -> Just CS9600
            "19200" -> Just CS19200
            "38400" -> Just CS38400
            "57600" -> Just CS57600
            "115200" -> Just CS115200
            _ -> Nothing

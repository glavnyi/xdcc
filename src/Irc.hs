{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}

module Irc ( IrcIO
           , Connection
           , Network
           , Nickname
           , Channel
           , Pack
           , EventFunc
           , connectTo
           , sendAndWaitForAck
           , send
           , disconnectFrom
           , onMessage
           , onCtcpMessage
           , from
           , and
           , msgHasPrefix
           , logMsg
           ) where

import           Control.Concurrent.Broadcast (Broadcast, broadcast)
import qualified Control.Concurrent.Broadcast as Broadcast (listenTimeout, new)
import           Control.Error
import           Control.Monad                (replicateM, when)
import           Control.Monad.Trans.Class    (lift)
import           Data.ByteString.Char8        hiding (length, map, zip)
import           Data.CaseInsensitive         (CI)
import qualified Data.CaseInsensitive         as CI
import           Data.Monoid                  ((<>))
import           Network.IRC.CTCP             (CTCPByteString, asCTCP)
import           Prelude                      hiding (and)
import           System.Console.Concurrent    (outputConcurrent)
import           System.IO.Error              (ioeGetErrorString)

import           Network.SimpleIRC

type Network = String
type Nickname = String
type Channel = CI String
type Pack = Int
type Connection = MIrc

type IrcIO = ExceptT String IO

config :: Network -> Nickname -> [(Channel, Broadcast ())] -> IrcConfig
config network nick chansWithBroadcasts = (mkDefaultConfig network nick)
    { cChannels = map (CI.original . fst) chansWithBroadcasts
    , cEvents   = map asOnJoinEvent chansWithBroadcasts }
  where asOnJoinEvent (chan, b) = Join (onJoin chan b)

connectTo :: Network -> Nickname -> [Channel] -> Bool -> IO () -> IO ()
          -> IrcIO Connection
connectTo network nick chans withDebug onConnected onJoined =
  do bcs <- lift $ replicateM (length chans) Broadcast.new
     con <- connect' (config' bcs) withDebug
     lift onConnected
     joined <- lift $ waitForAll bcs
     case sequence joined of
       Just _ -> do lift onJoined
                    return con
       Nothing -> throwE "Timeout when waiting on joining all channels."
  where config' bcs = config network nick (chans `zip` bcs)

connect' :: IrcConfig -> Bool -> IrcIO Connection
connect' conf withDebug =
    do con <- lift $ hoistEither <$> connect conf True withDebug
       catchE con (throwE . ioeGetErrorString)

waitForAll :: [Broadcast ()] -> IO [Maybe ()]
waitForAll = mapM (`Broadcast.listenTimeout` 30000000)

sendAndWaitForAck :: Connection
                  -> Nickname
                  -> ByteString
                  -> (Nickname -> Broadcast b -> EventFunc)
                  -> String
                  -> IrcIO b
sendAndWaitForAck con rNick cmd broadCastIfMsg errMsg =
    do bc <- lift Broadcast.new
       v <- lift $ do changeEvents con
                                   [ Privmsg (broadCastIfMsg rNick bc)
                                   , Notice logMsg ]
                      send con rNick cmd
                      Broadcast.listenTimeout bc 30000000
       failWith errMsg v

send :: Connection -> Nickname -> ByteString -> IO ()
send con rNick msg =
    do sendCmd con command
       outputConcurrent (show command ++ "\n")
  where command = MPrivmsg (pack rNick) msg

disconnectFrom :: Connection -> IO ()
disconnectFrom = flip disconnect "bye"

onJoin :: Channel -> Broadcast () -> EventFunc
onJoin channel notifyJoined con ircMessage =
  do curNick <- getNickname con
     onMessage (for curNick `and` msgEqCi channel) (\_ ->
            broadcast notifyJoined ()) ircMessage

logMsg :: EventFunc
logMsg _ IrcMessage { mOrigin = Just origin, mCode, mMsg } =
    outputConcurrentBs (mCode <> " " <> origin <>": " <> mMsg <> "\n")
logMsg _ IrcMessage { mCode, mMsg } =
    outputConcurrentBs (mCode <> ": " <> mMsg <> "\n")

outputConcurrentBs :: ByteString -> IO ()
outputConcurrentBs = outputConcurrent . unpack

onMessage :: (a -> Bool)
          -> (a -> IO ())
          -> a
          -> IO ()
onMessage p f x = when (p x) $ f x

onCtcpMessage :: (IrcMessage -> Bool)
              -> (CTCPByteString -> IO ())
              -> IrcMessage
              -> IO ()
onCtcpMessage p f = onMessage p (sequence_ . fmap f . asCTCP . mMsg)

for :: ByteString -> IrcMessage -> Bool
for nick IrcMessage { mNick = Just recipient } = nick == recipient
for _ _ = False

from :: Nickname -> IrcMessage -> Bool
from rNick IrcMessage { mOrigin = Just origin } = pack rNick == origin
from _ _ = False

msgEqCi :: CI String -> IrcMessage -> Bool
msgEqCi msg IrcMessage { mMsg } = msg == CI.mk (unpack mMsg)

msgHasPrefix :: ByteString -> IrcMessage -> Bool
msgHasPrefix prefix IrcMessage { mMsg } = prefix `isPrefixOf` mMsg

and :: (a -> Bool) -> (a -> Bool) -> a -> Bool
and f g x = f x && g x

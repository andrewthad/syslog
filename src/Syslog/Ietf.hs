{-# language BangPatterns #-}
{-# language DuplicateRecordFields #-}
{-# language LambdaCase #-}
{-# language NamedFieldPuns #-}
{-# language TypeApplications #-}
{-# language UnboxedTuples #-}

-- | Parse RFC 5424 messages. For example (from the spec itself):
--
-- > <165>1 2003-10-11T22:14:15.003Z mymachine.example.com
-- >   evntslog - ID47 [exampleSDID@32473 iut="3" eventSource="Application"
-- >   eventID="1011"] BOMAn application event log entry...
module Syslog.Ietf
  ( -- * Types
    Message(..)
  , Element(..)
  , Parameter(..)
    -- * Full Decode
  , decode
  , parser
  ) where

import Prelude hiding (id)

import Control.Monad (when)
import Data.Bytes.Types (Bytes(Bytes))
import Data.Bytes.Parser (Parser)
import Data.Word (Word8,Word32,Word64)
import Data.Int (Int64)
import Data.Primitive (SmallArray)

import qualified Chronos
import qualified Data.Primitive.Contiguous as C
import qualified Data.Maybe.Unpacked.Numeric.Word32 as Word32
import qualified Data.Bytes.Parser as Parser
import qualified Data.Bytes.Parser.Latin as Latin
import qualified Data.Bytes.Parser.Unsafe as Unsafe
import qualified Data.Bytes.Types

data Message = Message
  { priority :: !Word32
  , version :: !Word32
  , timestamp :: !Chronos.OffsetDatetime
  , hostname :: {-# UNPACK #-} !Bytes
  , application :: {-# UNPACK #-} !Bytes
  , processId :: {-# UNPACK #-} !Word32.Maybe
  , messageType :: {-# UNPACK #-} !Bytes
    -- ^ A missing message type, represented as a hyphen in IETF-flavor
    -- syslog, is represented by the empty byte sequence.
  , structuredData :: {-# UNPACK #-} !(SmallArray Element)
  , message :: {-# UNPACK #-} !Bytes
  } deriving (Show)

data Element = Element
  { id :: {-# UNPACK #-} !Bytes
  , parameters :: {-# UNPACK #-} !(SmallArray Parameter)
  } deriving (Show)

data Parameter = Parameter
  { name :: {-# UNPACK #-} !Bytes
  , value :: {-# UNPACK #-} !Bytes
  } deriving (Show)

-- | Run the RFC 5424 parser. See 'parser'.
decode :: Bytes -> Maybe Message
decode = Parser.parseBytesMaybe parser

-- | Parse a RFC 5424 message.
parser :: Parser () s Message
parser = do
  priority <- takePriority ()
  version <- Latin.decWord32 ()
  Latin.char () ' '
  timestamp <- takeTimestamp
  Latin.char () ' '
  hostname <- takeKeywordAndSpace ()
  application <- takeKeywordAndSpace ()
  processId <- Latin.trySatisfy (=='-') >>= \case
    True -> pure Word32.nothing
    False -> do
      w <- Latin.decWord32 ()
      pure (Word32.just w)
  Latin.char () ' '
  messageType <- Latin.trySatisfy (=='-') >>= \case
    True -> do
      Latin.char () ' ' 
      array <- Unsafe.expose 
      pure Bytes{array,offset=0,length=0}
    False -> takeKeywordAndSpace ()
  structuredData <- Latin.trySatisfy (=='-') >>= \case
    True -> pure mempty
    False -> takeStructuredData
  Latin.char () ' '
  message <- Parser.remaining
  pure Message
    {priority,version,timestamp,hostname,application
    ,processId,messageType,structuredData,message
    }

takeStructuredData :: Parser () s (SmallArray Element)
takeStructuredData = go 0 [] where
  go :: Int -> [Element] -> Parser () s (SmallArray Element)
  go !n !acc = Latin.trySatisfy (=='[') >>= \case
    True -> do
      id <- takeKeyword
      parameters <- takeParameters
      let !e = Element{id,parameters}
      go (n + 1) (e : acc)
    False -> pure $! C.unsafeFromListReverseN n acc

takeParameters :: Parser () s (SmallArray Parameter)
takeParameters = go 0 [] where
  go :: Int -> [Parameter] -> Parser () s (SmallArray Parameter)
  go !n !acc = Latin.trySatisfy (==']') >>= \case
    True -> pure $! C.unsafeFromListReverseN n acc
    False -> do
      Latin.char () ' '
      name <- takeKeywordAndEquals
      value <- takeParameterValue
      let !p = Parameter{name,value}
      go (n + 1) (p : acc)

-- TODO: Handle escape sequences correctly.
takeParameterValue :: Parser () s Bytes
takeParameterValue = do
  Latin.char () '"'
  Latin.takeTrailedBy () '"'

-- | Consume the angle-bracketed priority. RFC 5424 does not allow
-- a space to follow the priority, so this does not consume a
-- trailing space.
takePriority :: e -> Parser e s Word32
takePriority e = do
  Latin.char e '<'
  priority <- Latin.decWord32 e
  Latin.char e '>'
  pure priority

-- | Consume the keyword and the space that follows it. Returns
-- the hostname.
takeKeywordAndSpace :: e -> Parser e s Bytes
takeKeywordAndSpace e =
  -- TODO: This should actually use a takeWhile1.
  Latin.takeTrailedBy e ' '

-- | Consume the keyword. Returns the keyword.
takeKeyword :: Parser e s Bytes
takeKeyword =
  -- TODO: Should use takeWhile1
  Parser.takeWhile (\c -> c /= 0x20)

-- | Consume the keyword and the equals sign that follows it. Returns
-- the keyword.
takeKeywordAndEquals :: Parser () s Bytes
takeKeywordAndEquals =
  -- TODO: This should actually use a takeWhile1.
  Latin.takeTrailedBy () '='

-- | Consume the timestamp.
takeTimestamp :: Parser () s Chronos.OffsetDatetime
takeTimestamp = do
  year <- Latin.decWord ()
  Latin.char () '-'
  month' <- Latin.decWord ()
  let !month = month' - 1
  when (month >= 12) (Parser.fail ())
  Latin.char () '-'
  day <- Latin.decWord ()
  Latin.char () 'T'
  hour <- Latin.decWord ()
  Latin.char () ':'
  minute <- Latin.decWord ()
  Latin.char () ':'
  sec <- Latin.decWord ()
  let date = Chronos.Date
        (Chronos.Year (fromIntegral year))
        (Chronos.Month (fromIntegral month))
        (Chronos.DayOfMonth (fromIntegral day))
  !nanos <- Latin.trySatisfy (=='.') >>= \case
    True -> do
      (n,w) <- Parser.measure (Latin.decWord64 ())
      when (n > 9) (Parser.fail ())
      let go !acc !b = case b of
            0 -> acc
            _ -> go (acc * 10) (b - 1)
          !ns = go w (9 - n)
      pure ns
    False -> pure 0
  off <- Latin.any () >>= \case
    'Z' -> pure 0
    '+' -> parserOffset
    '-' -> do
      !off <- parserOffset
      pure (negate off)
    _ -> Parser.fail ()
  pure $! Chronos.OffsetDatetime
    ( Chronos.Datetime date $ Chronos.TimeOfDay
      (fromIntegral hour)
      (fromIntegral minute)
      (fromIntegral @Word64 @Int64 (fromIntegral sec * 1000000000 + nanos))
    ) (Chronos.Offset off)

-- Should consume exactly five characters: HH:MM. However, the implementation
-- is more generous.
parserOffset :: Parser () s Int
parserOffset = do
  h <- Latin.decWord8 ()
  Latin.char () ':'
  m <- Latin.decWord8 ()
  let !r = ((fromIntegral @Word8 @Int h) * 60) + fromIntegral @Word8 @Int m
  pure r

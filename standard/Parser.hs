{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -Wno-unused-do-bind #-}

{-| This module translates @./dhall.abnf@ into a parser implemented using an
    LL parser combinator package

    This parser optimizes for exactly corresponding to the ABNF grammar, at the
    expense of efficiency
-}
module Parser where

import Control.Applicative (Alternative(..), optional)
import Control.Monad (MonadPlus(..), guard, replicateM)
import Crypto.Hash (Digest, SHA256)
import Data.ByteArray.Encoding (Base(..))
import Data.ByteString (ByteString)
import Data.Functor (void)
import Data.List.NonEmpty (NonEmpty(..))
import Data.String (IsString(..))
import Data.Text (Text)
import Data.Void (Void)
import Numeric.Natural (Natural)
import Prelude hiding (exponent, takeWhile)
import Text.Megaparsec.Char (char)

import Syntax
    ( Builtin(..)
    , Constant(..)
    , Expression(..)
    , File(..)
    , FilePrefix(..)
    , ImportMode(..)
    , ImportType(..)
    , Operator(..)
    , Scheme(..)
    , TextLiteral(..)
    , URL(..)
    )
import Text.Megaparsec
    ( MonadParsec
    , Parsec
    , satisfy
    , takeWhileP
    , takeWhile1P
    , try
    )

import qualified Control.Monad.Combinators.NonEmpty as Combinators.NonEmpty
import qualified Crypto.Hash                        as Hash
import qualified Data.ByteArray.Encoding            as ByteArray.Encoding
import qualified Data.Char                          as Char
import qualified Data.List.NonEmpty                 as NonEmpty
import qualified Data.Text                          as Text
import qualified Data.Text.Encoding                 as Text.Encoding

newtype Parser a = Parser { unParser :: Parsec Void Text a }
    deriving
    ( Alternative
    , Applicative
    , Functor
    , Monad
    , MonadFail
    , MonadParsec Void Text
    , MonadPlus
    , Monoid
    , Semigroup
    )

instance a ~ Text => IsString (Parser a) where
    fromString x = Parser (fromString x)

between :: Char -> Char -> Char -> Bool
between lo hi c = lo <= c && c <= hi

takeWhile :: (Char -> Bool) -> Parser Text
takeWhile = takeWhileP Nothing

takeWhile1 :: (Char -> Bool) -> Parser Text
takeWhile1 = takeWhile1P Nothing

digitToNumber :: Char -> Int
digitToNumber c
    | '0' <= c && c <= '9' = 0x0 + Char.ord c - Char.ord '0'
    | 'A' <= c && c <= 'F' = 0xA + Char.ord c - Char.ord 'A'
    | 'a' <= c && c <= 'f' = 0xa + Char.ord c - Char.ord 'a'
    | otherwise = error "Invalid hexadecimal digit"

caseInsensitive :: Char -> Char -> Bool
caseInsensitive expected actual = Char.toUpper actual == expected

base :: Num n => [Char] -> n -> n
digits `base` b = foldl snoc 0 (map (fromIntegral . digitToNumber) digits)
  where
    snoc result number = result * b + number

atMost :: Int -> Parser a -> Parser [a]
atMost 0 _ = do
    return []
atMost n parser = (do
    x <- parser

    xs <- atMost (n - 1) parser

    return (x : xs) ) <|> return []

atLeast :: Int -> Parser a -> Parser [a]
atLeast lowerBound parser = do
    prefix <- replicateM lowerBound parser

    suffix <- many parser

    return (prefix <> suffix)

range :: Int -> Int -> Parser a -> Parser [a]
range lowerBound upperBound parser = do
    prefix <- replicateM lowerBound parser

    suffix <- atMost (upperBound - lowerBound) parser

    return (prefix <> suffix)

endOfLine :: Parser Text
endOfLine = "\n" <|> "\r\n"

validNonAscii :: Char -> Bool
validNonAscii c =
       between     '\x80'   '\xD7FF' c
    || between   '\xE000'   '\xFFFD' c
    || between  '\x10000'  '\x1FFFD' c
    || between  '\x20000'  '\x2FFFD' c
    || between  '\x30000'  '\x3FFFD' c
    || between  '\x40000'  '\x4FFFD' c
    || between  '\x50000'  '\x5FFFD' c
    || between  '\x60000'  '\x6FFFD' c
    || between  '\x70000'  '\x7FFFD' c
    || between  '\x80000'  '\x8FFFD' c
    || between  '\x90000'  '\x9FFFD' c
    || between  '\xA0000'  '\xAFFFD' c
    || between  '\xB0000'  '\xBFFFD' c
    || between  '\xC0000'  '\xCFFFD' c
    || between  '\xD0000'  '\xDFFFD' c
    || between  '\xE0000'  '\xEFFFD' c
    || between  '\xF0000'  '\xFFFFD' c
    || between '\x100000' '\x10FFFD' c

tab :: Char
tab = '\t'

blockComment :: Parser ()
blockComment = do "{-"; blockCommentContinue

blockCommentChar :: Parser ()
blockCommentChar =
        void (satisfy (between '\x20' '\x7F'))
    <|> void (satisfy validNonAscii)
    <|> void (char tab)
    <|> void endOfLine

blockCommentContinue :: Parser ()
blockCommentContinue =
        void "-}"
    <|> (do blockComment; blockCommentContinue)
    <|> (do blockCommentChar; blockCommentContinue)

notEndOfLine :: Parser ()
notEndOfLine = void (satisfy predicate)
  where
    predicate c =
            between '\x20' '\x7F' c
        ||  validNonAscii c
        ||  tab == c

lineComment :: Parser ()
lineComment = do "--"; _ <- many notEndOfLine; _ <- endOfLine; return ()

whitespaceChunk :: Parser ()
whitespaceChunk =
        void " "
    <|> void (char tab)
    <|> void endOfLine
    <|> lineComment
    <|> blockComment

whsp :: Parser ()
whsp = void (many whitespaceChunk)

whsp1 :: Parser ()
whsp1 = void (some whitespaceChunk)

alpha :: Char -> Bool
alpha c = between '\x41' '\x5A' c || between '\x61' '\x7A' c

digit :: Char -> Bool
digit = between '\x30' '\x39'

alphaNum :: Char -> Bool
alphaNum c = alpha c || digit c

hexUpTo :: Char -> Char -> Bool
hexUpTo upperBound c = digit c || between 'A' upperBound (Char.toUpper c)

hexDig :: Char -> Bool
hexDig = hexUpTo 'F'

simpleLabelFirstChar :: Char -> Bool
simpleLabelFirstChar c = alpha c || c == '_'

simpleLabelNextChar :: Char -> Bool
simpleLabelNextChar c = alphaNum c || c `elem` [ '-', '/', '_' ]

simpleLabel :: Parser Text
simpleLabel = try do
    first <- satisfy simpleLabelFirstChar

    rest  <- takeWhile simpleLabelNextChar

    let l = Text.cons first rest

    guard (l `notElem` reservedKeywords)

    return l

quotedLabelChar :: Char -> Bool
quotedLabelChar c = between '\x20' '\x5F' c || between '\x61' '\x7E' c

quotedLabel :: Parser Text
quotedLabel = takeWhile quotedLabelChar

label :: Parser Text
label = (do "`"; l <- quotedLabel; "`"; return l)
    <|> simpleLabel

nonreservedLabels :: Parser Text
nonreservedLabels =
        (do "`"; l <- quotedLabel; "`"; guard (l `notElem` builtins); return l)
    <|> simpleLabel

anyLabel :: Parser Text
anyLabel = label

anyLabelOrSome :: Parser Text
anyLabelOrSome = anyLabel <|> "Some"

doubleQuoteChunk :: Parser TextLiteral
doubleQuoteChunk =
        interpolation
    <|> (do _ <- char '\x5C';

            c <- doubleQuoteEscaped;

            return (Chunks [] (Text.singleton c))
        )
    <|> (do c <- satisfy doubleQuoteChar

            return (Chunks [] (Text.singleton c))
        )

doubleQuoteEscaped :: Parser Char
doubleQuoteEscaped =
        char '\x22'
    <|> char '\x24'
    <|> char '\x5C'
    <|> char '\x2F'
    <|> char '\x62'
    <|> char '\x66'
    <|> char '\x6E'
    <|> char '\x72'
    <|> char '\x74'
    <|> (do char '\x75'; unicodeEscape)

unicodeEscape :: Parser Char
unicodeEscape = do
    number <- unbracedEscape <|> (do "{"; c <- bracedEscape; "}"; return c)

    return (Char.chr number)

unicodeSuffix :: Parser Int
unicodeSuffix = beginsWithoutF <|> beginsWithF
  where
    beginsWithoutF = do
        digit0 <- satisfy (hexUpTo 'E')

        digits1 <- replicateM 3 (satisfy hexDig)

        return ((digit0 : digits1) `base` 16)

    beginsWithF = do
        digit0 <- satisfy (caseInsensitive 'F')

        digits1 <- replicateM 2 (satisfy hexDig)

        digit2 <- satisfy (hexUpTo 'D')

        return ((digit0 : digits1 <> [ digit2 ]) `base` 16)

unbracedEscape :: Parser Int
unbracedEscape = beginsUpToC <|> beginsWithD <|> beginsWithE <|> beginsWithF
  where
    beginsUpToC = do
        digit0 <- satisfy (hexUpTo 'C')

        digits1 <- replicateM 3 (satisfy hexDig)

        return ((digit0 : digits1) `base` 16)

    beginsWithD = do
        digit0 <- satisfy (caseInsensitive 'D')

        digit1 <- satisfy (between '0' '7')

        digits2 <- replicateM 2 (satisfy hexDig)

        return ((digit0 : digit1 : digits2) `base` 16)

    beginsWithE = do
        digit0 <- satisfy (caseInsensitive 'E')

        digits1 <- replicateM 3 (satisfy hexDig)

        return ((digit0 : digits1) `base` 16)

    beginsWithF = do
        digit0 <- satisfy (caseInsensitive 'F')

        digits1 <- replicateM 2 (satisfy hexDig)

        digit2 <- satisfy (hexUpTo 'D')

        return ((digit0 : digits1 <> [ digit2 ]) `base` 16)

bracedCodepoint :: Parser Int
bracedCodepoint = planes1Through16 <|> unbracedEscape <|> threeDigits
  where
    planes1Through16 = do
        prefix <- fmap digitToNumber (satisfy hexDig) <|> (do "10"; return 16)

        suffix <- unicodeSuffix

        return (prefix * 0x10000 + suffix)

    threeDigits = do
        digits <- range 1 3 (satisfy hexDig)

        return (digits `base` 16)

bracedEscape :: Parser Int
bracedEscape = do
    _ <- takeWhile (== '0')

    bracedCodepoint

doubleQuoteChar :: Char -> Bool
doubleQuoteChar c = do
        between '\x20' '\x21' c
    ||  between '\x23' '\x5B' c
    ||  between '\x5D' '\x7F' c
    ||  validNonAscii c

doubleQuoteLiteral :: Parser TextLiteral
doubleQuoteLiteral = do
    _ <- char '"'

    chunks <- many doubleQuoteChunk

    _ <- char '"'

    return (mconcat chunks)

singleQuoteContinue :: Parser TextLiteral
singleQuoteContinue =
        (interpolation <> singleQuoteContinue)
    <|> (escapedQuotePair <> singleQuoteContinue)
    <|> (escapedInterpolation <> singleQuoteContinue)
    <|> (do _ <- "''"; return mempty)
    <|> (singleQuoteChar <> singleQuoteContinue)

escapedQuotePair :: Parser TextLiteral
escapedQuotePair = do
    _ <- "'''"

    return (Chunks [] "''")

escapedInterpolation :: Parser TextLiteral
escapedInterpolation = do
    _ <- "''${"

    return (Chunks [] "${")

singleQuoteChar :: Parser TextLiteral
singleQuoteChar =
        (do c <- satisfy predicate

            return (Chunks [] (Text.singleton c))
        )
    <|> (do t <- endOfLine

            return (Chunks [] t)
        )
  where
    predicate c =
            between '\x20' '\x7F' c
        ||  validNonAscii c
        ||  tab == c

singleQuoteLiteral :: Parser TextLiteral
singleQuoteLiteral = do
    _ <- "''"

    _ <- endOfLine

    singleQuoteContinue

interpolation :: Parser TextLiteral
interpolation = do
    _ <- "${"

    e <- completeExpression

    _ <- "}"

    return (Chunks [("", e)] "")

textLiteral :: Parser TextLiteral
textLiteral = doubleQuoteLiteral <|> singleQuoteLiteral

reservedKeywords :: [Text]
reservedKeywords =
    [ "if"
    , "then"
    , "else"
    , "let"
    , "in"
    , "using"
    , "missing"
    , "assert"
    , "as"
    , "Infinity"
    , "NaN"
    , "merge"
    , "Some"
    , "toMap"
    , "forall"
    , "with"
    ]

keyword :: Parser ()
keyword =
        if_
    <|> then_
    <|> else_
    <|> let_
    <|> in_
    <|> using
    <|> void missing
    <|> assert
    <|> as
    <|> _Infinity
    <|> _NaN
    <|> merge
    <|> _Some
    <|> toMap
    <|> forallKeyword
    <|> with

if_ :: Parser ()
if_ = void "if"

then_ :: Parser ()
then_ = void "then"

else_ :: Parser ()
else_ = void "else"

let_ :: Parser ()
let_ = void "let"

in_ :: Parser ()
in_ = void "in"

as :: Parser ()
as = void "as"

using :: Parser ()
using = void "using"

merge :: Parser ()
merge = void "merge"

missing :: Parser ImportType
missing = do _ <- "missing"; return Missing

_Infinity :: Parser ()
_Infinity = void "Infinity"

_NaN :: Parser ()
_NaN = void "NaN"

_Some :: Parser ()
_Some = void "Some"

toMap :: Parser ()
toMap = void "toMap"

assert :: Parser ()
assert = void "assert"

forallKeyword :: Parser ()
forallKeyword = void "forall"

forallSymbol :: Parser ()
forallSymbol = void "∀"

forall :: Parser ()
forall = forallSymbol <|> forallKeyword

with :: Parser ()
with = void "with"

builtins :: [Text]
builtins =
    [ "Natural/fold"
    , "Natural/build"
    , "Natural/isZero"
    , "Natural/even"
    , "Natural/odd"
    , "Natural/toInteger"
    , "Natural/show"
    , "Integer/toDouble"
    , "Integer/show"
    , "Integer/negate"
    , "Integer/clamp"
    , "Natural/subtract"
    , "Double/show"
    , "List/build"
    , "List/fold"
    , "List/length"
    , "List/head"
    , "List/last"
    , "List/indexed"
    , "List/reverse"
    , "Text/show"
    , "Text/replace"
    , "Bool"
    , "True"
    , "False"
    , "Optional"
    , "None"
    , "Natural"
    , "Integer"
    , "Double"
    , "Text"
    , "List"
    , "Type"
    , "Kind"
    , "Sort"
    ]

builtin :: Parser Builtin
builtin =
        _NaturalFold
    <|> _NaturalBuild
    <|> _NaturalIsZero
    <|> _NaturalEven
    <|> _NaturalOdd
    <|> _NaturalToInteger
    <|> _NaturalShow
    <|> _IntegerToDouble
    <|> _IntegerShow
    <|> _IntegerNegate
    <|> _IntegerClamp
    <|> _NaturalSubtract
    <|> _DoubleShow
    <|> _ListBuild
    <|> _ListFold
    <|> _ListLength
    <|> _ListHead
    <|> _ListLast
    <|> _ListIndexed
    <|> _ListReverse
    <|> _TextShow
    <|> _TextReplace
    <|> _Bool
    <|> _True
    <|> _False
    <|> _Optional
    <|> _None
    <|> _Natural
    <|> _Integer
    <|> _Double
    <|> _Text
    <|> _List

_NaturalFold :: Parser Builtin
_NaturalFold = do _ <- "Natural/fold"; return NaturalFold

_NaturalBuild :: Parser Builtin
_NaturalBuild = do _ <- "Natural/build"; return NaturalBuild

_NaturalIsZero :: Parser Builtin
_NaturalIsZero = do _ <- "Natural/isZero"; return NaturalIsZero

_NaturalEven :: Parser Builtin
_NaturalEven = do _ <- "Natural/even"; return NaturalEven

_NaturalOdd :: Parser Builtin
_NaturalOdd = do _ <- "Natural/odd"; return NaturalOdd

_NaturalToInteger :: Parser Builtin
_NaturalToInteger = do _ <- "Natural/toInteger"; return NaturalToInteger

_NaturalShow :: Parser Builtin
_NaturalShow = do _ <- "Natural/show"; return NaturalShow

_IntegerToDouble :: Parser Builtin
_IntegerToDouble = do _ <- "Integer/toDouble"; return IntegerToDouble

_IntegerShow :: Parser Builtin
_IntegerShow = do _ <- "Integer/show"; return IntegerShow

_IntegerNegate :: Parser Builtin
_IntegerNegate = do _ <- "Integer/negate"; return IntegerNegate

_IntegerClamp :: Parser Builtin
_IntegerClamp = do _ <- "Integer/clamp"; return IntegerClamp

_NaturalSubtract :: Parser Builtin
_NaturalSubtract = do _ <- "Natural/subtract"; return NaturalSubtract

_DoubleShow :: Parser Builtin
_DoubleShow = do _ <- "Double/show"; return DoubleShow

_ListBuild :: Parser Builtin
_ListBuild = do _ <- "List/build"; return ListBuild

_ListFold :: Parser Builtin
_ListFold = do _ <- "List/fold"; return ListFold

_ListLength :: Parser Builtin
_ListLength = do _ <- "List/length"; return ListLength

_ListHead :: Parser Builtin
_ListHead = do _ <- "List/head"; return ListHead

_ListLast :: Parser Builtin
_ListLast = do _ <- "List/last"; return ListLast

_ListIndexed :: Parser Builtin
_ListIndexed = do _ <- "List/indexed"; return ListIndexed

_ListReverse :: Parser Builtin
_ListReverse = do _ <- "List/reverse"; return ListReverse

_TextShow :: Parser Builtin
_TextShow = do _ <- "Text/show"; return TextShow

_TextReplace :: Parser Builtin
_TextReplace = do _ <- "Text/replace"; return TextReplace

_Bool :: Parser Builtin
_Bool = do _ <- "Bool"; return Bool

_True :: Parser Builtin
_True = do _ <- "True"; return Syntax.True

_False :: Parser Builtin
_False = do _ <- "False"; return Syntax.False

_Optional :: Parser Builtin
_Optional = do _ <- "Optional"; return Optional

_None :: Parser Builtin
_None = do _ <- "None"; return None

_Natural :: Parser Builtin
_Natural = do _ <- "Natural"; return Natural

_Integer :: Parser Builtin
_Integer = do _ <- "Integer"; return Integer

_Double :: Parser Builtin
_Double = do _ <- "Double"; return Double

_Text :: Parser Builtin
_Text = do _ <- "Text"; return Text

_List :: Parser Builtin
_List = do _ <- "List"; return List

_Location :: Parser ()
_Location = void "Location"

constant :: Parser Constant
constant =
        _Type
    <|> _Kind
    <|> _Sort

_Type :: Parser Constant
_Type = do _ <- "Type"; return Type

_Kind :: Parser Constant
_Kind = do _ <- "Kind"; return Kind

_Sort :: Parser Constant
_Sort = do _ <- "Sort"; return Sort

combine :: Parser Operator
combine = do _ <- "∧" <|> "/\\"; return CombineRecordTerms

combineTypes :: Parser Operator
combineTypes = do _ <- "⩓" <|> "//\\\\"; return CombineRecordTypes

equivalent :: Parser Operator
equivalent = do _ <- "≡" <|> "==="; return Equivalent

prefer :: Parser Operator
prefer = do _ <- "⫽" <|> "//"; return Prefer

lambda :: Parser ()
lambda = do _ <- "λ" <|> "\\"; return ()

arrow :: Parser ()
arrow = do _ <- "→" <|> "->"; return ()

complete :: Parser ()
complete = do _ <- "::"; return ()

sign :: Num n => Parser (n -> n)
sign = (do _ <- "+"; return id) <|> (do _ <- "-"; return negate)

exponent :: Parser Int
exponent = do
    _ <- "e"

    s <- sign

    digits <- atLeast 1 (satisfy digit)

    return (s (digits `base` 10))

numericDoubleLiteral :: Parser Double
numericDoubleLiteral = do
    s <- sign

    digits0 <- atLeast 1 (satisfy digit)

    let withRadix = do
            _ <- "."

            digits1 <- atLeast 1 (satisfy digit)

            e <- exponent <|> pure 0

            return (s (fromInteger ((digits0 <> digits1) `base` 10) * 10^(e - length digits1)))

    let withoutRadix = do
            e <- exponent

            return (s (fromInteger (digits0 `base` 10) * 10^e))

    withRadix <|> withoutRadix

minusInfinityLiteral :: Parser Double
minusInfinityLiteral = do
    _ <- "-"

    _ <- _Infinity

    return (-1/0)

plusInfinityLiteral :: Parser Double
plusInfinityLiteral = do
    _ <- _Infinity

    return (1/0)

doubleLiteral :: Parser Double
doubleLiteral =
        numericDoubleLiteral
    <|> minusInfinityLiteral
    <|> plusInfinityLiteral
    <|> (do _ <- _NaN; return (0/0))

naturalLiteral :: Parser Natural
naturalLiteral = hexadecimal <|> decimal <|> zero
  where
    hexadecimal = do
        _ <- "0x"

        digits <- atLeast 1 (satisfy hexDig)

        return (digits `base` 16)

    decimal = do
        digit0 <- satisfy (between '1' '9')

        digits1 <- many (satisfy digit)

        return ((digit0 : digits1) `base` 10)

    zero = do
        _ <- "0"

        return 0

integerLiteral :: Parser Double
integerLiteral = do
    s <- sign

    n <- naturalLiteral

    return (s (fromIntegral n))

identifier :: Parser Expression
identifier = variable <|> fmap Builtin builtin

variable :: Parser Expression
variable = do
    x <- nonreservedLabels

    n <- index <|> pure 0

    return (Variable x n)
  where
    index = do
        whsp

        _ <- "@"

        whsp

        naturalLiteral

pathCharacter :: Char -> Bool
pathCharacter c =
        c == '\x21'
    ||  between '\x24' '\x27' c
    ||  between '\x2A' '\x2B' c
    ||  between '\x2D' '\x2E' c
    ||  between '\x30' '\x3B' c
    ||  c == '\x3D'
    ||  between '\x40' '\x5A' c
    ||  between '\x5E' '\x7A' c
    ||  c == '\x7C'
    ||  c == '\x7E'

quotedPathCharacter :: Char -> Bool
quotedPathCharacter c =
        between '\x20' '\x21' c
    ||  between '\x23' '\x2E' c
    ||  between '\x30' '\x7F' c
    ||  validNonAscii c

unquotedPathComponent :: Parser Text
unquotedPathComponent = takeWhile1 pathCharacter

quotedPathComponent :: Parser Text
quotedPathComponent = takeWhile1 quotedPathCharacter

pathComponent :: Parser Text
pathComponent = do
    _ <- "/"

    let quoted = do
            _ <- "\""

            component <- quotedPathComponent

            _ <- "\""

            return component

    unquotedPathComponent <|> quoted

path_ :: Parser File
path_ = do
    components <- Combinators.NonEmpty.some pathComponent

    return (File (NonEmpty.init components) (NonEmpty.last components))

local :: Parser ImportType
local = parentPath <|> herePath <|> homePath <|> absolutePath

parentPath :: Parser ImportType
parentPath = do
    _ <- ".."

    p <- path_

    return (Path Parent p)

herePath :: Parser ImportType
herePath = do
    _ <- "."

    p <- path_

    return (Path Here p)

homePath :: Parser ImportType
homePath = do
    _ <- "~"

    p <- path_

    return (Path Home p)

absolutePath :: Parser ImportType
absolutePath = do
    p <- path_

    return (Path Absolute p)

scheme_ :: Parser Scheme
scheme_ = do
    _ <- "http"

    let secure = do
            _ <- "s"

            return HTTPS

    secure <|> return HTTP

httpRaw :: Parser URL
httpRaw = do
    s <- scheme_

    _ <- "://"

    a <- authority_

    p <- pathAbempty

    q <- optional (do _ <- "?"; query_)

    return (URL s a p q)

pathAbempty :: Parser File
pathAbempty = do
    segments <- many (do _ <- "/"; segment)

    case segments of
        [] -> do
            return (File [] "")
        s : ss -> do
            let n = s :| ss

            return (File (NonEmpty.init n) (NonEmpty.last n))

authority_ :: Parser Text
authority_ = do
    ((userinfo <> "@") <|> "") <> host <> ((":" <> port) <|> ":")

userinfo :: Parser Text
userinfo = do
    let character = do
            c <- satisfy (\c -> unreserved c || subDelims c || c == ':')

            return (Text.singleton c)

    texts <- many (character <|> pctEncoded)

    return (Text.concat texts)

host :: Parser Text
host = ipLiteral <|> ipv4Address <|> domain

port :: Parser Text
port = takeWhile digit

ipLiteral :: Parser Text
ipLiteral = "[" <> (ipv6Address <|> ipvFuture) <> "]"

ipvFuture :: Parser Text
ipvFuture = do
        "v"
    <>  takeWhile1 hexDig
    <>  "."
    <>  takeWhile1 (\c -> unreserved c || subDelims c || c == ':')

ipv6Address :: Parser Text
ipv6Address =
        try option0
    <|> try option1
    <|> try option2
    <|> try option3
    <|> try option4
    <|> try option5
    <|> try option6
    <|> option7
  where
    option0 = do
        a <- replicateM 6 (h16 <> ":")

        b <- ls32

        return (Text.concat (a <> [ b ]))

    option1 = do
        a <- (h16 <|> "")

        b <- "::"

        c <- replicateM 4 (h16 <> ":")

        d <- ls32

        return (Text.concat ([ a, b ] <> c <> [ d ]))

    option2 = do
        let prefix = do
                a <- h16

                b <- atLeast 1 (":" <> h16)

                return (Text.concat (a : b))

        a <- prefix <|> ""

        b <- "::"

        c <- replicateM 3 (h16 <> ":")

        d <- ls32

        return (Text.concat ([ a, b ] <> c <> [ d ]))

    option3 = do
        let prefix = do
                a <- h16

                b <- atLeast 2 (":" <> h16)

                return (Text.concat (a : b))

        a <- prefix <|> ""

        b <- "::"

        c <- replicateM 2 (h16 <> ":")

        d <- ls32

        return (Text.concat ([ a, b ] <> c <> [ d ]))

    option4 = do
        let prefix = do
                a <- h16

                b <- atLeast 3 (":" <> h16)

                return (Text.concat (a : b))

        (prefix <|> "") <> "::" <> h16 <> ":" <> ls32

    option5 = do
        let prefix = do
                a <- h16

                b <- atLeast 4 (":" <> h16)

                return (Text.concat (a : b))

        (prefix <|> "") <> "::" <> ls32

    option6 = do
        let prefix = do
                a <- h16

                b <- atLeast 5 (":" <> h16)

                return (Text.concat (a : b))

        (prefix <|> "") <> "::" <> h16

    option7 = do
        let prefix = do
                a <- h16

                b <- atLeast 6 (":" <> h16)

                return (Text.concat (a : b))

        (prefix <|> "") <> "::"

h16 :: Parser Text
h16 = do
    a <- satisfy hexDig 

    b <- replicateM 3 (satisfy hexDig)

    return (Text.pack (a : b))

ls32 :: Parser Text
ls32 = (h16 <> ":" <> h16) <|> ipv4Address

ipv4Address :: Parser Text
ipv4Address = decOctet <> "." <> decOctet <> "." <> decOctet <> "." <> decOctet

decOctet :: Parser Text
decOctet = do
        try beginsWith25
    <|> try beginsWith2
    <|> try beginsWith1
    <|> try twoDigits
    <|> oneDigit
  where
    beginsWith25 = do
        a <- "25"

        b <- satisfy (between '\x30' '\x35')

        return (a <> Text.singleton b)

    beginsWith2 = do
        a <- "2"

        b <- satisfy (between '\x30' '\x34')

        c <- satisfy digit

        return (a <> Text.singleton b <> Text.singleton c)

    beginsWith1 = do
        a <- "1"

        b <- replicateM 2 (satisfy digit)

        return (a <> Text.pack b)

    twoDigits = do
        a <- satisfy (between '\x31' '\x39')

        b <- satisfy digit

        return (Text.pack [a, b])

    oneDigit = do
        b <- satisfy digit

        return (Text.singleton b)

domain :: Parser Text
domain = do
    a <- domainlabel

    b <- many ("." <> domainlabel)

    c <- "."

    return (a <> Text.concat b <> c)

domainlabel :: Parser Text
domainlabel = do
    a <- takeWhile1 alphaNum

    b <- many (takeWhile1 ('-' ==) <> takeWhile1 alphaNum)

    return (a <> Text.concat b)

segment :: Parser Text
segment = do
    a <- many pchar

    return (Text.concat a)

pchar :: Parser Text
pchar = character <|> pctEncoded
  where
    character = do
        c <- satisfy (\c -> unreserved c || subDelims c || c `elem` [ ':', '@' ])

        return (Text.singleton c)

query_ :: Parser Text
query_ = do
    let character = do
            c <- satisfy (\c -> c `elem` [ '/', '?' ])

            return (Text.singleton c)

    a <- many (pchar <|> character)

    return (Text.concat a)

pctEncoded :: Parser Text
pctEncoded = do
    a <- "%"

    b <- satisfy hexDig

    c <- satisfy hexDig

    return (a <> Text.pack [ b, c ])

unreserved :: Char -> Bool
unreserved c = alphaNum c || c `elem` [ '-', '.', '_', '~' ]

subDelims :: Char -> Bool
subDelims c = c `elem` [ '!', '$', '&', '\'', '*', '+', ';', '=' ]

http :: Parser ImportType
http = do
    url <- httpRaw

    headers <- optional do
        whsp

        using

        whsp

        importExpression

    return (Remote url headers)

env :: Parser ImportType
env = do
    _ <- "env:"

    let posix = do
            "\""

            v <- posixEnvironmentVariable

            "\""

            return v

    v <- bashEnvironmentVariable <|> posix

    return (Env v)

bashEnvironmentVariable :: Parser Text
bashEnvironmentVariable = do
    a <- satisfy (\c -> alpha c || c == '_')

    b <- takeWhile1 (\c -> alphaNum c || c == '_')

    return (Text.cons a b)

posixEnvironmentVariable :: Parser Text
posixEnvironmentVariable = do
    a <- some posixEnvironmentVariableCharacter

    return (Text.pack a)

posixEnvironmentVariableCharacter :: Parser Char
posixEnvironmentVariableCharacter = do
    let escaped = do
            "\\"

            let remainder =
                         (do _ <- "\""; return '"' )
                    <|>  (do _ <- "\\"; return '\\')
                    <|>  (do _ <- "a" ; return '\a')
                    <|>  (do _ <- "b" ; return '\b')
                    <|>  (do _ <- "f" ; return '\f')
                    <|>  (do _ <- "n" ; return '\n')
                    <|>  (do _ <- "r" ; return '\r')
                    <|>  (do _ <- "t" ; return '\t')
                    <|>  (do _ <- "v" ; return '\v')

            remainder

    let unescaped c =
                between '\x20' '\x21' c
            ||  between '\x23' '\x3C' c
            ||  between '\x3E' '\x5B' c
            ||  between '\x5D' '\x7E' c

    escaped <|> satisfy unescaped

importType :: Parser ImportType
importType =
    missing <|> local <|> http <|> env

hash :: Parser (Digest SHA256)
hash = do
    "sha256:"

    hexDigits <- replicateM 64 (satisfy hexDig)

    let base16 = Text.Encoding.encodeUtf8 (Text.pack hexDigits)

    bytes <-  case ByteArray.Encoding.convertFromBase Base16 base16 of
        Left string -> fail string
        Right bytes -> return (bytes :: ByteString)

    case Hash.digestFromByteString bytes of
        Nothing -> fail "Invalid sha256 hash"
        Just h  -> return h

import_ :: Parser Expression
import_ = do
    i <- importType

    h <- optional do
        whsp1

        hash

    let location = do
            whsp

            as

            whsp1

            (do _ <- _Text; return RawText) <|> (do _ <- _Location; return Location)

    l <- location <|> return Code

    return (Import i l h)

completeExpression :: Parser Expression
completeExpression = undefined

importExpression :: Parser Expression
importExpression = undefined

-- |
-- Module      : Mlatu.Term
-- Description : The core language
-- Copyright   : (c) Caden Haustin, 2021
-- License     : MIT
-- Maintainer  : mlatu@brightlysalty.33mail.com
-- Stability   : experimental
-- Portability : GHC
module Mlatu.Term
  ( Case (..),
    CoercionHint (..),
    Else (..),
    MatchHint (..),
    Permit (..),
    Term (..),
    Value (..),
    asCoercion,
    compose,
    decompose,
    identityCoercion,
    origin,
    permissionCoercion,
    quantifierCount,
    stripMetadata,
    stripValue,
    typ,
    defaultElseBody,
  )
where

import Data.List (partition)
import Mlatu.Entry.Parameter (Parameter (..))
import Mlatu.Kind qualified as Kind
import Mlatu.Literal (FloatLiteral, IntegerLiteral)
import Mlatu.Name
  ( Closed,
    ClosureIndex (..),
    ConstructorIndex (..),
    GeneralName (..),
    LocalIndex (..),
    Qualified (..),
    Unqualified (..),
  )
import Mlatu.Operator (Fixity (Postfix))
import Mlatu.Origin (Origin)
import Mlatu.Signature (Signature)
import Mlatu.Signature qualified as Signature
import Mlatu.Type (Type, TypeId)
import Relude hiding (Compose, Type)
import qualified Mlatu.Vocabulary as Vocabulary

-- | This is the core language. It permits pushing values to the stack, invoking
-- definitions, and moving values between the stack and local variables.
--
-- It also permits empty programs and program concatenation. Together these form
-- a monoid over programs. The denotation of the concatenation of two programs
-- is the composition of the denotations of those two programs. In other words,
-- there is a homomorphism from the syntactic monoid onto the semantic monoid.
--
-- A value of type @'Term' a@ is a term annotated with a value of type @a@. A
-- parsed term may have a type like @'Term' ()@, while a type-inferred term may
-- have a type like @'Term' 'Type'@.
data Term a
  = -- | @id@, @as (T)@, @with (+A -B)@: coerces the stack to a particular type.
    Coercion !CoercionHint !a !Origin
  | -- | @e1 e2@: composes two terms.
    Compose !a !(Term a) !(Term a)
  | -- | @Λx. e@: generic terms that can be specialized.
    Generic !Unqualified !TypeId !(Term a) !Origin
  | -- | @(e)@: precedence grouping for infix operators.
    Group !(Term a)
  | -- | @→ x; e@: local variable introductions.
    Lambda !a !Unqualified !a !(Term a) !Origin
  | -- | @match { case C {...}... else {...} }@, @if {...} else {...}@:
    -- pattern-matching.
    Match !MatchHint !a ![Case a] !(Else a) !Origin
  | -- | @new.n@: ADT allocation.
    New !a !ConstructorIndex !Int !Origin
  | -- | @new.closure.n@: closure allocation.
    NewClosure !a !Int !Origin
  | -- | @new.vec.n@: vector allocation.
    NewVector !a !Int !a !Origin
  | -- | @push v@: push of a value.
    Push !a !(Value a) !Origin
  | -- | @f@: an invocation of a word.
    Word !a !Fixity !GeneralName ![Type] !Origin
  deriving (Ord, Eq, Show)

-- | The type of coercion to perform.
data CoercionHint
  = -- | The identity coercion, generated by empty terms.
    IdentityCoercion
  | -- | A coercion to a particular type.
    AnyCoercion !Signature
  deriving (Ord, Eq, Show)

-- | The original source of a @match@ expression
data MatchHint
  = -- | @match@ generated from @if@.
    BooleanMatch
  | -- | @match@ explicitly in the source.
    AnyMatch
  deriving (Ord, Eq, Show)

-- | A case branch in a @match@ expression.
data Case a = 
  Case !GeneralName !(Term a) !Origin
  deriving (Ord, Eq, Show)

-- | An @else@ branch in a @match@ (or @if@) expression.
data Else a
  = DefaultElse !a !Origin
  | Else !(Term a) !Origin
  deriving (Ord, Eq, Show)

defaultElseBody :: a -> Origin -> Term a
defaultElseBody a = Word a Postfix (QualifiedName (Qualified Vocabulary.global "abort")) []

-- | A permission to grant or revoke in a @with@ expression.
data Permit = Permit
  { permitted :: !Bool,
    permitName :: !GeneralName
  }
  deriving (Ord, Eq, Show)

-- | A value, used to represent literals in a parsed program, as well as runtime
-- values in the interpreter.
data Value a
  = -- | A quotation with explicit variable capture; see "Mlatu.Scope".
    Capture ![Closed] !(Term a)
  | -- | A character literal.
    Character !Char
  | -- | A captured variable.
    Closed !ClosureIndex
  | -- | A floating-point literal.
    Float !FloatLiteral
  | -- | An integer literal.
    Integer !IntegerLiteral
  | -- | A local variable.
    Local !LocalIndex
  | -- | A reference to a name.
    Name !Qualified
  | -- | A parsed quotation.
    Quotation !(Term a)
  | -- | A text literal.
    Text !Text
  deriving (Ord, Eq, Show)

-- FIXME: 'compose' should work on 'Term ()'.
compose :: a -> Origin -> [Term a] -> Term a
compose x o = foldr (Compose x) (identityCoercion x o)

asCoercion :: a -> Origin -> [Signature] -> Term a
asCoercion x o ts = Coercion (AnyCoercion signature) x o
  where
    signature = Signature.Quantified [] (Signature.Function ts ts [] o) o

identityCoercion :: a -> Origin -> Term a
identityCoercion = Coercion IdentityCoercion

permissionCoercion :: [Permit] -> a -> Origin -> Term a
permissionCoercion permits x o = Coercion (AnyCoercion signature) x o
  where
    signature =
      Signature.Quantified
        [ Parameter o "R" Kind.Stack Nothing,
          Parameter o "S" Kind.Stack Nothing
        ]
        ( Signature.Function
            [ Signature.StackFunction
                (Signature.Variable "R" o)
                []
                (Signature.Variable "S" o)
                []
                (map permitName grants)
                o
            ]
            [ Signature.StackFunction
                (Signature.Variable "R" o)
                []
                (Signature.Variable "S" o)
                []
                (map permitName revokes)
                o
            ]
            []
            o
        )
        o
    (grants, revokes) = partition permitted permits

decompose :: Term a -> [Term a]
-- TODO: Verify that this is correct.
decompose (Generic _ _ t _) = decompose t
decompose (Compose _ a b) = decompose a ++ decompose b
decompose (Coercion IdentityCoercion _ _) = []
decompose (Group (Group a)) = [Group a]
decompose term = [term]

origin :: Term a -> Origin
origin term = case term of
  Coercion _ _ o -> o
  Compose _ a _ -> origin a
  Generic _ _ _ o -> o
  Group a -> origin a
  Lambda _ _ _ _ o -> o
  New _ _ _ o -> o
  NewClosure _ _ o -> o
  NewVector _ _ _ o -> o
  Match _ _ _ _ o -> o
  Push _ _ o -> o
  Word _ _ _ _ o -> o

quantifierCount :: Term a -> Int
quantifierCount = countFrom 0
  where
    countFrom !c (Generic _ _ body _) = countFrom (c + 1) body
    countFrom c _ = c

-- Deduces the explicit type of a term.

typ :: Term Type -> Type
typ = metadata

metadata :: Term a -> a
metadata term = case term of
  Coercion _ t _ -> t
  Compose t _ _ -> t
  Generic _ _ term' _ -> metadata term'
  Group term' -> metadata term'
  Lambda t _ _ _ _ -> t
  Match _ t _ _ _ -> t
  New t _ _ _ -> t
  NewClosure t _ _ -> t
  NewVector t _ _ _ -> t
  Push t _ _ -> t
  Word t _ _ _ _ -> t

stripMetadata :: Term a -> Term ()
stripMetadata term = case term of
  Coercion a _ b -> Coercion a () b
  Compose _ a b -> Compose () (stripMetadata a) (stripMetadata b)
  Generic a b term' c -> Generic a b (stripMetadata term') c
  Group term' -> stripMetadata term'
  Lambda _ a _ b c -> Lambda () a () (stripMetadata b) c
  Match a _ b c d -> Match a () (map stripCase b) (stripElse c) d
  New _ a b c -> New () a b c
  NewClosure _ a b -> NewClosure () a b
  NewVector _ a _ b -> NewVector () a () b
  Push _ a b -> Push () (stripValue a) b
  Word _ a b c d -> Word () a b c d
  where
    stripCase :: Case a -> Case ()
    stripCase case_ = case case_ of
      Case a b c -> Case a (stripMetadata b) c

    stripElse :: Else a -> Else ()
    stripElse else_ = case else_ of
      Else a b -> Else (stripMetadata a) b
      DefaultElse _ b -> DefaultElse () b

stripValue :: Value a -> Value ()
stripValue v = case v of
  Capture a b -> Capture a (stripMetadata b)
  Character a -> Character a
  Closed a -> Closed a
  Float a -> Float a
  Integer a -> Integer a
  Local a -> Local a
  Name a -> Name a
  Quotation a -> Quotation (stripMetadata a)
  Text a -> Text a

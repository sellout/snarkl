{-# LANGUAGE RebindableSyntax #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use camelCase" #-}

module Snarkl.Language.SyntaxMonad
  ( -- | Computation monad
    Comp,
    CompResult,
    runState,
    return,
    (>>=),
    (>>),
    raise_err,
    Env (..),
    State (..),
    -- | Return a fresh input variable.
    fresh_input,
    -- | Return a fresh variable.
    fresh_var,
    -- | Return a fresh location.
    fresh_loc,
    -- | Basic values
    unit,
    false,
    true,
    -- | Arrays
    arr,
    input_arr,
    get,
    set,
    -- | Pairs
    pair,
    fst_pair,
    snd_pair,
    -- | Basic static analysis
    is_true,
    is_false,
    assert_false,
    assert_true,
    is_bot,
    assert_bot,
    -- | Show the current state.
    debug_state,
    -- | Misc. functions imported by 'Snarkl.Language.Syntax.hs'
    get_addr,
    guard,
    add_objects,
  )
where

import Control.Monad (forM, replicateM)
import Control.Monad.Supply (Supply, runSupply)
import Control.Monad.Supply.Class (MonadSupply (fresh))
import Data.Field.Galois (Prime)
import qualified Data.Map.Strict as Map
import Data.String (IsString (..))
import Data.Typeable (Typeable)
import GHC.TypeLits (KnownNat)
import Snarkl.Errors (ErrMsg (ErrMsg), failWith)
import Snarkl.Language.Expr (Variable (..))
import Snarkl.Language.TExpr
  ( Loc,
    TExp (TEAssert, TEBinop, TEBot, TESeq, TEUnop, TEVal, TEVar),
    TLoc (TLoc),
    TVar (TVar),
    Ty (TArr, TBool, TProd, TUnit),
    Val (VFalse, VLoc, VTrue, VUnit),
    lastSeq,
    locOfTexp,
    teSeq,
    varOfTExp,
  )
import Prelude hiding
  ( fromRational,
    negate,
    not,
    return,
    (&&),
    (*),
    (+),
    (-),
    (/),
    (>>),
    (>>=),
  )
import qualified Prelude as P

{-----------------------------------------------
 State Monad
------------------------------------------------}

type CompResult s a = Either ErrMsg (a, s)

data State s a = State (s -> CompResult s a)

runState :: State s a -> s -> CompResult s a
runState mf s = case mf of
  State f -> f s

raise_err :: ErrMsg -> Comp ty p
raise_err msg = State (\_ -> Left msg)

-- | We have to define our own bind operator, unfortunately,
-- because the "result" that's returned is the sequential composition
-- of the results of 'mf', 'g' (not just whatever 'g' returns)
(>>=) ::
  forall (ty1 :: Ty) (ty2 :: Ty) s a.
  (Typeable ty1) =>
  State s (TExp ty1 a) ->
  (TExp ty1 a -> State s (TExp ty2 a)) ->
  State s (TExp ty2 a)
(>>=) mf g =
  State
    ( \s ->
        case runState mf s of
          Left err -> Left err
          Right (e, s') -> case runState (g e) s' of
            Left err -> Left err
            Right (e', s'') -> Right (e `teSeq` e', s'')
    )

(>>) ::
  forall (ty1 :: Ty) (ty2 :: Ty) s a.
  (Typeable ty1) =>
  State s (TExp ty1 a) ->
  State s (TExp ty2 a) ->
  State s (TExp ty2 a)
(>>) mf g = do _ <- mf; g

return :: TExp ty a -> State s (TExp ty a)
return e = State (\s -> Right (lastSeq e, s))

-- | At elaboration time, we maintain an environment containing
--    (i) next_var:  the next free variable
--    (ii) next_loc: the next fresh location
--    (iii) obj_map: a symbol table mapping (obj_loc,integer index) to
--    the constraint variable associated with that object, at that
--    field index. A given (obj_loc,integer index) pair may also
--    resolve to a constant rational, boolean, or the bottom value,
--    for constant propagation.
--
--  Reading from object 'a' at index 'i' (x := a_i) corresponds to:
--    (a) getting y <- obj_map(a,i)
--    (b) inserting the constraint (x = y), if x,y resolve to logic
--    vars.
data ObjBind
  = ObjLoc Loc
  | ObjVar Variable
  deriving
    ( Show
    )

data AnalBind p
  = AnalBool Bool
  | AnalConst (Prime p)
  | AnalBot
  deriving
    ( Show
    )

type ObjMap =
  Map.Map
    ( Loc, -- object a
      Int -- at index i
    )
    ObjBind -- maps to result r

data Env p = Env
  { next_variable :: Int,
    next_loc :: Int,
    input_vars :: [Variable],
    obj_map :: ObjMap,
    anal_map :: Map.Map Variable (AnalBind p) -- supporting simple constprop analyses
  }
  deriving (Show)

type Comp ty p = State (Env p) (TExp ty (Prime p))

{-----------------------------------------------
 Units, Booleans (used below)
------------------------------------------------}

unit :: TExp 'TUnit (Prime p)
unit = TEVal VUnit

false :: TExp 'TBool (Prime p)
false = TEVal VFalse

true :: TExp 'TBool (Prime p)
true = TEVal VTrue

{-----------------------------------------------
 Arrays
------------------------------------------------}

arr :: Int -> Comp ('TArr ty) p
arr 0 = raise_err $ ErrMsg "array must have size > 0"
arr len =
  State
    ( \s ->
        let loc = next_loc s
            (binds, nextVar) = runSupply (new_binds loc) (next_variable s)
         in Right
              ( TEVal (VLoc (TLoc $ next_loc s)),
                -- allocate:
                -- (1) a new location (next_loc s)
                -- (2) 'len' new variables [(next_variable s)..(next_variable s+len-1)]
                s
                  { next_variable = nextVar,
                    next_loc = loc P.+ 1,
                    obj_map = binds `Map.union` obj_map s
                  }
              )
    )
  where
    new_binds :: Loc -> Supply ObjMap
    new_binds loc =
      Map.fromList
        <$> forM
          [0 .. (len P.- 1)]
          ( \i ->
              fresh P.>>= \v ->
                pure
                  ( (loc, i),
                    ObjVar (Variable v)
                  )
          )

-- Like 'arr', but declare fresh array variables as inputs.
input_arr :: Int -> Comp ('TArr ty) p
input_arr 0 = raise_err $ ErrMsg "array must have size > 0"
input_arr len =
  State
    ( \s ->
        let loc = next_loc s
            ((binds, vars), nextVar) = runSupply (new_binds loc) (next_variable s)
         in Right
              ( TEVal (VLoc (TLoc $ next_loc s)),
                -- allocate:
                -- (1) a new location (next_loc s)
                -- (2) 'len' new variables [(next_variable s)..(next_variable s+len-1)]
                -- (3) mark new vars. as inputs
                s
                  { next_variable = nextVar,
                    next_loc = loc P.+ 1,
                    input_vars = vars ++ input_vars s,
                    obj_map = binds `Map.union` obj_map s
                  }
              )
    )
  where
    new_binds :: Loc -> Supply (ObjMap, [Variable])
    new_binds loc =
      new_vars P.>>= \vs ->
        pure
          ( Map.fromList $ zipWith (\i v -> ((loc, i), ObjVar v)) [0 .. (len P.- 1)] vs,
            vs
          )
    --       (Map.fromList $ zipWith (\(i, v) -> ((next_loc s, i), ObjVar v)) [0 .. (len vs P.- 1)] vs, vs)

    --        ( forM [0 .. (len P.- 1)] \i ->
    --                fresh P.>>= \v ->
    --                  pure
    --                    ( ( (next_loc s, i),
    --                        ObjVar (Variable v)
    --                      ),
    --                      Variable v
    --                    )
    --            )
    new_vars :: Supply [Variable]
    new_vars = replicateM len (Variable <$> fresh)

get_addr :: (Loc, Int) -> Comp ty p
get_addr (l, i) =
  State
    ( \s -> case Map.lookup (l, i) (obj_map s) of
        Just (ObjLoc l') -> Right (TEVal (VLoc (TLoc l')), s)
        Just (ObjVar x) -> Right (TEVar (TVar x), s)
        Nothing ->
          Left $
            ErrMsg
              ( "unbound loc "
                  ++ show (l, i)
                  ++ " in heap "
                  ++ show (obj_map s)
              )
    )

guard ::
  (Typeable ty2) =>
  (KnownNat p) =>
  (TExp ty (Prime p) -> State (Env p) (TExp ty2 (Prime p))) ->
  TExp ty (Prime p) ->
  State (Env p) (TExp ty2 (Prime p))
guard f e =
  do
    b <- is_bot e
    case b of
      TEVal VTrue -> return TEBot
      TEVal VFalse -> f e
      _ -> failWith $ ErrMsg "internal error in guard"

guarded_get_addr ::
  (Typeable ty2) =>
  (KnownNat p) =>
  TExp ty (Prime p) ->
  Int ->
  State (Env p) (TExp ty2 (Prime p))
guarded_get_addr e i =
  guard (\e0 -> get_addr (locOfTexp e0, i)) e

get :: (Typeable ty) => (KnownNat p) => (TExp ('TArr ty) (Prime p), Int) -> Comp ty p
get (TEBot, _) = return TEBot
get (a, i) = guarded_get_addr a i

-- | Smart constructor for TEAssert
te_assert :: (Typeable ty) => (KnownNat p) => TExp ty (Prime p) -> TExp ty (Prime p) -> Comp 'TUnit p
te_assert x@(TEVar _) e =
  do
    e_bot <- is_bot e
    e_true <- is_true e
    e_false <- is_false e
    case (e_bot, e_true, e_false) of
      (TEVal VTrue, _, _) -> assert_bot x >> return (TEAssert x e)
      (_, TEVal VTrue, _) -> assert_true x >> return (TEAssert x e)
      (_, _, TEVal VTrue) -> assert_false x >> return (TEAssert x e)
      _ -> return $ TEAssert x e
te_assert _ e =
  failWith $
    ErrMsg $
      "in te_assert, expected var but got " ++ show e

-- | Update array 'a' at position 'i' to expression 'e'. We special-case
-- variable and location expressions, because they're representable untyped
-- in the object map.
set_addr ::
  (Typeable ty) =>
  (KnownNat p) =>
  (TExp ('TArr ty) (Prime p), Int) ->
  TExp ty (Prime p) ->
  Comp 'TUnit p
-- The following specialization (to variable expressions) is an
-- optimization: we avoid introducing a fresh variable.
set_addr (TEVal (VLoc (TLoc l)), i) (TEVar (TVar x)) =
  add_objects [((l, i), ObjVar x)] >> return unit
-- The following specialization (to location values) is necessary to
-- satisfy [INVARIANT]: All expressions of compound types (sums,
-- products, arrays, ...) have the form (TEVal (VLoc (TLoc l))), for
-- some location l.
set_addr (TEVal (VLoc (TLoc l)), i) (TEVal (VLoc (TLoc l'))) =
  do
    _ <- add_objects [((l, i), ObjLoc l')]
    return unit

-- Default:
set_addr (TEVal (VLoc (TLoc l)), i) e =
  do
    x <- fresh_var
    _ <- add_objects [((l, i), ObjVar (varOfTExp x))]
    te_assert x e

-- Err: expression does not satisfy [INVARIANT].
set_addr (e1, _) _ =
  raise_err $ ErrMsg ("expected " ++ show e1 ++ " a loc")

set :: (Typeable ty, KnownNat p) => (TExp ('TArr ty) (Prime p), Int) -> TExp ty (Prime p) -> Comp 'TUnit p
set (a, i) e = set_addr (a, i) e

{-----------------------------------------------
 Products
------------------------------------------------}

pair ::
  ( Typeable ty1,
    Typeable ty2,
    KnownNat p
  ) =>
  TExp ty1 (Prime p) ->
  TExp ty2 (Prime p) ->
  Comp ('TProd ty1 ty2) p
pair te1 te2 =
  do
    l <- fresh_loc
    _ <- add_binds (locOfTexp l) (lastSeq te1) (lastSeq te2)
    return l
  where
    add_binds l (TEVal (VLoc (TLoc l1))) (TEVal (VLoc (TLoc l2))) =
      add_objects [((l, 0), ObjLoc l1), ((l, 1), ObjLoc l2)]
    add_binds l (TEVal (VLoc (TLoc l1))) e2 =
      do
        x2 <- fresh_var
        _ <- add_objects [((l, 0), ObjLoc l1), ((l, 1), ObjVar $ varOfTExp x2)]
        te_assert x2 e2
    add_binds l e1 (TEVal (VLoc (TLoc l2))) =
      do
        x1 <- fresh_var
        _ <- add_objects [((l, 0), ObjVar $ varOfTExp x1), ((l, 1), ObjLoc l2)]
        te_assert x1 e1
    add_binds l e1 e2 =
      do
        x1 <- fresh_var
        x2 <- fresh_var
        _ <-
          add_objects
            [ ((l, 0), ObjVar $ varOfTExp x1),
              ((l, 1), ObjVar $ varOfTExp x2)
            ]
        -- NOTE: return e ~~> return (lastSeq e). So we rely on the
        -- slightly weird semantics of (>>=) to do the sequencing of
        -- the two assertions for us.
        _ <- te_assert x1 e1
        te_assert x2 e2

fst_pair ::
  (Typeable ty1) =>
  (KnownNat p) =>
  TExp ('TProd ty1 ty2) (Prime p) ->
  Comp ty1 p
fst_pair TEBot = return TEBot
fst_pair e = guarded_get_addr e 0

snd_pair ::
  ( Typeable ty2,
    KnownNat p
  ) =>
  TExp ('TProd ty1 ty2) (Prime p) ->
  Comp ty2 p
snd_pair TEBot = return TEBot
snd_pair e = guarded_get_addr e 1

{-----------------------------------------------
 Auxiliary functions
------------------------------------------------}

debug_state :: (KnownNat p) => State (Env p) (TExp 'TUnit a)
debug_state =
  State (\s -> Left $ ErrMsg $ show s)

fresh_var :: State (Env p) (TExp ty a)
fresh_var =
  State
    ( \s ->
        let (v, nextVar) = runSupply (Variable <$> fresh) (next_variable s)
         in Right
              ( TEVar (TVar v),
                s
                  { next_variable = nextVar
                  }
              )
    )

fresh_input :: State (Env p) (TExp ty a)
fresh_input =
  State
    ( \s ->
        let (v, nextVar) = runSupply (Variable <$> fresh) (next_variable s)
         in Right
              ( TEVar (TVar v),
                s
                  { next_variable = nextVar,
                    input_vars = v : input_vars s
                  }
              )
    )

fresh_loc :: State (Env p) (TExp ty a)
fresh_loc =
  State
    ( \s ->
        Right
          ( TEVal (VLoc (TLoc $ next_loc s)),
            s
              { next_loc = (P.+) (next_loc s) 1
              }
          )
    )

add_objects :: [((Loc, Int), ObjBind)] -> Comp 'TUnit p
add_objects binds =
  State
    ( \s ->
        Right
          ( unit,
            s
              { obj_map = Map.fromList binds `Map.union` obj_map s
              }
          )
    )

add_statics :: [(Variable, AnalBind p)] -> Comp 'TUnit p
add_statics binds =
  State
    ( \s ->
        Right
          ( unit,
            s
              { anal_map = Map.fromList binds `Map.union` anal_map s
              }
          )
    )

-- | Does boolean expression 'e' resolve (statically) to 'b'?
is_bool :: (KnownNat p) => TExp ty (Prime p) -> Bool -> Comp 'TBool p
is_bool (TEVal VFalse) False = return true
is_bool (TEVal VTrue) True = return true
is_bool e@(TEVar _) b =
  State
    ( \s ->
        Right
          ( case Map.lookup (varOfTExp e) (anal_map s) of
              Nothing -> false
              Just (AnalBool b') | b /= b' -> false
              Just (AnalBool b') | b == b' -> true
              Just _ | otherwise -> false,
            s
          )
    )
is_bool _ _ = return false

is_false :: (KnownNat p) => TExp ty (Prime p) -> Comp 'TBool p
is_false = flip is_bool False

is_true :: (KnownNat p) => TExp ty (Prime p) -> Comp 'TBool p
is_true = flip is_bool True

-- | Add binding 'x = b'.
assert_bool :: (KnownNat p) => TExp ty (Prime p) -> Bool -> Comp 'TUnit p
assert_bool (TEVar (TVar x)) b = add_statics [(x, AnalBool b)]
assert_bool e _ = raise_err $ ErrMsg $ "expected " ++ show e ++ " a variable"

assert_false :: (KnownNat p) => TExp ty (Prime p) -> Comp 'TUnit p
assert_false = flip assert_bool False

assert_true :: (KnownNat p) => TExp ty (Prime p) -> Comp 'TUnit p
assert_true = flip assert_bool True

var_is_bot :: (KnownNat p) => TExp ty (Prime p) -> Comp 'TBool p
var_is_bot e@(TEVar (TVar _)) =
  State
    ( \s ->
        Right
          ( case Map.lookup (varOfTExp e) (anal_map s) of
              Nothing -> false
              Just AnalBot -> true
              Just _ -> false,
            s
          )
    )
var_is_bot _ = return false

is_bot :: (KnownNat p) => TExp ty (Prime p) -> Comp 'TBool p
is_bot e =
  case e of
    e0@(TEVar _) -> var_is_bot e0
    TEUnop _ e0 -> is_bot e0
    TEBinop _ e1 e2 -> either_is_bot e1 e2
    TESeq e1 e2 -> either_is_bot e1 e2
    TEBot -> return true
    _ -> return false
  where
    either_is_bot :: (KnownNat p) => TExp ty1 (Prime p) -> TExp ty2 (Prime p) -> Comp 'TBool p
    either_is_bot e10 e20 =
      do
        e1_bot <- is_bot e10
        e2_bot <- is_bot e20
        case (e1_bot, e2_bot) of
          (TEVal VTrue, _) -> return true
          (_, TEVal VTrue) -> return true
          _ -> return false

assert_bot :: (KnownNat p) => TExp ty (Prime p) -> Comp 'TUnit p
assert_bot (TEVar (TVar x)) = add_statics [(x, AnalBot)]
assert_bot e = raise_err $ ErrMsg $ "in assert_bot, expected " ++ show e ++ " a variable"
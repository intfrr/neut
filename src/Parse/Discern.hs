module Parse.Discern
  ( discern,
    discernIdentPlus,
    discernDef,
    discernText,
  )
where

import Control.Monad.State.Lazy
import Data.EnumCase
import Data.Env
import qualified Data.HashMap.Lazy as Map
import Data.Ident
import Data.Meta
import Data.Namespace
import qualified Data.Text as T
import Data.WeakTerm

type NameEnv = Map.HashMap T.Text Ident

discern :: WeakTermPlus -> WithEnv WeakTermPlus
discern e = do
  nenv <- gets topNameEnv
  discern' nenv e

discernDef :: Def -> WithEnv Def
discernDef (m, xt, xts, e) = do
  nenv <- gets topNameEnv
  (xt', xts', e') <- discernFix nenv xt xts e
  return (m, xt', xts', e')

discernText :: Meta -> T.Text -> WithEnv Ident
discernText m x = do
  nenv <- gets topNameEnv
  penv <- gets prefixEnv
  lookupName'' m penv nenv $ asIdent x

-- Alpha-convert all the variables so that different variables have different names.
discern' :: NameEnv -> WeakTermPlus -> WithEnv WeakTermPlus
discern' nenv term =
  case term of
    (m, WeakTermTau) ->
      return (m, WeakTermTau)
    (m, WeakTermUpsilon x@(I (s, _))) -> do
      penv <- gets prefixEnv
      mx <- lookupName m penv nenv x
      case mx of
        Just x' ->
          return (m, WeakTermUpsilon x')
        Nothing -> do
          b1 <- lookupEnumValueNameWithPrefix s
          case b1 of
            Just s' ->
              return (m, WeakTermEnumIntro s')
            Nothing -> do
              b2 <- lookupEnumTypeNameWithPrefix s
              case b2 of
                Just s' ->
                  return (m, WeakTermEnum s')
                Nothing -> do
                  mc <- lookupConstantMaybe m penv s
                  case mc of
                    Just c ->
                      return (m, WeakTermConst c)
                    Nothing ->
                      raiseError m $ "undefined variable: " <> asText x
    (m, WeakTermPi xts t) -> do
      (xts', t') <- discernBinder nenv xts t
      return (m, WeakTermPi xts' t')
    (m, WeakTermPiIntro xts e) -> do
      (xts', e') <- discernBinder nenv xts e
      return (m, WeakTermPiIntro xts' e')
    (m, WeakTermPiElim e es) -> do
      es' <- mapM (discern' nenv) es
      e' <- discern' nenv e
      return (m, WeakTermPiElim e' es')
    (m, WeakTermFix (mx, x, t) xts e) -> do
      (xt', xts', e') <- discernFix nenv (mx, x, t) xts e
      return (m, WeakTermFix xt' xts' e')
    (m, WeakTermConst x) ->
      return (m, WeakTermConst x)
    (m, WeakTermAster h) ->
      return (m, WeakTermAster h)
    (m, WeakTermInt t x) -> do
      t' <- discern' nenv t
      return (m, WeakTermInt t' x)
    (m, WeakTermFloat t x) -> do
      t' <- discern' nenv t
      return (m, WeakTermFloat t' x)
    (m, WeakTermEnum s) ->
      return (m, WeakTermEnum s)
    (m, WeakTermEnumIntro x) ->
      return (m, WeakTermEnumIntro x)
    (m, WeakTermEnumElim (e, t) caseList) -> do
      e' <- discern' nenv e
      t' <- discern' nenv t
      caseList' <-
        forM caseList $ \((mCase, l), body) -> do
          l' <- discernEnumCase mCase l
          body' <- discern' nenv body
          return ((mCase, l'), body')
      return (m, WeakTermEnumElim (e', t') caseList')
    (m, WeakTermArray dom kind) -> do
      dom' <- discern' nenv dom
      return (m, WeakTermArray dom' kind)
    (m, WeakTermArrayIntro kind es) -> do
      es' <- mapM (discern' nenv) es
      return (m, WeakTermArrayIntro kind es')
    (m, WeakTermArrayElim kind xts e1 e2) -> do
      e1' <- discern' nenv e1
      (xts', e2') <- discernBinder nenv xts e2
      return (m, WeakTermArrayElim kind xts' e1' e2')
    (m, WeakTermStruct ts) ->
      return (m, WeakTermStruct ts)
    (m, WeakTermStructIntro ets) -> do
      let (es, ts) = unzip ets
      es' <- mapM (discern' nenv) es
      return (m, WeakTermStructIntro $ zip es' ts)
    (m, WeakTermStructElim xts e1 e2) -> do
      e1' <- discern' nenv e1
      (xts', e2') <- discernStruct nenv xts e2
      return (m, WeakTermStructElim xts' e1' e2')
    (m, WeakTermQuestion e t) -> do
      e' <- discern' nenv e
      t' <- discern' nenv t
      return (m, WeakTermQuestion e' t')
    (_, WeakTermErase mxs e) -> do
      penv <- gets prefixEnv
      forM_ mxs $ \(mx, x) -> lookupName'' mx penv nenv (asIdent x)
      let xs = map snd mxs
      let nenv' = Map.filterWithKey (\k _ -> k `notElem` xs) nenv
      discern' nenv' e

discernIdentPlus :: WeakIdentPlus -> WithEnv WeakIdentPlus
discernIdentPlus (m, x, t) = do
  sanityCheck m x
  nenv <- gets topNameEnv
  t' <- discern' nenv t
  x' <- newNameWith x
  modify (\env -> env {topNameEnv = Map.insert (asText x) x' (topNameEnv env)})
  return (m, x', t')

sanityCheck :: Meta -> Ident -> WithEnv ()
sanityCheck m x = do
  nenv <- gets topNameEnv
  when (Map.member (asText x) nenv)
    $ raiseError m
    $ "the variable " <> asText x <> " is already defined at top level"

discernBinder ::
  NameEnv ->
  [WeakIdentPlus] ->
  WeakTermPlus ->
  WithEnv ([WeakIdentPlus], WeakTermPlus)
discernBinder nenv binder e =
  case binder of
    [] -> do
      e' <- discern' nenv e
      return ([], e')
    (mx, x, t) : xts -> do
      t' <- discern' nenv t
      x' <- newNameWith x
      (xts', e') <- discernBinder (insertName x x' nenv) xts e
      return ((mx, x', t') : xts', e')

discernFix ::
  NameEnv ->
  WeakIdentPlus ->
  [WeakIdentPlus] ->
  WeakTermPlus ->
  WithEnv (WeakIdentPlus, [WeakIdentPlus], WeakTermPlus)
discernFix nenv self binder e = do
  (binder', e') <- discernBinder nenv (self : binder) e
  return (head binder', tail binder', e')

discernEnumCase :: Meta -> EnumCase -> WithEnv EnumCase
discernEnumCase m weakCase =
  case weakCase of
    EnumCaseLabel l -> do
      ml <- lookupEnumValueNameWithPrefix l
      case ml of
        Just l' ->
          return (EnumCaseLabel l')
        Nothing ->
          raiseError m $ "no such enum-value is defined: " <> l
    _ ->
      return weakCase

discernStruct ::
  NameEnv ->
  [(Meta, Ident, a)] ->
  WeakTermPlus ->
  WithEnv ([(Meta, Ident, a)], WeakTermPlus)
discernStruct nenv binder e =
  case binder of
    [] -> do
      e' <- discern' nenv e
      return ([], e')
    ((mx, x, t) : xts) -> do
      x' <- newNameWith x
      (xts', e') <- discernStruct (insertName x x' nenv) xts e
      return ((mx, x', t) : xts', e')

insertName :: Ident -> Ident -> NameEnv -> NameEnv
insertName (I (s, _)) =
  Map.insert s

lookupName :: Meta -> [T.Text] -> NameEnv -> Ident -> WithEnv (Maybe Ident)
lookupName m penv nenv x =
  case Map.lookup (asText x) nenv of
    Just x' ->
      return $ Just x'
    Nothing ->
      lookupName' m penv nenv x

lookupName' :: Meta -> [T.Text] -> NameEnv -> Ident -> WithEnv (Maybe Ident)
lookupName' m penv nenv x =
  case penv of
    [] ->
      return Nothing
    prefix : prefixList -> do
      let query = prefix <> nsSep <> asText x
      case Map.lookup query nenv of
        Nothing ->
          lookupName' m prefixList nenv x
        Just x' ->
          return $ Just x'

lookupName'' :: Meta -> [T.Text] -> NameEnv -> Ident -> WithEnv Ident
lookupName'' m penv nenv x = do
  mx <- lookupName m penv nenv x
  case mx of
    Just x' ->
      return x'
    Nothing ->
      raiseError m $ "(double-prime) undefined variable: " <> asText x

lookupConstantMaybe :: Meta -> [T.Text] -> T.Text -> WithEnv (Maybe T.Text)
lookupConstantMaybe m penv x = do
  b <- isConstant x
  if b
    then return $ Just x
    else lookupConstantMaybe' m penv x

lookupConstantMaybe' :: Meta -> [T.Text] -> T.Text -> WithEnv (Maybe T.Text)
lookupConstantMaybe' m penv x =
  case penv of
    [] ->
      return Nothing
    prefix : prefixList -> do
      let query = prefix <> nsSep <> x
      b <- isConstant query
      if b
        then return $ Just query
        else lookupConstantMaybe' m prefixList x

lookupEnum :: (T.Text -> WithEnv Bool) -> T.Text -> WithEnv (Maybe T.Text)
lookupEnum f name = do
  b <- f name
  if b
    then return $ Just name
    else do
      penv <- gets prefixEnv
      lookupEnum' f penv name

lookupEnum' :: (T.Text -> WithEnv Bool) -> [T.Text] -> T.Text -> WithEnv (Maybe T.Text)
lookupEnum' f penv name =
  case penv of
    [] ->
      return Nothing
    prefix : prefixList -> do
      let name' = prefix <> nsSep <> name
      b <- f name'
      if b
        then return $ Just name'
        else lookupEnum' f prefixList name

lookupEnumValueNameWithPrefix :: T.Text -> WithEnv (Maybe T.Text)
lookupEnumValueNameWithPrefix =
  lookupEnum isDefinedEnumValue

lookupEnumTypeNameWithPrefix :: T.Text -> WithEnv (Maybe T.Text)
lookupEnumTypeNameWithPrefix =
  lookupEnum isDefinedEnumType

isDefinedEnumValue :: T.Text -> WithEnv Bool
isDefinedEnumValue name = do
  renv <- gets revEnumEnv
  return $ name `Map.member` renv

isDefinedEnumType :: T.Text -> WithEnv Bool
isDefinedEnumType name = do
  eenv <- gets enumEnv
  return $ name `Map.member` eenv

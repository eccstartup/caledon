{-# LANGUAGE 
 FlexibleContexts,  
 FlexibleInstances,
 TupleSections
 #-}
module Solver where

import AST
import Choice

import Control.Monad (void, unless)
import Control.Applicative ((<|>), empty)
import Control.Monad.Error.Class
import Control.Monad.State (StateT, runStateT)
import Control.Monad.Writer (WriterT, runWriterT)
import Control.Monad.Writer.Class
import Control.Monad.Trans.Class
import Data.Monoid
import Data.Functor
import Data.Traversable (forM)
import Data.Foldable as F (msum, foldr', foldl', foldl')
import qualified Data.Map as M
import qualified Data.Set as S
import Debug.Trace

type VarGen = StateT Integer Choice

--------------------------------------------------------------------
----------------------- UNIFICATION --------------------------------
--------------------------------------------------------------------
type Unification = VarGen Substitution

getV = id
setV a _ = a
      
unifyAll _ _ [] = return mempty
unifyAll envE env (a:l) = do
  s <- appendErr ("ON: "++show env) $ unify envE env a
  (s ***) <$> unifyAll envE env (subst s l)

unify :: M.Map Name Tp -> M.Map Name Tp -> Constraint Tm -> Unification
unify envE env constraint@(a :=: b) = 
  let badConstraint :: VarGen a
      badConstraint = throwError $ show constraint
      unify'' = unify envE env
      unify' = unify envE
      doUntoBoth :: [Argument] -> [Argument] -> Unification
      doUntoBoth m n = F.foldl' act (return mempty) (zip (getTipe <$> m) (getTipe <$> n))
      act prev (mt,nt) = do
        sub <- prev 
        sub' <- unify' (subst sub env) $ subst sub (toTm mt :=: toTm nt)
        return $ sub *** sub'

  in case a :=: b of
    _ :=: _ | a > b -> unify' env $ b :=: a

    AbsImp n ty t :=: _ -> do
      (v',s) <- solve $ (M.toList envE)++(M.toList env) :|- ty
      unify' env $ subst s (subst (n |-> v') t) :=: (subst s b)
      
    Abs n ty t :=: Abs n' ty' t' -> do  
      s <- unify'' $ toTm ty :=: toTm ty'
      nm <- getNew
      s' <- unify' (subst s $ M.insert nm ty env) $ subst (M.insert n (var nm) s) t :=: subst (M.insert n' (var nm) s) t'
      return $ s *** M.delete nm s'
    Abs n ty t :=: _ -> do  
      nm <- getNew
      s <- unify' (M.insert nm ty env) $ subst (n |-> var nm) t :=: rebuildSpine b [Norm $ Atom $ var nm]
      return $ M.delete nm s
    
    Spine (Var a) [] :=: Spine (Var a') [] | a == a' -> 
      return mempty
    Spine (Var a) [] :=: _ | not (M.member a env) && (not $ S.member a $ freeVariables b) -> 
      return $ a |-> b
    
    Spine (Var a) m :=: Spine (Var a') n | a == a' && M.member a env && length m == length n ->  -- the var has the same rule whether it is quantified or not.
      doUntoBoth m n
      
    Spine (Cons c) _ :=: Spine (Cons c') _ | c /= c' -> -- Const-Const /= 
      badConstraint
    Spine (Cons _) m :=: Spine (Cons _) n | length m == length n ->  -- Const-Const = 
      doUntoBoth m n
      
    Spine (Var x) n :=: Spine (Cons c) m | not $ M.member x env -> do -- Gvar-Const
      us <- forM n $ const $ getNew
      usty <- forM n $ const $ Atom <$> var <$> getNew
      xs <- forM m $ const $ Var <$> getNew
      let l = Spine (Cons c) $ (\xi -> Norm $ Atom $ Spine xi $ Norm <$> Atom <$> var <$> us) <$> xs
          s = x |-> foldr' (\(v,ty) t -> Abs v ty t) l (zip us usty)
      s' <- unify' (subst s env) $ subst s (a :=: b)
      return $ (s *** s')
      
    Spine (Var a) n :=: Spine (Var a') m | a == a' && length m == length n -> do -- Gvar-Gvar - same
      h <- getNew
      let act (xi, yi) next = do
            vi <- getNew
            sub' <- catchError (Just <$> unify'' (toTm xi :=: toTm yi)) $ \_ -> return Nothing
            (xs,zs,sub) <- next
            case sub' of
              Just sub' -> return (vi:xs,vi:zs, sub' *** sub)              
              Nothing   -> return (vi:xs,zs, sub)
                
      (xs,zs,sub) <- foldr' act (return (mempty, mempty, mempty)) (zip (getTipe <$> n) (getTipe <$> m))
      
      let base = Spine (Var h) (Norm <$> Atom <$> var <$> zs)
          f' = foldr' (\v t -> Abs v undefined t) base xs
      return (sub *** a |-> f')
      
    Spine (Var f) xs :=: Spine (Var g) ys | f /= g -> do -- Gvar-Gvar - diff
      h <- getNew
      let act xi next = do
            sub' <- flip catchError (const $ return Nothing) $ msum $ flip fmap ys $ \yi -> do
              sub <- unify'' (toTm xi :=: toTm yi)
              return $ Just (yi,sub)
            (zs,sub) <- next
            case sub' of
              Just (yi,sub') -> return ((xi,yi):zs, sub' *** sub)              
              Nothing  -> return (zs, sub)
      (zs,sub) <- foldr' act (return (mempty, mempty)) xs
      
      let toVar (Atom (Spine (Var x) [])) = do
            t <- getNew
            return (x, Atom $ var t)
          toVar _ = badConstraint
      
      xs' <- mapM toVar (getTipe <$> xs)
      ys' <- mapM toVar (getTipe <$> ys)
      
      let baseF = Spine (Var h) (fst <$> zs)
          f' = foldr' (\(v,vt) t -> Abs v vt t) baseF xs'
          
          baseG = Spine (Var h) (snd <$> zs)
          g' = foldr' (\(v,vt) t -> Abs v vt t) baseG ys'
      return (sub *** (f |-> f' *** g |-> g'))

      
    _ :=: _ -> badConstraint

genUnifyEngine env consts = do
  s <- unifyAll env mempty consts
  return $ finishSubst s
  
recSubst :: (Eq b, Subst b) => Substitution -> b -> b
recSubst s f = fst $ head $ dropWhile (not . uncurry (==)) $ iterate (\(_,b) -> (b,subst s b)) (f,subst s f)  

finishSubst s = recSubst s s

finishSubstWith w s = case M.lookup w s of
  Just (Spine (Var v) []) -> finishSubst $ M.insert v (var w) (M.delete w s)
  _ -> s


----------------------------------------------------------------------
----------------------- LOGIC ENGINE ---------------------------------
----------------------------------------------------------------------
type Reification = VarGen (Tm,Substitution)
type Deduction = VarGen Substitution

unifier :: [(Name,Tp)] -> Tp -> Reification 
unifier cons t = do
  t' <- case t of
    Atom k -> return k
    _ -> empty
  let isAtom (Atom _) = True
      isAtom _ = False
  msum $ flip map (filter (isAtom . snd) cons) $ \(x,Atom con) -> do
    s <- genUnifyEngine (M.fromList cons) [con :=: t']
    return $ (var x,s) 

left :: Judgement -> Reification
left ([] :|- _) = empty
left ((x,f):context :|- r) = case f of
  Atom _ -> unifier [(x,f)] r
  ForallImp nm t1 t2 -> do
    nm' <- getNew
    y <- getNew
    (m,so) <- left $ (y,subst (nm |-> var nm') t2):context :|- r
    let n = case M.lookup nm' so of
          Nothing -> var nm'
          Just a -> a
        s = seq n $ M.delete nm' so
    s' <- natural (subst s $ (x,f):context) $ subst s (n,t1)
    return (subst s' $ subst (y |-> Spine (Var x) []) m, s *** s')
    
  Forall nm t1 t2 -> do
    nm' <- getNew
    y <- getNew
    (m,so) <- left $ (y,subst (nm |-> var nm') t2):context :|- r
    let n = case M.lookup nm' so of
          Nothing -> var nm'
          Just a -> a
        s = seq n $ M.delete nm' so
    s' <- natural (subst s $ (x,f):context) $ subst s (n,t1)
    return (subst s' $ subst (y |-> Spine (Var x) [Norm $ Atom n]) m, s *** s')

right :: Judgement -> Reification
right (context :|- r) = case r of
  Atom _ -> unifier context r
  ForallImp nm t1 t2 -> do
    nm' <- getNew
    (v,s) <- solve $ (nm', t1):context :|- subst (nm |-> cons nm') t2
    return $ (toTm $ ForallImp nm' t1 (Atom v), s)
  Forall nm t1 t2 -> do
    nm' <- getNew
    (v,s) <- solve $ (nm', t1):context :|- subst (nm |-> cons nm') t2
    return $ (toTm $ Forall nm' t1 (Atom v), s)

solve :: Judgement -> Reification
solve judge@(context :|- r) = right judge <|> (msum $ useSingle (\f ctx -> left $ f:ctx :|- r) context)
  where useSingle f lst = sw id lst
          where sw _ [] = []
                sw placeOnEnd (a:lst) =  f a (placeOnEnd lst):sw (placeOnEnd . (a:)) lst

natural :: [(Name, Tp)] -> (Tm,Tp) -> Deduction
natural cont (tm,ty) = do
  let env = M.fromList cont
  (_, constraints) <- runWriterT $ checkTerm env tm ty
  genUnifyEngine (M.fromList cont) constraints
  

solver :: [(Name,Tp)] -> Tp -> Either String [(Name, Tm)]
solver axioms t = case runError $ runStateT (solve $ axioms :|- t) 0 of
  Right ((tm,s),_) -> Right $ ("query" , varsToCons tm):(recSubst s $ map (\a -> (a,var a)) $ S.toList $ freeVariables t)
    where varsToCons = subst $ M.fromList $ map (\(a,_) -> (a,cons a)) axioms
  Left s -> Left $ "reification not possible: "++s
  
-----------------------------------------------------------------
----------------------- Type Checker ----------------------------    
-----------------------------------------------------------------
type Environment = M.Map Name Tp
type NatDeduct = WriterT [Constraint Tm] VarGen

checkVariable :: Environment -> Variable -> Tp -> NatDeduct Tp
checkVariable env v t = case v of
  Cons nm -> case env ! nm of
    Nothing -> error $ nm++" was not found in the environment in "++show v
    Just t' -> do
      tell [toTm t' :=: toTm t]
      return t'
  Var nm -> case env ! nm of
    Nothing -> do 
      (t'',s) <- lift $ solve $ M.toList env :|- t
      tell $ map (\(s,t) -> var s :=: t ) $ M.toList s 
      tell [var nm :=: t'']
      return t
      -- I'm not sure this makes sense at all.
      -- in the mean time, assume there is only one use of each unbound variable
    Just t' -> do
      tell [toTm t' :=: toTm t]
      return t'
      
checkTerm :: Environment -> Tm -> Tp -> NatDeduct (Tm,Tp)
checkTerm env v t = case v of
  Spine a l -> do
    tv1  <- (++':':show a) <$> getNew
    tv2l <- forM l $ \b -> do
      bty <- getNew
      nm' <- getNew
      t'  <- checkTerm env (toTm b) $ Atom $ var bty
      return (nm',t')
      
    tv1' <- checkVariable env a $ Atom $ var $ tv1
    
    tell [ toTm tv1' :=: toTm (foldr (\(nm,b) tp -> Forall nm (snd b) tp) t tv2l ) ]
    return $ (Spine a $ map (Norm . Atom . fst . snd) tv2l, t)
        
  AbsImp nm ty tm -> do  
    ty' <- checkTipe env ty
    v1  <- (++':':'<':nm) <$> getNew
    nm' <- (++'@':nm) <$> getNew
    v2  <- (++':':'>':nm) <$> getNew
    tell [ toTm (ForallImp v1 ty $ Atom $ var v2) :=: toTm t ]
    ((tm',t'),constraints) <- listen $ checkTerm (M.insert nm' ty env) (subst (nm |-> var nm') tm) $ Atom $ var v2
    s <- finishSubstWith nm' <$> (lift $ genUnifyEngine env constraints)
    tell $ map (\(s,t) -> var s :=: t ) $ M.toList s
    let s' = s *** nm' |-> var nm 
    return $ (AbsImp nm ty' $ subst s' tm' , ForallImp v1 ty t')
    
  Abs nm ty tm -> do
    ty' <- checkTipe env ty
    v1  <- (++':':'<':nm) <$> getNew
    nm' <- (++'@':nm) <$> getNew
    v2  <- (++':':'>':nm) <$> getNew

    tell [ toTm (Forall v1 ty $ Atom $ var v2) :=: toTm t ]
    
    ((tm',t'),constraints) <- listen $ checkTerm (M.insert nm' ty env) (subst (nm |-> var nm') tm) $ Atom $ var v2
    s <- finishSubstWith nm' <$> (lift $ genUnifyEngine env constraints)
    tell $ map (\(s,t) -> var s :=: t ) $ M.toList s
    let s' = s *** nm' |-> var nm 
    return $ (Abs nm ty' $ subst s' tm' , Forall v1 ty t')
    
checkTipe :: Environment -> Tp -> NatDeduct Tp
checkTipe env v = case v of
  Atom tm -> do
    (a,_) <- checkTerm env tm atom
    return $ Atom a
  ForallImp nm ty t -> do
    Forall nm' ty' t' <- checkTipe env (Forall nm ty t)
    return $ ForallImp nm' ty' t'
  Forall nm ty t -> do
    ty' <- checkTipe env ty
    nm' <- (++'*':nm) <$> getNew
    (a,constraints) <- listen $ checkTipe (M.insert nm' ty env) $ subst (nm |-> var nm') t
    s <- finishSubstWith nm' <$> (lift $ genUnifyEngine env constraints)
    
    tell $ map (\(s,t) -> var s :=: t ) $ M.toList s
    let s' = s *** nm' |-> var nm 
    return $ Forall nm ty' (subst s' a)
    
getCons tm = case tm of
  Spine (Cons t) _ -> return t
  Abs _ _ t -> getCons t
  _ -> throwError $ "can't place a non constructor term here: "++ show tm

getPred tp = case tp of
  Atom t -> getCons t
  Forall _ _ t -> getPred t
  ForallImp _ _ t -> getPred t

-- need to do a topological sort of types and predicates.
-- such that types get minimal correct bindings
checkType :: Environment -> Name -> Tp -> Choice Tp
checkType env base ty = fmap fst $ flip runStateT 0 $ appendErr ("FOR: "++show ty) $ do
  con <- getPred ty
  unless (null base || con == base) 
    $ throwError $ "non local name \""++con++"\" expecting "++base
  (ty',constraints) <- runWriterT $ checkTipe env ty
  
  s <- appendErr ("CONSTRAINTS: "++show constraints) $ genUnifyEngine env constraints
  
  return $ subst s ty'

typeCheckPredicate :: Environment -> Predicate -> Choice Predicate
typeCheckPredicate env (Query nm ty) = appendErr ("in query : "++show ty) $ do
  void $ checkType env "" ty
  return $ Query nm ty
typeCheckPredicate env pred@(Predicate pnm pty plst) = appendErr ("in\n"++show pred) $ do
  pty' <- appendErr ("in name: "++ pnm ++" : "++show pty) $
    checkType env "atom" pty
  plst' <- forM plst $ \(nm,ty) -> 
    appendErr ("in case: " ++nm ++ " = "++show ty) $ (nm,) <$> checkType env pnm ty
  return $ Predicate pnm pty' plst'

typeCheckAll :: [Predicate] -> Choice [Predicate]
typeCheckAll preds = forM preds $ typeCheckPredicate assumptions
  where assumptions = M.fromList $ 
                      ("atom", atom): -- atom : atom is a given.
                      ("forall", Atom $ Abs "_" (Atom $ Abs "_" atom $ cons "atom") $ cons "atom"): -- atom : atom is a given.
                      concatMap (\st -> case st of
                                    Query _ _ -> []
                                    _ -> (predName st, predType st):predConstructors st) preds

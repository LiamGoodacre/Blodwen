module TTImp.Elab.State

import TTImp.TTImp
import Core.CaseTree
import Core.Context
import Core.TT
import Core.Normalise
import Core.Unify

import Data.List

-- How the elaborator should deal with IBindVar:
-- * NONE: IBindVar is not valid (rhs of an definition, top level expression)
-- * PI True: Bind implicits as Pi, in the appropriate scope, and bind
--            any additional holes
-- * PI False: As above, but don't bind additional holes
-- * PATTERN: Bind implicits as PVar, but only at the top level
public export
data ImplicitMode = NONE | PI Bool | PATTERN

public export
data ElabMode = InType | InLHS | InExpr

public export
record EState (vars : List Name) where
  constructor MkElabState
  boundNames : List (Name, (Term vars, Term vars))
                  -- implicit pattern/type variable bindings and the 
                  -- term/type they elaborated to
  toBind : List (Name, (Term vars, Term vars))
                  -- implicit pattern/type variables which haven't been
                  -- bound yet.
  boundImplicits : List Name
                  -- names we've already decided will be bound implicits, no
                  -- we don't need to bind again
  asVariables : List Name -- Names bound in @-patterns
  implicitsUsed : List Name -- explicitly given implicits which have been used
                            -- in the current application (need to keep track, as
                            -- they may not be given in the same order as they are 
                            -- needed in the type)
  defining : Name -- Name of thing we're currently defining

public export
Elaborator : Type -> Type
Elaborator annot
    = {vars : List Name} ->
      Ref Ctxt Defs -> Ref UST (UState annot) ->
      Ref ImpST (ImpState annot) ->
      Env Term vars -> NestedNames vars -> 
      ImpDecl annot -> Core annot ()

public export
record ElabInfo annot where
  constructor MkElabInfo
  topLevel : Bool -- at the top level of a type sig (i.e not in a higher order type)
  implicitMode : ImplicitMode
  elabMode : ElabMode
  implicitsGiven : List (Name, RawImp annot)

export
initElabInfo : ImplicitMode -> ElabMode -> ElabInfo annot
initElabInfo imp elab = MkElabInfo True imp elab []

-- A label for the internal elaborator state
export
data EST : Type where

export
initEState : Name -> EState vars
initEState n = MkElabState [] [] [] [] [] n

-- Convenient way to record all of the elaborator state, for the times
-- we need to backtrack
export
AllState : List Name -> Type -> Type
AllState vars annot = (Defs, UState annot, EState vars, ImpState annot)

export
getAllState : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
              {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
              Core annot (AllState vars annot)
getAllState
    = do ctxt <- get Ctxt
         ust <- get UST
         est <- get EST
         ist <- get ImpST
         pure (ctxt, ust, est, ist)

export
putAllState : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
           {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
           AllState vars annot -> Core annot ()
putAllState (ctxt, ust, est, ist)
    = do put Ctxt ctxt
         put UST ust
         put EST est
         put ImpST ist

export
getState : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
           {auto i : Ref ImpST (ImpState annot)} ->
           Core annot (Defs, UState annot, ImpState annot)
getState
    = do ctxt <- get Ctxt
         ust <- get UST
         ist <- get ImpST
         pure (ctxt, ust, ist)

export
putState : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
           {auto i : Ref ImpST (ImpState annot)} ->
           (Defs, UState annot, ImpState annot)-> Core annot ()
putState (ctxt, ust, ist)
    = do put Ctxt ctxt
         put UST ust
         put ImpST ist

export
saveImps : {auto e : Ref EST (EState vars)} -> Core annot (List Name)
saveImps
    = do est <- get EST
         pure (implicitsUsed est)

export
restoreImps : {auto e : Ref EST (EState vars)} -> List Name -> Core annot ()
restoreImps imps
    = do est <- get EST
         put EST (record { implicitsUsed = imps } est)

export
usedImp : {auto e : Ref EST (EState vars)} -> Name -> Core annot ()
usedImp imp
    = do est <- get EST
         put EST (record { implicitsUsed $= (imp :: ) } est)

-- Check that explicitly given implicits that we've used are allowed in the
-- the current application
export
checkUsedImplicits : {auto e : Ref EST (EState vars)} ->
                     annot -> List Name -> List Name -> Term vars -> Core annot ()
checkUsedImplicits loc used [] tm = pure ()
checkUsedImplicits loc used given tm
    = let unused = filter (\x => not (x `elem` used)) given in
          case unused of
               [] => -- remove the things which were given, and are now part of
                     -- an application, from the 'implicitsUsed' list, because
                     -- we've now verified that they were used correctly.
                     restoreImps (filter (\x => not (x `elem` given)) used)
               (n :: _) => throw (InvalidImplicit loc n tm)

export
weakenedEState : {auto e : Ref EST (EState vs)} ->
                 Core annot (Ref EST (EState (n :: vs)))
weakenedEState
    = do est <- get EST
         e' <- newRef EST (MkElabState (map wknTms (boundNames est))
                                       (map wknTms (toBind est))
                                       (boundImplicits est)
                                       (asVariables est)
                                       (implicitsUsed est)
                                       (defining est))
         pure e'
  where
    wknTms : (Name, (Term vs, Term vs)) -> 
             (Name, (Term (n :: vs), Term (n :: vs)))
    wknTms (f, (x, y)) = (f, (weaken x, weaken y))

-- remove the outermost variable from the unbound implicits which have not
-- yet been bound. If it turns out to depend on it, that means it can't
-- be bound at the top level, which is an error.
export
strengthenedEState : {auto e : Ref EST (EState (n :: vs))} ->
                     (top : Bool) -> annot ->
                     Core annot (EState vs)
strengthenedEState True loc = do est <- get EST
                                 pure (initEState (defining est))
strengthenedEState False loc 
    = do est <- get EST
         bns <- traverse strTms (boundNames est)
         todo <- traverse strTms (toBind est)
         pure (MkElabState bns todo (boundImplicits est) 
                                    (asVariables est)
                                    (implicitsUsed est) 
                                    (defining est))
  where
    -- Remove any instance of the top level local variable from an
    -- application. Fail if it turns out to be necessary.
    -- NOTE: While this isn't strictly correct given the type of the hole
    -- which stands for the unbound implicits, it's harmless because we
    -- never actualy *use* that hole - this process is only to ensure that the
    -- unbound implicit doesn't depend on any variables it doesn't have
    -- in scope.
    removeArgVars : List (Term (n :: vs)) -> Maybe (List (Term vs))
    removeArgVars [] = pure []
    removeArgVars (Local (There p) :: args) 
        = do args' <- removeArgVars args
             pure (Local p :: args')
    removeArgVars (Local Here :: args) 
        = removeArgVars args
    removeArgVars (a :: args)
        = do a' <- shrinkTerm a (DropCons SubRefl)
             args' <- removeArgVars args
             pure (a' :: args')

    removeArg : Term (n :: vs) -> Maybe (Term vs)
    removeArg tm with (unapply tm)
      removeArg (apply f args) | ArgsList 
          = do args' <- removeArgVars args
               f' <- shrinkTerm f (DropCons SubRefl)
               pure (apply f' args')

    strTms : (Name, (Term (n :: vs), Term (n :: vs))) -> 
             Core annot (Name, (Term vs, Term vs))
    strTms {vs} (f, (x, y))
        = case (removeArg x, shrinkTerm y (DropCons SubRefl)) of
               (Just x', Just y') => pure (f, (x', y'))
               _ => throw (GenericMsg loc ("Invalid unbound implicit " ++ show f))

export
clearEState : {auto e : Ref EST (EState vs)} ->
              Core annot ()
clearEState = do est <- get EST
                 put EST (initEState (defining est))

export
clearToBind : {auto e : Ref EST (EState vs)} ->
              Core annot ()
clearToBind
    = do est <- get EST
         put EST (record { toBind = [] } est)
 
export
dropTmIn : List (a, (c, d)) -> List (a, d)
dropTmIn = map (\ (n, (_, t)) => (n, t))

-- Record the given names, arising as unbound implicits, as having been bound
-- now (so don't bind them again)
export
setBound : {auto e : Ref EST (EState vars)} ->
           List Name -> Core annot ()
setBound ns
    = do est <- get EST
         put EST (record { boundImplicits $= (ns ++) } est)

-- 'toBind' are the names which are to be implicitly bound (pattern bindings and
-- unbound implicits).
export
getToBind : {auto c : Ref Ctxt Defs} -> {auto e : Ref EST (EState vars)} ->
            {auto u : Ref UST (UState annot)} ->
            Env Term vars ->
            Core annot (List (Name, Term vars))
getToBind {vars} env
    = do est <- get EST
         ust <- get UST
         gam <- getCtxt
         log 5 $ "Before normImps " ++ show (map (norm gam) (reverse $ toBind est))
         log 10 $ "With holes " ++ show (map snd (holes ust))
         -- if we encounter a hole name that we've seen before, and is now 
         -- stored in boundImplicits, we don't want to bind it again
         normImps gam (boundImplicits est) (asLast (asVariables est)
                                                   (reverse $ toBind est))
  where
    -- put the @-pattern bound names last (so that we have the thing they're
    -- equal to bound first)
    asLast : List Name -> List (Name, Term vars, Term vars) -> 
                          List (Name, Term vars, Term vars)
    asLast asvars ns 
        = filter (\p => not (fst p `elem` asvars)) ns ++
          filter (\p => fst p `elem` asvars) ns

    norm : Gamma -> (Name, Term vars, Term vars) -> (Name, Term vars)
    norm gam (n, tm, ty) = (n, normaliseHoles gam env tm)

    normImps : Gamma -> List Name -> List (Name, Term vars, Term vars) -> 
               Core annot (List (Name, Term vars))
    normImps gam ns [] = pure []
    normImps gam ns ((PV n, tm, ty) :: ts) 
        = do rest <- normImps gam (PV n :: ns) ts
             pure ((PV n, normaliseHoles gam env ty) :: rest)
    normImps gam ns ((n, tm, ty) :: ts)
        = case (getFnArgs (normaliseHoles gam env tm)) of
             (Ref nt n', args) => 
                do hole <- isHole n'
                   if hole && not (n' `elem` ns)
                      then do rest <- normImps gam (n' :: ns) ts
                              pure ((n', normaliseHoles gam env ty) :: rest)
                      -- unified to something concrete, so no longer relevant, drop it
                      else normImps gam ns ts
             _ => do rest <- normImps gam (n :: ns) ts
                     pure ((n, normaliseHoles gam env ty) :: rest)

-- Bind implicit arguments, returning the new term and its updated type
bindImplVars : Int -> 
               ImplicitMode ->
               Gamma ->
               List (Name, Term vars) ->
               Term vars -> Term vars -> (Term vars, Term vars)
bindImplVars i NONE gam args scope scty = (scope, scty)
bindImplVars i mode gam [] scope scty = (scope, scty)
bindImplVars i mode gam ((n, ty) :: imps) scope scty
    = let (scope', ty') = bindImplVars (i + 1) mode gam imps scope scty
          tmpN = MN "unb" i
          repNameTm = repName (Ref Bound tmpN) scope' 
          repNameTy = repName (Ref Bound tmpN) ty'
          n' = dropNS n in
          case mode of
               PATTERN =>
                  case lookupDefExact n gam of
                       Just (PMDef _ _ t) =>
                          -- if n is an accessible pattern variable, bind it,
                          -- otherwise reduce it
                          case n of
                               PV _ =>
                                  (Bind n' (PLet (embed (normalise gam [] (Ref Func n))) ty) 
                                           (refToLocal tmpN n' repNameTm), 
                                   Bind n' 
                                        (PLet (embed (normalise gam [] (Ref Func n))) ty) 
                                              (refToLocal tmpN n' repNameTy))
                               _ => (subst (embed (normalise gam [] (Ref Func n)))
                                           (refToLocal tmpN n repNameTm),
                                     subst (embed (normalise gam [] (Ref Func n)))
                                           (refToLocal tmpN n repNameTy))
                       _ =>
                          (Bind n' (PVar ty) (refToLocal tmpN n' repNameTm), 
                           Bind n' (PVTy ty) (refToLocal tmpN n' repNameTy))
               PI _ =>
                  case lookupDefExact n gam of
                     Just (PMDef _ _ t) =>
                        (subst (embed (normalise gam [] (Ref Func n)))
                               (refToLocal tmpN n repNameTm),
                         subst (embed (normalise gam [] (Ref Func n)))
                               (refToLocal tmpN n repNameTy))
                     _ => (Bind n' (Pi Implicit ty) (refToLocal tmpN n' repNameTm), ty')
               _ => (Bind n' (Pi Implicit ty) (refToLocal tmpN n' repNameTm), ty')
  where
    -- Replace the name applied to the given number of arguments 
    -- with another term
    repName : (new : Term vars) -> Term vars -> Term vars
    repName new (Local p) = Local p
    repName new (Ref nt fn)
        = case nameEq n fn of
               Nothing => Ref nt fn
               Just Refl => new
    repName new (Bind y b tm) 
        = Bind y (assert_total (map (repName new) b)) 
                 (repName (weaken new) tm)
    repName new (App fn arg) 
        = case getFn fn of
               Ref nt fn' =>
                   case nameEq n fn' of
                        Nothing => App (repName new fn) (repName new arg)
                        Just Refl => 
                           let locs = case lookupDefExact fn' gam of
                                           Just (Hole i _) => i
                                           _ => 0
                                        in
                               apply new (drop locs (getArgs (App fn arg)))
               _ => App (repName new fn) (repName new arg)
    repName new (PrimVal y) = PrimVal y
    repName new Erased = Erased
    repName new TType = TType

export
bindImplicits : ImplicitMode ->
                Gamma -> Env Term vars ->
                List (Name, Term vars) ->
                Term vars -> Term vars -> (Term vars, Term vars)
bindImplicits {vars} mode gam env hs tm ty 
   = bindImplVars 0 mode gam (map nHoles hs)
                             (normaliseHoles gam env tm)
                             (normaliseHoles gam env ty)
  where
    nHoles : (Name, Term vars) -> (Name, Term vars)
    nHoles (n, ty) = (n, normaliseHoles gam env ty)

export
bindTopImplicits : ImplicitMode -> Gamma -> Env Term vars ->
                   List (Name, ClosedTerm) -> Term vars -> Term vars ->
                   (Term vars, Term vars)
bindTopImplicits {vars} mode gam env hs tm ty
    = bindImplicits mode gam env (map weakenVars hs) tm ty
  where
    weakenVars : (Name, ClosedTerm) -> (Name, Term vars)
    weakenVars (n, tm) = (n, rewrite sym (appendNilRightNeutral vars) in
                                     weakenNs vars tm)

-- Find any holes in the resulting expression, and implicitly bind them
-- at the top level (i.e. they can't depend on any explicitly given
-- arguments).
-- Return the updated term and type, and the names of holes which occur
export
findHoles : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
            ImplicitMode -> Env Term vars -> Term vars -> Term vars ->
            Core annot (Term vars, Term vars, List Name) 
findHoles NONE env tm exp = pure (tm, exp, [])
findHoles (PI False) env tm exp = pure (tm, exp, [])
findHoles mode env tm exp
    = do h <- newRef HVar []
         tm <- holes h tm
         hs <- get HVar
         gam <- getCtxt
         log 5 $ "Extra implicits to bind: " ++ show (reverse hs)
         let (tm', ty) = bindTopImplicits mode gam env (reverse hs) tm exp
         traverse implicitBind (map fst hs)
         pure (tm', ty, map fst hs)
  where
    data HVar : Type where -- empty type to label the local state

    mkType : (vars : List Name) -> Term hs -> Maybe (Term hs)
    mkType (v :: vs) (Bind tm (Pi _ ty) sc) 
        = do sc' <- mkType vs sc
             shrinkTerm sc' (DropCons SubRefl)
    mkType _ tm = pure tm

    processHole : Ref HVar (List (Name, ClosedTerm)) ->
                  Name -> (vars : List Name) -> ClosedTerm ->
                  Core annot ()
    processHole h n vars ty
       = do hs <- get HVar
--             putStrLn $ "IMPLICIT: " ++ show (n, vars, ty)
            case mkType vars ty of
                 Nothing => pure ()
                 Just impTy =>
                    case lookup n hs of
                         Just _ => pure ()
                         Nothing => put HVar ((n, impTy) :: hs)

    holes : Ref HVar (List (Name, ClosedTerm)) ->
            Term vars -> 
            Core annot (Term vars)
    holes h {vars} (Ref nt fn) 
        = do gam <- getCtxt
             case lookupDefTyExact fn gam of
                  Just (Hole _ _, ty) =>
                       do processHole h fn vars ty
                          pure (Ref nt fn)
                  _ => pure (Ref nt fn)
    holes h (App fn arg)
        = do fn' <- holes h fn
             arg' <- holes h arg
             pure (App fn' arg')
    -- Allow implicits under 'Pi', 'PVar', 'PLet' only
    holes h (Bind y (Pi imp ty) sc)
        = do ty' <- holes h ty
             sc' <- holes h sc
             pure (Bind y (Pi imp ty') sc')
    holes h (Bind y (PVar ty) sc)
        = do ty' <- holes h ty
             sc' <- holes h sc
             pure (Bind y (PVar ty') sc')
    holes h (Bind y (PLet val ty) sc)
        = do val' <- holes h val
             ty' <- holes h ty
             sc' <- holes h sc
             pure (Bind y (PLet val' ty') sc')
    holes h tm = pure tm

export
renameImplicits : Gamma -> Term vars -> Term vars
renameImplicits gam (Bind (PV n) b sc) 
    = case lookupDefExact (PV n) gam of
           Just (PMDef _ _ def) =>
--                 trace ("OOPS " ++ show n ++ " = " ++ show def) $
                    Bind (UN n) b (renameImplicits gam (renameTop (UN n) sc))
           _ => Bind (UN n) b (renameImplicits gam (renameTop (UN n) sc))
renameImplicits gam (Bind n b sc) 
    = Bind n b (renameImplicits gam sc)
renameImplicits gam t = t

export
convert : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
          {auto e : Ref EST (EState vars)} ->
          annot -> ElabMode -> Env Term vars -> NF vars -> NF vars -> 
          Core annot (List Name)
convert loc elabmode env x y 
    = let umode = case elabmode of
                       InLHS => InLHS
                       _ => InTerm in
          catch (do solveConstraints umode
                    log 10 $ "Unifying " ++ show (quote empty env x) ++ " and " 
                                         ++ show (quote empty env y)
                    vs <- unify umode loc env x y
                    solveConstraints umode
                    pure vs)
            (\err => do gam <- getCtxt 
                        throw (WhenUnifying loc env
                                            (normaliseHoles gam env (quote empty env x))
                                            (normaliseHoles gam env (quote empty env y))
                                  err))
  
export
inventFnType : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
               {auto e : Ref EST (EState vars)} ->
               annot -> Env Term vars -> (bname : Name) ->
               Core annot (Term vars, Term (bname :: vars))
inventFnType loc env bname
    = do an <- genName "argh"
         scn <- genName "sch"
         argTy <- addBoundName loc an False env TType
         scTy <- addBoundName loc scn False (Pi Explicit argTy :: env) TType
         pure (argTy, scTy)

-- Given a raw term, collect the explicitly given implicits {x = tm} in the
-- top level application, and return an updated term without them
export
collectGivenImps : RawImp annot -> (RawImp annot, List (Name, RawImp annot))
collectGivenImps (IImplicitApp loc fn nm arg)
    = let (fn', args') = collectGivenImps fn in
          (fn', (nm, arg) :: args')
collectGivenImps (IApp loc fn arg)
    = let (fn', args') = collectGivenImps fn in
          (IApp loc fn' arg, args')
collectGivenImps tm = (tm, [])

-- try an elaborator, if it fails reset the state and return 'Left',
-- otherwise return 'Right'
export
tryError : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
           {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
           Core annot a -> Core annot (Either (Error annot) a)
tryError elab 
    = do -- store the current state of everything
         st <- getAllState
         catch (do res <- elab 
                   pure (Right res))
               (\err => do -- reset the state
                           putAllState st
                           pure (Left err))

-- try one elaborator; if it fails, try another
export
tryElab : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
          {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
          Core annot a ->
          Core annot a ->
          Core annot a
tryElab elab1 elab2
    = do Right ok <- tryError elab1
               | Left err => elab2
         pure ok

-- try one elaborator; if it fails, handle the error
export
handle : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
         {auto i : Ref ImpST (ImpState annot)} ->
         Core annot a ->
         (Error annot -> Core annot a) ->
         Core annot a
handle elab1 elab2
    = do -- store the current state of everything
         st <- getState
         catch elab1
               (\err => do -- reset the state
                           putState st
                           elab2 err)

-- try all elaborators, return the results from the ones which succeed
-- and the corresponding elaborator state
export
successful : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
             {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
             List (Core annot a) ->
             Core annot (List (Either (Error annot)
                                      (a, AllState vars annot)))
successful [] = pure []
successful (elab :: elabs)
    = do init_st <- getAllState
         Right res <- tryError elab
               | Left err => do rest <- successful elabs
                                pure (Left err :: rest)

         elabState <- getAllState -- save state at end of successful elab
         -- reinitialise state for next elabs
         putAllState init_st
         rest <- successful elabs
         pure (Right (res, elabState) :: rest)

export
exactlyOne : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
             {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
             annot ->
             List (Core annot (Term vars, Term vars)) ->
             Core annot (Term vars, Term vars)
exactlyOne loc [elab] = elab
exactlyOne loc all
    = do elabs <- successful all
         case rights elabs of
              [(res, state)] =>
                   do putAllState state
                      pure res
              rs => throw (altError (lefts elabs) rs)
  where
    -- If they've all failed, collect all the errors
    -- If more than one succeeded, report the ambiguity
    altError : List (Error annot) -> List ((Term vars, Term vars), AllState vars annot) ->
               Error annot
    altError ls [] = AllFailed ls
    altError ls rs = AmbiguousElab loc (map (\x => fst (fst x)) rs)

export
anyOne : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
         {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
         annot ->
         List (Core annot (Term vars, Term vars)) ->
         Core annot (Term vars, Term vars)
anyOne loc [] = throw (GenericMsg loc "All elaborators failed")
anyOne loc [elab] = elab
anyOne loc (e :: es) = tryElab e (anyOne loc es)


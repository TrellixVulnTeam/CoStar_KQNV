Require Import Arith List Omega PeanoNat Program.Wf String.
Require Import GallStar.Defs.
Require Import GallStar.Lex.
Require Import GallStar.Tactics.
Require Import GallStar.Termination.
Require Import GallStar.Utils.
        Import ListNotations.
Set Implicit Arguments.

(* Hide an alternative definition of "sum" from NtSet *)
Definition sum := Datatypes.sum.

Definition location_stack := (location * list location)%type.

Record subparser := Sp { avail      : NtSet.t
                       ; prediction : list symbol
                       ; stack      : location_stack
                       }.

(* Error values that the prediction mechanism can return *)
Inductive prediction_error :=
| SpInvalidState  : prediction_error
| SpLeftRecursion : nonterminal -> prediction_error.

Open Scope list_scope.

(* "move" operation *)

Inductive subparser_move_result :=
| SpMoveSucc   : subparser -> subparser_move_result
| SpMoveReject : subparser_move_result
| SpMoveError  : prediction_error -> subparser_move_result.

Definition moveSp (g : grammar) (tok : token) (sp : subparser) : subparser_move_result :=
  match sp with
  | Sp _ pred stk =>
    match stk with
    | (Loc _ _ [], [])                => SpMoveReject
    | (Loc _ _ [], _ :: _)            => SpMoveError SpInvalidState
    | (Loc _ _ (NT _ :: _), _)        => SpMoveError SpInvalidState
    | (Loc xo pre (T a :: suf), locs) =>
      match tok with
      | (a', _) =>
        if t_eq_dec a' a then
          SpMoveSucc (Sp (allNts g) pred (Loc xo (pre ++ [T a]) suf, locs))
        else
          SpMoveReject
      end
    end
  end.

Definition move_result := sum prediction_error (list subparser).

Fixpoint aggrMoveResults (smrs : list subparser_move_result) : 
  move_result :=
  match smrs with
  | []           => inr []
  | smr :: smrs' =>
    match (smr, aggrMoveResults smrs') with
    | (SpMoveError e, _)       => inl e
    | (_, inl e)               => inl e
    | (SpMoveSucc sp, inr sps) => inr (sp :: sps)
    | (SpMoveReject, inr sps)  => inr sps
    end
  end.

Definition move (g : grammar) (tok : token) (sps : list subparser) : move_result :=
  aggrMoveResults (map (moveSp g tok) sps).

(* "closure" operation *)

Inductive subparser_closure_step_result :=
| SpClosureStepDone  : subparser_closure_step_result
| SpClosureStepK     : list subparser -> subparser_closure_step_result
| SpClosureStepError : prediction_error -> subparser_closure_step_result.

Definition spClosureStep (g : grammar) (sp : subparser) : 
  subparser_closure_step_result :=
  match sp with
  | Sp av pred (loc, locs) =>
    match loc with
    | Loc _ _ [] =>
      match locs with
      | []                        => SpClosureStepDone
      | (Loc _ _ []) :: _         => SpClosureStepError SpInvalidState
      | (Loc _ _ (T _ :: _)) :: _ => SpClosureStepError SpInvalidState
      | (Loc xo_cr pre_cr (NT x :: suf_cr)) :: locs_tl =>
        let stk':= (Loc xo_cr (pre_cr ++ [NT x]) suf_cr, locs_tl) 
        in  SpClosureStepK [Sp (NtSet.add x av) pred stk']
      end
    | Loc _ _ (T _ :: _)       => SpClosureStepDone
    | Loc xo pre (NT x :: suf) =>
      if NtSet.mem x av then
        let sps' := map (fun rhs => Sp (NtSet.remove x av) 
                                       pred 
                                       (Loc (Some x) [] rhs, loc :: locs))
                        (rhssForNt g x)
        in  SpClosureStepK sps'
      else if NtSet.mem x (allNts g) then
             SpClosureStepError (SpLeftRecursion x)
           else
             SpClosureStepK []
    end
  end.

Definition closure_result := sum prediction_error (list subparser).

Fixpoint aggrClosureResults (crs : list closure_result) : closure_result :=
  match crs with
  | [] => inr []
  | cr :: crs' =>
    match (cr, aggrClosureResults crs') with
    | (inl e, _)          => inl e
    | (inr _, inl e)      => inl e
    | (inr sps, inr sps') => inr (sps ++ sps')
    end
  end.

Definition spMeas (g : grammar) (sp : subparser) : nat * nat :=
  match sp with
  | Sp av _ stk =>
    let m := maxRhsLength g in
    let e := NtSet.cardinal av               
    in  (stackScore stk (1 + m) e, stackHeight stk)
  end.

Lemma spClosureStep_meas_lt :
  forall (g : grammar)
         (sp sp' : subparser)
         (sps'   : list subparser),
    spClosureStep g sp = SpClosureStepK sps'
    -> In sp' sps'
    -> lex_nat_pair (spMeas g sp') (spMeas g sp).
Proof.
  intros g sp sp' sps' hs hi; unfold spClosureStep in hs; repeat dmeq h; tc; inv hs.
  - (* lemma *)
    apply in_singleton_eq in hi; subst.
    unfold spMeas.
    pose proof stackScore_le_after_return as hle.
    specialize hle with (callee  := Loc lopt rpre [])
                        (caller  := Loc lopt0 rpre0 (NT n :: l3))
                        (caller' := Loc lopt0 (rpre0 ++ [NT n]) l3)
                        (x := n)
                        (x' := n)
                        (suf' := l3)
                        (av := avail0)
                        (locs := l2)
                        (b := 1 + maxRhsLength g).
    eapply le_lt_or_eq in hle; auto. 
    destruct hle as [hlt | heq]; auto.
    + apply pair_fst_lt; auto.
    + rewrite heq; apply pair_snd_lt; auto.
  - apply in_map_iff in hi.
    destruct hi as [rhs [heq hi]]; subst.
    unfold spMeas.
    apply pair_fst_lt.
    eapply stackScore_lt_after_push; simpl; eauto.
    apply NtSet.mem_spec; auto.
  - inv hi.
Defined.

Lemma acc_after_step :
  forall g sp sp' sps',
    spClosureStep g sp = SpClosureStepK sps'
    -> In sp' sps'
    -> Acc lex_nat_pair (spMeas g sp)
    -> Acc lex_nat_pair (spMeas g sp').
Proof.
  intros g so sp' sps' heq hi ha.
  eapply Acc_inv; eauto.
  eapply spClosureStep_meas_lt; eauto.
Defined.

Fixpoint spClosure (g  : grammar) 
                   (sp : subparser) 
                   (a  : Acc lex_nat_pair (spMeas g sp)) : closure_result :=
  match spClosureStep g sp as r return spClosureStep g sp = r -> _ with
  | SpClosureStepDone     => fun _  => inr [sp]
  | SpClosureStepError e  => fun _  => inl e
  | SpClosureStepK sps'   => 
    fun hs => 
      let crs := 
          dmap sps' (fun sp' hin => spClosure g sp' (acc_after_step _ _ _ hs hin a))
      in  aggrClosureResults crs
  end eq_refl.

Definition closure (g : grammar) (sps : list subparser) :
  sum prediction_error (list subparser) :=
  aggrClosureResults (map (fun sp => spClosure g sp (lex_nat_pair_wf _)) sps).

(*
Lemma subparser_lt_after_return :
  forall g sp sp' av pred callee caller caller' locs x x' suf',
    sp = Sp av pred (callee, caller :: locs)
    -> sp' = Sp (NtSet.add x av) pred (caller', locs)
    -> callee.(rsuf)  = []
    -> caller.(rsuf)  = NT x' :: suf'
    -> caller'.(rsuf) = suf'
    -> lex_nat_pair (meas g sp') (meas g sp).
Proof.
  intros g sp sp' av pred ce cr cr' locs x x' suf' Hsp Hsp' Hce Hcr Hr'; subst.
  unfold meas.
  pose proof (stackScore_le_after_return ce cr cr' x x' cr'.(rsuf)
                                         av locs (1 + maxRhsLength g)) as Hle.
  apply le_lt_or_eq in Hle; auto; destruct Hle as [Hlt | Heq].
  - apply pair_fst_lt; auto.
  - rewrite Heq; apply pair_snd_lt; auto.
Defined.

Lemma acc_after_return :
  forall g sp sp' callee caller caller' av pred pre_ce pre_cr suf_tl locs locs_tl xo y zo,
    Acc lex_nat_pair (meas g sp)
    -> sp = Sp av pred (callee, locs)
    -> callee = Loc zo pre_ce []
    -> locs = caller :: locs_tl
    -> caller = Loc xo pre_cr (NT y :: suf_tl)
    -> caller' = Loc xo (pre_cr ++ [NT y]) suf_tl
    -> sp' = Sp (NtSet.add y av) pred (caller', locs_tl)
    -> Acc lex_nat_pair (meas g sp').
Proof.
  intros g sp sp' callee caller caller' av pred pre_ce pre_cr suf_tl
         locs locs_tl xo y zo Hac Hsp Hce Hl Hcr Hcr' Hsp'; subst.
  eapply Acc_inv; eauto.
  eapply subparser_lt_after_return; eauto.
  simpl; auto.
Defined.

Lemma subparser_lt_after_push :
  forall g sp sp' av pred caller callee locs xo y pre suf' rhs,
    sp = Sp av pred (caller, locs)
    -> sp' = Sp (NtSet.remove y av) pred (callee, caller :: locs)
    -> caller = Loc xo pre (NT y :: suf')
    -> callee = Loc (Some y) [] rhs
    ->  NtSet.In y av
    -> In rhs (rhssForNt g y)
    -> lex_nat_pair (meas g sp') (meas g sp).
Proof.
  intros g sp sp' av pred cr ce locs xo y pre suf' rhs
         Hsp Hsp' Hcr Hce Hin Hin'; subst.
  unfold meas.
  apply pair_fst_lt.
  eapply stackScore_lt_after_push; simpl; eauto.
Defined.

Lemma acc_after_push :
  forall g sp sp' av pred pre suf_tl loc locs xo y,
    Acc lex_nat_pair (meas g sp)
    -> sp  = Sp av pred (loc, locs)
    -> loc = Loc xo pre (NT y :: suf_tl)
    -> NtSet.In y av
    -> In sp' (map (fun rhs => Sp (NtSet.remove y av)
                                  pred
                                  (Loc (Some y) [] rhs, loc :: locs))
                   (rhssForNt g y))
    -> Acc lex_nat_pair (meas g sp').
Proof.
  intros g sp sp' av pred pre suf_tl loc locs xo y Ha Hs Hl Hin Hin'; subst.
  eapply Acc_inv; eauto.
  apply in_map_iff in Hin'.
  destruct Hin' as [rhs [Heq Hin']]; subst.
  eapply subparser_lt_after_push; eauto.
Defined.

Definition mem_dec (x : nonterminal) (s : NtSet.t) :
  {~NtSet.In x s} + {NtSet.In x s}.
  destruct (NtSet.mem x s) eqn:Hm.
  - right.
    apply NtSet.mem_spec; auto.
  - left.
    unfold not; intros H.
    apply NtSet.mem_spec in H.
    congruence.
Defined.

(* subparser closure *)
Fixpoint spc (g : grammar) (sp : subparser)
             (a : Acc lex_nat_pair (meas g sp)) {struct a} :
             list (sum prediction_error subparser) :=
  match sp as s return sp = s -> _ with
  | Sp av pred (loc, locs) =>
    fun Hs =>
      match loc as l return loc = l -> _ with
      | Loc _ _ [] =>
        fun Hl =>
          match locs as ls return locs = ls -> _ with
          | []                        => fun _  => [inr sp]
          | (Loc _ _ []) :: _         => fun _  => [inl SpInvalidState]
          | (Loc _ _ (T _ :: _)) :: _ => fun _  => [inl SpInvalidState]
          | (Loc xo pre (NT y :: suf')) :: locs' =>
            fun Hls =>
              let stk':= (Loc xo (pre ++ [NT y]) suf', locs') in
              spc g (Sp (NtSet.add y av) pred stk')
                  (acc_after_return _ a Hs Hl Hls eq_refl eq_refl eq_refl)
          end eq_refl
      | Loc _ _ (T _ :: _)       => fun _ => [inr sp]
      | Loc xo pre (NT y :: suf') =>
        fun Hl =>
          match mem_dec y av with
          | left _   => [inl (SpLeftRecursion y)]
          | right Hm =>
            let sps' :=
                map (fun rhs =>
                       Sp (NtSet.remove y av) pred (Loc (Some y) [] rhs, loc :: locs))
                    (rhssForNt g y)
            in  dflat_map sps'
                          (fun sp' Hi =>
                             spc g sp' (acc_after_push _ _ a Hs Hl Hm Hi))
          end
      end eq_refl
  end eq_refl.

Definition closure (g : grammar) (sps : list subparser) :
  sum prediction_error (list subparser) :=
  let es := flat_map (fun sp => spc g sp (lex_nat_pair_wf _)) sps
  in  sumOfListSum es.
*)

(* LL prediction *)

Inductive prediction_result :=
| PredSucc   : list symbol      -> prediction_result
| PredAmbig  : list symbol      -> prediction_result
| PredReject :                     prediction_result
| PredError  : prediction_error -> prediction_result.

Definition finalConfig (sp : subparser) : bool :=
  match sp with
  | Sp _ _ (Loc _ _ [], []) => true
  | _                       => false
  end.

Definition allPredictionsEqual (sp : subparser) (sps : list subparser) : bool :=
  allEqual _ beqGamma sp.(prediction) (map prediction sps).

Definition handleFinalSubparsers (sps : list subparser) : prediction_result :=
  match filter finalConfig sps with
  | []         => PredReject
  | sp :: sps' => 
    if allPredictionsEqual sp sps' then
      PredSucc sp.(prediction)
    else
      PredAmbig sp.(prediction)
  end.

Fixpoint llPredict' (g : grammar) (ts : list token) (sps : list subparser) : prediction_result :=
  match ts with
  | []       => handleFinalSubparsers sps
  | t :: ts' =>
    match sps with 
    | []         => PredReject
    | sp :: sps' =>
      if allPredictionsEqual sp sps' then
        PredSucc sp.(prediction)
      else
        match move g t sps with
        | inl msg => PredError msg
        | inr mv  =>
          match closure g mv with
          | inl msg => PredError msg
          | inr cl  => llPredict' g ts' cl
          end
        end
    end
  end.

Definition startState (g : grammar) (x : nonterminal) (stk : location_stack) :
  sum prediction_error (list subparser) :=
  match stk with
  | (loc, locs) =>
    let init := map (fun rhs => Sp (allNts g) rhs (Loc (Some x) [] rhs, loc :: locs))
                    (rhssForNt g x)
    in  closure g init
  end.

Definition llPredict (g : grammar) (x : nonterminal) (stk : location_stack)
                     (ts : list token) : prediction_result :=
  match startState g x stk with
  | inl msg => PredError msg
  | inr sps => llPredict' g ts sps
  end.

(* LEMMAS *)

Lemma handleFinalSubparsers_success_from_subparsers :
  forall sps gamma,
    handleFinalSubparsers sps = PredSucc gamma
    -> exists sp, In sp sps /\ sp.(prediction) = gamma.
Proof.
  intros sps gamma Hh.
  unfold handleFinalSubparsers in Hh.
  dmeq Hf; tc.
  dm; tc.
  inv Hh.
  eexists; split; eauto.
  eapply filter_cons_in; eauto.
Defined.

Lemma handleFinalSubparsers_ambig_from_subparsers :
  forall sps gamma,
    handleFinalSubparsers sps = PredAmbig gamma
    -> exists sp, In sp sps /\ sp.(prediction) = gamma.
Proof.
  intros sps gamma Hh.
  unfold handleFinalSubparsers in Hh.
  dmeq Hf; tc.
  dm; tc.
  inv Hh.
  eexists; split; eauto.
  eapply filter_cons_in; eauto.
Defined.

Lemma move_unfold :
  forall g t sps,
    move g t sps = 
    aggrMoveResults (map (moveSp g t) sps).
Proof. 
  auto. 
Defined.

(*
Lemma in_sumOfListSum_result_in_input :
  forall A B (es : list (sum A B)) (b : B) (bs : list B),
    sumOfListSum es = inr bs
    -> In b bs
    -> In (inr b) es.
Proof.
  intros A B es b.
  induction es as [| e es' IH]; intros bs Hs Hi.
  - simpl in *. inv Hs. inv Hi.
  - simpl in Hs.
    destruct e as [a | b']; tc.
    destruct (sumOfListSum es') eqn:Htl; tc.
    inv Hs.
    inv Hi.
    + apply in_eq.
    + apply in_cons; eauto.
Defined.
*)

Lemma in_aggrMoveResults_result_in_input :
  forall (smrs : list subparser_move_result)
         (sp   : subparser)
         (sps  : list subparser),
    aggrMoveResults smrs = inr sps
    -> In sp sps
    -> In (SpMoveSucc sp) smrs.
Proof.
  intros smrs sp.
  induction smrs as [| smr smrs' IH]; intros sps ha hi; sis.
  - inv ha; inv hi.
  - destruct smr as [sp' | | e]; destruct (aggrMoveResults smrs') as [e' | sps']; 
      tc; inv ha.
    + inv hi; firstorder.
    + firstorder.
Qed.

Lemma aggrMoveResults_error_in_input :
  forall (smrs : list subparser_move_result)
         (e    : prediction_error),
    aggrMoveResults smrs = inl e
    -> In (SpMoveError e) smrs.
Proof.
  intros smrs e ha.
  induction smrs as [| smr smrs' IH]; sis; tc.
  destruct smr as [sp' | | e']; destruct (aggrMoveResults smrs') as [e'' | sps'];
    tc; inv ha; eauto.
Qed.
    
(*
Lemma in_extractSomes_result_in_input :
  forall A (a : A) (os : list (option A)),
    In a (extractSomes os)
    -> In (Some a) os.
Proof.
  intros A a os Hi; induction os as [| o os' IH]; simpl in Hi.
  - inv Hi.
  - destruct o as [a' |].
    + inv Hi.
      * apply in_eq.
      * apply in_cons; auto.
    + apply in_cons; auto.
Defined.
*)

Lemma moveSp_preserves_prediction :
  forall g t sp sp',
    moveSp g t sp = SpMoveSucc sp'
    -> sp'.(prediction) = sp.(prediction).
Proof.
  intros g t sp sp' hm.
  unfold moveSp in hm.
  destruct sp as [av pred (loc, locs)].
  destruct loc as [x pre suf].
  destruct suf as [| [a | x'] suf_tl]; tc.
  - destruct locs; tc.
  - destruct t as (a', _).
    destruct (t_eq_dec a' a); subst; tc.
    inv hm; auto.
Defined.

(*
Lemma moveSp_preserves_prediction :
  forall t sp sp',
    moveSp t sp = Some (inr sp')
    -> sp'.(prediction) = sp.(prediction).
Proof.
  intros t sp sp' Hm.
  unfold moveSp in Hm.
  destruct sp as [av pred (loc, locs)].
  destruct loc as [x pre suf].
  destruct suf as [| [a | x'] suf_tl]; tc.
  - destruct locs; tc.
  - destruct t as (a', _).
    destruct (t_eq_dec a' a); subst; tc.
    inv Hm; auto.
Defined.
*)

Lemma move_preserves_prediction :
  forall g t sp' sps sps',
    move g t sps = inr sps'
    -> In sp' sps'
    -> exists sp, In sp sps /\ sp'.(prediction) = sp.(prediction).
Proof.
  intros g t sp' sps sps' hm hi.
  unfold move in hm.
  eapply in_aggrMoveResults_result_in_input in hm; eauto.
  eapply in_map_iff in hm.
  destruct hm as [sp [hmsp hi']].
  eexists; split; eauto.
  eapply moveSp_preserves_prediction; eauto.
Defined.

(*
Lemma spc_unfold_return :
  forall g sp a es av pred stk loc locs x pre caller locs_tl x_cr pre_cr suf_cr y suf_tl_cr,
    spc g sp a = es
    -> sp = Sp av pred stk
    -> stk = (loc, locs)
    -> loc = Loc x pre []
    -> locs = caller :: locs_tl
    -> caller = Loc x_cr pre_cr suf_cr
    -> suf_cr = NT y :: suf_tl_cr
    -> exists a',
        spc g
            (Sp (NtSet.add y av)
                pred
                (Loc x_cr (pre_cr ++ [NT y]) suf_tl_cr, locs_tl))
            a' = es.
Proof.
  intros.
  subst.
  destruct a.
  simpl.
  eexists; eauto.
Defined.
*)

(*
Lemma in_dflat_map :
  forall (A B : Type) (l : list A) (f : forall x, In x l -> list B) (y : B) (ys : list B),
    dflat_map l f = ys
    -> In y ys
    -> (exists x Hin, In x l /\ In y (f x Hin)).
Proof.
  intros A B l f y ys Heq Hin; subst.
  induction l as [| x l' IH].
  + inv Hin.
  + simpl in Hin.
    apply in_app_or in Hin; destruct Hin as [Hl | Hr].
    * exists x; eexists; split; eauto.
      apply in_eq.
    * apply IH in Hr.
      destruct Hr as [x' [Hin [Hin' Hin'']]].
      exists x'; eexists; split; eauto.
      -- apply in_cons; auto.
      -- apply Hin''.
Defined.
*)

(* need a lemma that lets us unfold spClosure *)

Lemma spClosure_unfold :
  forall g sp a,
    spClosure g sp a =
    match spClosureStep g sp as r return spClosureStep g sp = r -> _ with
    | SpClosureStepDone     => fun _  => inr [sp]
    | SpClosureStepError e  => fun _  => inl e
    | SpClosureStepK sps'   => 
      fun hs => 
        let crs := 
            dmap sps' (fun sp' hin => spClosure g sp' (acc_after_step _ _ _ hs hin a))
        in  aggrClosureResults crs
    end eq_refl.
Proof.
  intros g sp a; destruct a; auto.
Qed.

Lemma spClosure_cases' :
  forall (g : grammar)
         (sp : subparser)
         (a : Acc lex_nat_pair (spMeas g sp))
         (sr : subparser_closure_step_result)
         (cr : closure_result)
         (heq : spClosureStep g sp = sr),
    match sr as r return spClosureStep g sp = r -> closure_result with
    | SpClosureStepDone     => fun _  => inr [sp]
    | SpClosureStepError e  => fun _  => inl e
    | SpClosureStepK sps'   => 
      fun hs => 
        let crs := 
            dmap sps' (fun sp' hin => spClosure g sp' (acc_after_step _ _ _ hs hin a))
        in  aggrClosureResults crs
    end heq = cr
    -> match cr with
       | inl e => 
         sr = SpClosureStepError e
         \/ exists (sps : list subparser)
                   (hs  : spClosureStep g sp = SpClosureStepK sps)
                   (crs : list closure_result),
             crs = dmap sps (fun sp' hi => 
                               spClosure g sp' (acc_after_step _ _ _ hs hi a))
             /\ aggrClosureResults crs = inl e
       | inr sps => 
         (sr = SpClosureStepDone
          /\ sps = [sp])
         \/ exists (sps' : list subparser)
                   (hs   : spClosureStep g sp = SpClosureStepK sps')
                   (crs  : list closure_result),
             crs = dmap sps' (fun sp' hi => 
                                spClosure g sp' (acc_after_step _ _ _ hs hi a))
             /\ aggrClosureResults crs = inr sps
       end.
Proof.
  intros g sp a sr cr heq.
  destruct sr as [ | sps | e]; destruct cr as [e' | sps']; intros heq'; tc; auto.
  - inv heq'; auto.
  - right; eauto.
  - right; eauto.
  - inv heq'; auto.
Qed.

Lemma spClosure_cases :
  forall g sp a cr,
    spClosure g sp a = cr
    -> match cr with
       | inl e => 
         spClosureStep g sp = SpClosureStepError e
         \/ exists (sps : list subparser)
                   (hs  : spClosureStep g sp = SpClosureStepK sps)
                   (crs : list closure_result),
             crs = dmap sps (fun sp' hi => 
                               spClosure g sp' (acc_after_step _ _ _ hs hi a))
             /\ aggrClosureResults crs = inl e
       | inr sps => 
         (spClosureStep g sp = SpClosureStepDone
          /\ sps = [sp])
         \/ exists (sps' : list subparser)
                   (hs   : spClosureStep g sp = SpClosureStepK sps')
                   (crs  : list closure_result),
             crs = dmap sps' (fun sp' hi => 
                                spClosure g sp' (acc_after_step _ _ _ hs hi a))
             /\ aggrClosureResults crs = inr sps
       end.
Proof.
  intros g sp a cr hs; subst.
  rewrite spClosure_unfold.
  eapply spClosure_cases'; eauto.
Qed.

Lemma spClosure_success_cases :
  forall g sp a sps,
    spClosure g sp a = inr sps
    -> (spClosureStep g sp = SpClosureStepDone
        /\ sps = [sp])
       \/ exists (sps' : list subparser)
                 (hs   : spClosureStep g sp = SpClosureStepK sps')
                 (crs  : list closure_result),
        crs = dmap sps' (fun sp' hi => 
                           spClosure g sp' (acc_after_step _ _ _ hs hi a))
        /\ aggrClosureResults crs = inr sps.
Proof.
  intros g sp a sps hs.
  apply spClosure_cases with (cr := inr sps); auto.
Qed.

Lemma spClosure_error_cases :
  forall g sp a e,
    spClosure g sp a = inl e
    -> spClosureStep g sp = SpClosureStepError e
       \/ exists (sps : list subparser)
                 (hs  : spClosureStep g sp = SpClosureStepK sps)
                 (crs : list closure_result),
        crs = dmap sps (fun sp' hi => 
                          spClosure g sp' (acc_after_step _ _ _ hs hi a))
        /\ aggrClosureResults crs = inl e.
Proof.
  intros g sp a e hs.
  apply spClosure_cases with (cr := inl e); auto.
Qed.
                   
Lemma sp_in_aggrClosureResults_result_in_input:
  forall (crs : list closure_result) 
         (sp  : subparser)
         (sps : list subparser),
    aggrClosureResults crs = inr sps 
    -> In sp sps 
    -> exists sps',
        In (inr sps') crs
        /\ In sp sps'.
Proof.
  intros crs; induction crs as [| cr crs IH]; intros sp sps ha hi.
  - inv ha; inv hi.
  - simpl in ha; destruct cr as [e | sps']; destruct (aggrClosureResults crs) as [e' | sps''];
      tc; inv ha.
    apply in_app_or in hi.
    destruct hi as [hi' | hi''].
    + eexists; split; eauto.
      apply in_eq.
    + apply IH in hi''; auto.
      destruct hi'' as [sps [hi hi']].
      eexists; split; eauto.
      apply in_cons; auto.
Qed.

Lemma error_in_aggrClosureResults_result_in_input:
  forall (crs : list closure_result) 
         (e   : prediction_error),
    aggrClosureResults crs = inl e
    -> In (inl e) crs.
Proof.
  intros crs e ha; induction crs as [| cr crs IH]; sis; tc.
  destruct cr as [e' | sps].
  - inv ha; auto.
  - destruct (aggrClosureResults crs) as [e' | sps']; tc; auto.
Qed.

Lemma spClosureStep_preserves_prediction :
  forall g sp sp' sps',
    spClosureStep g sp = SpClosureStepK sps'
    -> In sp' sps'
    -> sp.(prediction) = sp'.(prediction).
Proof.
  intros g sp sp' sps' hs hi.
  unfold spClosureStep in hs; dms; tc; inv hs.
  - apply in_singleton_eq in hi; subst; auto.
  - apply in_map_iff in hi.
    destruct hi as [rhs [heq hi]]; subst; auto.
  - inv hi.
Qed.

(* clean this up *)
Lemma spClosure_preserves_prediction :
  forall g pair (a : Acc lex_nat_pair pair) sp a' sp' sps',
    pair = spMeas g sp
    -> spClosure g sp a' = inr sps'
    -> In sp' sps'
    -> sp'.(prediction) = sp.(prediction).
Proof.
  intros g pair a.
  induction a as [pair hlt IH].
  intros sp a' sp' sps' heq hs hi; subst.
  pose proof hs as hs'.
  apply spClosure_success_cases in hs'.
  destruct hs' as [[ hd heq] | [sps'' [hs' [crs [heq heq']]]]]; subst.
  - apply in_singleton_eq in hi; subst; auto.
  - eapply sp_in_aggrClosureResults_result_in_input in heq'; eauto.
    destruct heq' as [sps [hi' hi'']].
    eapply dmap_in in hi'; eauto.
    destruct hi' as [sp'' [hi''' [_ heq]]].
    eapply IH in heq; subst; eauto.
    + apply spClosureStep_preserves_prediction with (sp' := sp'') in hs'; auto.
      rewrite hs'; auto.
    + eapply spClosureStep_meas_lt; eauto.
Qed.

(*
(* CLEAN THIS UP! *)
Lemma sp_closure_preserves_prediction :
  forall g sp Ha sp' es,
    spc g sp Ha = es
    -> In (inr sp') es
    -> sp'.(prediction) = sp.(prediction).
Proof.
  intros g sp.
  remember (stackScore (stack sp) (S (maxRhsLength g)) (NtSet.cardinal (avail sp))) as score.
  generalize dependent sp.
  induction score as [score IHscore] using lt_wf_ind.
  intros sp.
  remember (stackHeight (stack sp)) as height.
  generalize dependent sp.
  induction height as [height IHheight] using lt_wf_ind.
  intros sp Hheight Hscore Ha sp' es Hf Hi.
  destruct Ha as [Ha].
  destruct sp as [av pred stk] eqn:Hsp.
  destruct stk as (loc, locs) eqn:Hstk.
  destruct loc as [x pre suf] eqn:Hloc.
  destruct suf as [| [a | y] suf_tl] eqn:Hsuf.
  - (* return case *)
    destruct locs as [| caller locs_tl] eqn:Hlocs.
    + (* return to final configuration *)
      simpl in Hf; subst.
      apply in_singleton_eq in Hi; inv Hi; auto.
    + (* return to caller frame *)
      destruct caller as [x_cr pre_cr suf_cr] eqn:Hcr.
      destruct suf_cr as [| [a | x'] suf_tl_cr] eqn:Hsufcr.
      * simpl in Hf; subst.
        apply in_singleton_eq in Hi; tc.
      * simpl in Hf; subst.
        apply in_singleton_eq in Hi; tc.
      * (*eapply spc_unfold_return in Hf; eauto.
        destruct Hf as [a' Hf]. *)
        pose proof stackScore_le_after_return as Hss.
        specialize Hss with
            (callee := Loc x pre [])
            (caller := Loc x_cr pre_cr (NT x' :: suf_tl_cr))
            (caller' := Loc x_cr (pre_cr ++ [NT x']) suf_tl_cr)
            (x := x')
            (x' := x')
            (suf' := suf_tl_cr)
            (av := av)
            (locs := locs_tl)
            (b := S (maxRhsLength g)).
        eapply le_lt_or_eq in Hss; auto.
        destruct Hss as [Hlt | Heq].
        -- eapply IHscore with
               (sp := Sp (NtSet.add x' av)
                         pred
                         (Loc x_cr (pre_cr ++ [NT x']) suf_tl_cr,
                          locs_tl)); subst; eauto.
        -- eapply IHheight with
               (sp := Sp (NtSet.add x' av)
                         pred
                         (Loc x_cr (pre_cr ++ [NT x']) suf_tl_cr,
                          locs_tl)); subst; eauto.
           simpl; auto.
  - (* next symbol is a terminal *)
    simpl in Hf; subst.
    apply in_singleton_eq in Hi; inv Hi; auto.
  - (* next symbol is a nonterminal *)
    simpl in Hf.
    destruct (mem_dec y av).
    + subst; apply in_singleton_eq in Hi; inv Hi.
    + eapply in_dflat_map in Hf; eauto.
      destruct Hf as [sp_mid [Hin [Hin' Hf]]].
      eapply in_map_iff in Hin'.
      destruct Hin' as [rhs [Heq Hin']].
      assert (Hlt : stackScore (stack sp_mid) (S (maxRhsLength g)) (NtSet.cardinal (avail sp_mid)) < score).
      { subst.
        eapply stackScore_lt_after_push; simpl; eauto. }
      subst.
      eapply IHscore in Hlt; simpl in *; eauto.
      simpl in *; auto.
      simpl in *; auto.
Defined.
  
*)
Lemma closure_preserves_prediction :
  forall g sp' sps sps',
    closure g sps = inr sps'
    -> In sp' sps'
    -> exists sp, In sp sps /\ sp'.(prediction) = sp.(prediction).
Proof.
  intros g sp' sps sps' hc hi.
  eapply sp_in_aggrClosureResults_result_in_input in hc; eauto.
  destruct hc as [sps'' [hi' hi'']].
  apply in_map_iff in hi'.
  destruct hi' as [sp [hspc hi''']].
  eexists; split; eauto.
  eapply spClosure_preserves_prediction; eauto.
  apply lex_nat_pair_wf.
Qed.

Lemma llPredict'_success_result_in_original_subparsers :
  forall g ts gamma sps,
    llPredict' g ts sps = PredSucc gamma
    -> exists sp, In sp sps /\ (prediction sp) = gamma.
Proof.
  intros g ts gamma.
  induction ts as [| t ts_tl IH]; intros sps Hl; simpl in Hl.
  - eapply handleFinalSubparsers_success_from_subparsers; eauto.
  - destruct sps as [| sp_hd sps_tl] eqn:Hs; tc.
    destruct (allPredictionsEqual sp_hd sps_tl) eqn:Ha.
    + inv Hl.
      eexists; split; eauto.
      apply in_eq.
    + rewrite <- Hs in *; clear Hs. 
      destruct (move g t _) as [msg | sps'] eqn:Hm; tc.
      destruct (closure g sps') as [msg | sps''] eqn:Hc; tc. 
      apply IH in Hl; clear IH.
      destruct Hl as [sp'' [Hin'' Heq]]; subst.
      eapply closure_preserves_prediction in Hc; eauto.
      destruct Hc as [sp' [Hin' Heq]]; rewrite Heq; clear Heq.
      eapply move_preserves_prediction in Hm; eauto.
      destruct Hm as [sp [Hin Heq]]; eauto.
Defined.

Lemma llPredict'_ambig_result_in_original_subparsers :
  forall g ts gamma sps,
    llPredict' g ts sps = PredAmbig gamma
    -> exists sp, In sp sps /\ (prediction sp) = gamma.
Proof.
  intros g ts gamma.
  induction ts as [| t ts_tl IH]; intros sps Hl; simpl in Hl.
  - eapply handleFinalSubparsers_ambig_from_subparsers; eauto.
  - destruct sps as [| sp_hd sps_tl] eqn:Hs; tc.
    destruct (allPredictionsEqual sp_hd sps_tl) eqn:Ha; tc.
    rewrite <- Hs in *; clear Hs. 
    destruct (move g t _) as [msg | sps'] eqn:Hm; tc.
    destruct (closure g sps') as [msg | sps''] eqn:Hc; tc. 
    apply IH in Hl; clear IH.
    destruct Hl as [sp'' [Hin'' Heq]]; subst.
    eapply closure_preserves_prediction in Hc; eauto.
    destruct Hc as [sp' [Hin' Heq]]; rewrite Heq; clear Heq.
    eapply move_preserves_prediction in Hm; eauto.
    destruct Hm as [sp [Hin Heq]]; eauto.
Defined.

Lemma startState_sp_prediction_in_rhssForNt :
  forall g x stk sp' sps',
    startState g x stk = inr sps'
    -> In sp' sps'
    -> In sp'.(prediction) (rhssForNt g x).
Proof.
  intros g x stk sp' sps' Hf Hi.
  unfold startState in Hf.
  destruct stk as (loc, locs).
  eapply closure_preserves_prediction in Hf; eauto.
  destruct Hf as [sp [Hin Heq]]; subst.
  apply in_map_iff in Hin.
  destruct Hin as [gamma [Hin Heq']]; subst.
  rewrite Heq; auto.
Defined.  

Lemma PredSucc_result_in_rhssForNt :
  forall g x stk ts gamma,
    llPredict g x stk ts = PredSucc gamma
    -> In gamma (rhssForNt g x).
Proof.
  intros g x stk ts gamma Hp.
  unfold llPredict in Hp.
  dmeq Hss; tc.
  apply llPredict'_success_result_in_original_subparsers in Hp.
  destruct Hp as [sp [Hin Heq]]; subst.
  eapply startState_sp_prediction_in_rhssForNt; eauto.
Defined.

Lemma PredAmbig_result_in_rhssForNt :
  forall g x stk ts gamma,
    llPredict g x stk ts = PredAmbig gamma
    -> In gamma (rhssForNt g x).
Proof.
  intros g x stk ts gamma Hf.
  unfold llPredict in Hf.
  dmeq Hss; tc.
  apply llPredict'_ambig_result_in_original_subparsers in Hf.
  destruct Hf as [sp [Hin Heq]]; subst.
  eapply startState_sp_prediction_in_rhssForNt; eauto.
Defined.

Lemma llPredict_succ_arg_result_in_grammar :
  forall g x stk ts ys,
    llPredict g x stk ts = PredSucc ys
    -> In (x, ys) g.
Proof.
  intros g x stk ts ys hp.
  apply PredSucc_result_in_rhssForNt in hp.
  apply in_rhssForNt_production_in_grammar; auto.
Qed.

Lemma llPredict_ambig_arg_result_in_grammar :
  forall g x stk ts ys,
    llPredict g x stk ts = PredAmbig ys
    -> In (x, ys) g.
Proof.
  intros g x stk ts ys hp.
  apply in_rhssForNt_production_in_grammar.
  eapply PredAmbig_result_in_rhssForNt; eauto.
Qed.

(* A well-formedness predicate over a location stack *)

(* EVENTUALLY, I SHOULD DEFINE THE PARSER STACK WELL-FORMEDNESS PREDICATE
   IN TERMS OF THIS ONE *)
Inductive locations_wf (g : grammar) : list location -> Prop :=
| WF_nil :
    locations_wf g []
| WF_bottom :
    forall xo pre suf,
      locations_wf g [Loc xo pre suf]
| WF_upper :
    forall x xo pre pre' suf suf' locs,
      In (x, pre' ++ suf') g
      -> locations_wf g (Loc xo pre (NT x :: suf) :: locs)
      -> locations_wf g (Loc (Some x) pre' suf'   ::
                         Loc xo pre (NT x :: suf) :: locs).

Hint Constructors locations_wf.

Definition lstack_wf (g : grammar) (stk : location_stack) : Prop :=
  match stk with
  | (loc, locs) => locations_wf g (loc :: locs)
  end.

Lemma locations_wf_app :
  forall g l,
    locations_wf g l
    -> forall p s,
      l = p ++ s
      -> locations_wf g p /\ locations_wf g s.
Proof.
  intros g l hw.
  induction hw; intros p s heq.
  - symmetry in heq; apply app_eq_nil in heq.
    destruct heq; subst; auto.
  - destruct p as [| fr p]; sis; subst; auto.
    apply cons_inv_eq in heq.
    destruct heq as [hh ht].
    apply app_eq_nil in ht; destruct ht; subst; auto.
  - destruct p as [| fr  p]; sis; subst; auto.
    destruct p as [| fr' p]; sis; subst; inv heq; auto.
    specialize (IHhw (Loc xo pre (NT x :: suf):: p) s).
    destruct IHhw as [hs hp]; auto.
Qed.

Lemma locations_wf_app_l :
  forall g p s,
    locations_wf g (p ++ s)
    -> locations_wf g p.
Proof.
  intros g p s hw.
  eapply locations_wf_app in hw; eauto.
  firstorder.
Qed.

Lemma locations_wf_tl :
  forall g h t,
    locations_wf g (h :: t)
    -> locations_wf g t.
Proof.
  intros g h t hw.
  rewrite cons_app_singleton in hw.
  eapply locations_wf_app in hw; eauto.
  firstorder.
Qed.

(* CLEAN UP *)
Lemma spClosureStep_preserves_lstack_wf_invar :
  forall g sp sp' sps',
    lstack_wf g sp.(stack)
    -> spClosureStep g sp = SpClosureStepK sps'
    -> In sp' sps'
    -> lstack_wf g sp'.(stack).
Proof.
  intros g sp sp' sps' hw hs hi.
  unfold spClosureStep in hs; dms; tc; sis; inv hs.
  - apply in_singleton_eq in hi; subst; simpl.
    inv hw.
    inv H8; constructor; auto.
    rewrite <- app_assoc; auto.
  - apply in_map_iff in hi.
    destruct hi as [rhs [heq hi]]; subst; sis.
    constructor; sis; auto.
    apply in_rhssForNt_production_in_grammar; auto.
  - inv hi.
Qed.

(* an invariant that relates the visited set to the stack *)

Definition processed_symbols_all_nullable (g : grammar) (frs : list location) : Prop :=
  Forall (fun fr => nullable_gamma g fr.(rpre)) frs.

Hint Constructors Forall.

Definition unavailable_nts_are_open_calls_invar g sp : Prop :=
  match sp with
  | Sp av _ (fr, frs) =>
    forall (x : nonterminal),
      NtSet.In x (allNts g)
      -> ~ NtSet.In x av
      -> nullable_gamma g fr.(rpre)
         /\ (exists frs_pre fr_cr frs_suf suf,
                frs = frs_pre ++ fr_cr :: frs_suf
                /\ processed_symbols_all_nullable g frs_pre
                /\ fr_cr.(rsuf) = NT x :: suf)
  end.

Definition sps_unavailable_nts_invar g sps : Prop :=
  forall sp, In sp sps -> unavailable_nts_are_open_calls_invar g sp.

Lemma spClosureStep_preserves_unavailable_nts_invar :
  forall g sp sp' sps',
    lstack_wf g sp.(stack)
    -> unavailable_nts_are_open_calls_invar g sp
    -> spClosureStep g sp = SpClosureStepK sps'
    -> In sp' sps'
    -> unavailable_nts_are_open_calls_invar g sp'.
Proof.
  intros g sp sp' sps' hw hu hs hi.
  unfold spClosureStep in hs.
  destruct sp as [av pred ([xo pre suf], frs)]; sis.
  destruct suf as [| [a | x] suf]; tc.
  - (* return case *)
    destruct frs as [| [xo_cr pre_cr suf_cr] frs]; tc.
    destruct suf_cr as [| [a | x'] suf_cr]; tc.
    inv hs.
    apply in_singleton_eq in hi; subst.
    unfold unavailable_nts_are_open_calls_invar.
    intros x hi hn; simpl.
    assert (hn' : ~ NtSet.In x av) by ND.fsetdec.
    apply hu in hn'; clear hu; auto.
    destruct hn' as [hng [frs_pre [fr_cr [frs_suf [suf [heq [hp heq']]]]]]].
    destruct frs_pre as [| fr' frs_pre]; sis.
    + inv heq; inv heq'.
      ND.fsetdec.
    + inv heq; inv hp; sis; split.
      * apply nullable_app; auto.
        constructor; auto.
        inv hw.
        rewrite app_nil_r in *.
        econstructor; eauto.
      * repeat eexists; eauto.
  - destruct (NtSet.mem x av) eqn:hm.
    + inv hs.
      apply in_map_iff in hi.
      destruct hi as [rhs [heq hi]]; subst.
      unfold unavailable_nts_are_open_calls_invar.
      intros x' hi' hn; simpl; split; auto.
      destruct (NF.eq_dec x' x); subst.
      * exists []; repeat eexists; eauto.
        constructor.
      * assert (hn' : ~ NtSet.In x' av) by ND.fsetdec.
        apply hu in hn'; clear hu; auto.
        destruct hn' as
            [hng [frs_pre [fr_cr [frs_suf [suf' [heq [hp heq']]]]]]]; subst.
        exists (Loc xo pre (NT x :: suf) :: frs_pre); repeat eexists; eauto.
        constructor; auto.
    + dm; tc.
      inv hs; inv hi.
Qed.       
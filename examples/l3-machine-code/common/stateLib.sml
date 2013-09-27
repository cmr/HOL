structure stateLib :> stateLib =
struct

open HolKernel boolLib bossLib
open lcsymtacs updateLib utilsLib
open stateTheory
open progSyntax

infix \\
val op \\ = op THEN;

val ERR = Feedback.mk_HOL_ERR "stateLib"

(* Some syntax functions *)

fun mk_state_pred x =
   pred_setSyntax.mk_set [pred_setSyntax.mk_set [pairSyntax.mk_pair x]]

(* ------------------------------------------------------------------------
   update_frame_state_thm: Generate theorem with conjuncts of the form

   !a w s x.
      f a IN x ==> (FRAME_STATE m x (u s a w) = FRAME_STATE m x (r s))

   where "m" is a projection map and "u" is a state update function.
   ------------------------------------------------------------------------ *)

local
   fun tac t = Cases THEN SRW_TAC [] [t, combinTheory.APPLY_UPDATE_THM]
   fun frame_state_thm def (f, u, r) =
      let
         val n = utilsLib.get_function def
         val thm =
            UPDATE_FRAME_STATE
            |> Drule.ISPEC n
            |> Q.ISPECL [f, u, r]
            |> SIMP_RULE (srw_ss()) []
         val p = fst (boolSyntax.dest_imp (Thm.concl thm))
         val p_thm = Tactical.prove (p, tac def)
      in
         Drule.GEN_ALL (MATCH_MP thm p_thm)
      end
in
   fun update_frame_state_thm proj_def =
      Drule.LIST_CONJ o
      List.map (Feedback.trace ("notify type variable guesses", 0)
                  (frame_state_thm proj_def))
end

(* ------------------------------------------------------------------------
   update_hidden_frame_state_thm: Generate theorem with conjuncts of the form

   !x y s. (FRAME_STATE m x (s with ? := x) = FRAME_STATE m x s)

   where "m" is a projection map.
   ------------------------------------------------------------------------ *)

local
   val tac =
      NTAC 2 STRIP_TAC
      THEN REWRITE_TAC [stateTheory.FRAME_STATE_def, stateTheory.STATE_def,
                        stateTheory.SELECT_STATE_def, set_sepTheory.fun2set_def]
      THEN SRW_TAC [] [pred_setTheory.EXTENSION, pred_setTheory.GSPECIFICATION]
      THEN EQ_TAC
      THEN STRIP_TAC
      THEN Q.EXISTS_TAC `a`
      THEN Cases_on `a`
   fun prove_hidden thm u =
      let
         val p = utilsLib.get_function thm
         val t = tac THEN FULL_SIMP_TAC (srw_ss()) [thm]
      in
         Drule.GEN_ALL
           (Q.prove (`!y s. FRAME_STATE ^p y ^u = FRAME_STATE ^p y s`, t))
      end
in
   fun update_hidden_frame_state_thm proj_def =
      utilsLib.map_conv (prove_hidden proj_def)
end

(* ------------------------------------------------------------------------
   star_select_state_thm: Generate theorems of the form

   !cd m p s x.
      ({cd} * p) (SELECT_STATE m x s) =
      (!c d. (c, d) IN cd ==> (m s c = d)) /\ IMAGE FST cd SUBSET x /\
      p (SELECT_STATE m (x DIFF IMAGE FST cd) s)

   pool_select_state_thm: Generate theorems of the form

   !cd m p s x.
      {cd} (SELECT_STATE m x s) =
      (!c d. (c, d) IN cd ==> (m s c = d)) /\ IMAGE FST cd SUBSET x /\
      (x DIFF IMAGE FST cd = {})

   ------------------------------------------------------------------------ *)

local
   val EXPAND_lem = Q.prove(
      `!x y m s c.
          (!c d. (c, d) IN set (x :: y) ==> (m s c = d)) =
          (!c d. ((c, d) = x) ==> (m s c = d)) /\
          (!c d. ((c, d) IN set y) ==> (m s c = d))`,
      SRW_TAC [] [] \\ utilsLib.qm_tac [])
   val EXPAND_lem2 = Q.prove(
      `!x y m s c.
          (!c d. (c, d) IN x INSERT y ==> (m s c = d)) =
          (!c d. ((c, d) = x) ==> (m s c = d)) /\
          (!c d. ((c, d) IN y) ==> (m s c = d))`,
      SRW_TAC [] [] \\ utilsLib.qm_tac [])
   val emp_thm =
      set_sepTheory.SEP_CLAUSES
      |> Drule.SPEC_ALL
      |> Drule.CONJUNCTS
      |> List.last
in
   fun star_select_state_thm proj_def thms (l, thm) =
      let
         val proj_tm = utilsLib.get_function proj_def
         val tm = thm |> Thm.concl |> boolSyntax.strip_forall |> snd
                      |> boolSyntax.rhs |> pred_setSyntax.strip_set |> List.hd
         val tm_thm = (REWRITE_CONV thms THENC Conv.CHANGED_CONV EVAL) tm
                      handle HOL_ERR {origin_function = "CHANGED_CONV", ...} =>
                         combinTheory.I_THM
      in
         STAR_SELECT_STATE
         |> Drule.ISPECL ([tm, proj_tm] @ l)
         |> Conv.CONV_RULE (Conv.STRIP_QUANT_CONV
               (Conv.FORK_CONV
                   (REWRITE_CONV [GSYM thm, emp_thm],
                    REWRITE_CONV [tm_thm, EXPAND_lem, EXPAND_lem2]
                    THENC SIMP_CONV (srw_ss()) [proj_def, emp_SELECT_STATE])))
         |> Drule.GEN_ALL
      end
   fun pool_select_state_thm proj_def thms instr_def =
      let
         val tm = utilsLib.get_function proj_def
         val ty = utilsLib.rng (Term.type_of tm)
         val ty =
            (pairSyntax.mk_prod (Type.dom_rng ty) --> Type.bool) --> Type.bool
         val emp = Term.mk_const ("emp", ty)
      in
         star_select_state_thm proj_def thms ([emp], instr_def)
      end
end

(* ------------------------------------------------------------------------
   sep_definitions sthy expnd thm

   Generate a state component map for a given next state function, where

   sthy: name of model (used as a prefix tag), e.g. "x86"
   expnd: specifies which record components should be expanded
          (be given separate component names). For example, [["CPSR"]]
   thm: the next state function
   ------------------------------------------------------------------------ *)

local
   fun def_suffix s = s ^ "_def"

   val comp_names =
      List.map (def_suffix o fst o Term.dest_const o utilsLib.get_function)

   fun mk_state_var ty = Term.mk_var ("s", ty)

   fun make_component_name sthy =
      String.concat o Lib.cons (sthy ^ "_c_") o Lib.separate "_" o List.rev

   fun make_assert_name sthy tm =
      sthy ^ String.extract (fst (Term.dest_const tm),
                             String.size sthy + 2, NONE)

   fun component (n, ty) =
      case Lib.total Type.dom_rng ty of
         SOME (d, r) => ((n, [ParseDatatype.dAQ d]), r)
       | NONE => ((n, []), ty)

   fun build_names (sthy, expnd, hide, state_ty) =
      let
         val s = mk_state_var state_ty
         fun loop (x as ((path, ty), tm), es, hs) =
            case Lib.total TypeBase.fields_of ty of
               NONE => [x]
             | SOME [] => [x]
             | SOME l =>
               let
                  val l = ListPair.zip (l, utilsLib.accessor_fns ty)
                  fun process n =
                     List.map List.tl o
                     List.filter (Lib.equal (SOME n) o Lib.total List.hd)
                  val (nd, dn) =
                     List.foldl
                        (fn ((x as ((n, t), f)), (nd, dn)) =>
                           let
                              val hs' = process n hs
                              val es' = process n es
                              val ahide = Lib.mem [] hs'
                              val y = ((n :: path, t), Term.mk_comb (f, tm))
                           in
                              if List.null es'
                                 then (nd, if ahide then dn else y :: dn)
                              else ((y, es', hs') :: nd, dn)
                           end) ([], []) l
               in
                  dn @ List.concat (List.map loop nd)
               end
         val (l1, tms) =
            ListPair.unzip (loop ((([], state_ty), s), expnd, hide))
         val (components, data) =
            ListPair.unzip
              (List.map (component o (make_component_name sthy ## Lib.I)) l1)
      in
         (components, Lib.mk_set data, tms)
      end

   fun data_constructor ty =
      case Type.dest_thy_type ty of
         {Thy = "fcp", Args = [_, n], Tyop = "cart"} =>
            "word" ^ Arbnum.toString (fcpSyntax.dest_numeric_type n)
       | {Thy = "min", Args = [a, b], Tyop = "fun"} =>
            data_constructor a ^ "_to_" ^ data_constructor b
       | {Thy = "pair", Args = [a, b], Tyop = "prod"} =>
            data_constructor a ^ "_X_" ^ data_constructor b
       | {Thy = "option", Args = [a], Tyop = "option"} =>
            data_constructor a ^ "_option"
       | {Thy = "list", Args = [a], Tyop = "list"} =>
            data_constructor a ^ "_list"
       | {Args = [], Tyop = s, ...} => s
       | _ => raise ERR "data_constructor" "incompatible type"

   fun define_assert0 sthy pred_ty (tm1, tm2) =
      let
         val dty = utilsLib.dom (Term.type_of tm2)
         val d = Term.mk_var ("d", dty)
         val tm_d = Term.mk_comb (tm2, d)
         val s = make_assert_name sthy tm1
         val l = Term.mk_comb (Term.mk_var (s, dty --> pred_ty), d)
         val r = mk_state_pred (tm1, tm_d)
      in
         Definition.new_definition (def_suffix s, boolSyntax.mk_eq (l, r))
      end

   fun define_assert1 sthy pred_ty (tm1, tm2) =
      let
         val (tm1, v, vty) =
            case Term.free_vars tm1 of
               [v] => let
                         val vty = Term.type_of v
                         val fv = Term.mk_var ("c", vty)
                      in
                         (Term.subst [v |-> fv] tm1, fv, vty)
                      end
             | _ => raise ERR "define_assert1" "expecting single free var"
         val dty = utilsLib.dom (Term.type_of tm2)
         val d = Term.mk_var ("d", dty)
         val tm_d = Term.mk_comb (tm2, d)
         val s = make_assert_name sthy (fst (boolSyntax.strip_comb tm1))
         val l =
            Term.list_mk_comb (Term.mk_var (s, vty --> dty --> pred_ty), [v, d])
         val r = mk_state_pred (tm1, tm_d)
      in
         Definition.new_definition (def_suffix s, boolSyntax.mk_eq (l, r))
      end
in
   fun sep_definitions sthy expnd hide thm =
      let
         val next_tm = utilsLib.get_function thm
         val state_ty = utilsLib.dom (Term.type_of next_tm)
         val (components, data, tms) = build_names (sthy, expnd, hide, state_ty)
         fun dc ty = sthy ^ "_d_" ^ data_constructor ty
         val data_cons = List.map (fn d => (dc d, [ParseDatatype.dAQ d])) data
         val s_c = sthy ^ "_component"
         val s_d = sthy ^ "_data"
         val () = Datatype.astHol_datatype
                    [(s_c, ParseDatatype.Constructors components)]
         val () = Datatype.astHol_datatype
                    [(s_d, ParseDatatype.Constructors data_cons)]
         val cty = Type.mk_type (s_c, [])
         val dty = Type.mk_type (s_d, [])
         val pred_ty =
            pred_setSyntax.mk_set_type
               (pred_setSyntax.mk_set_type (pairSyntax.mk_prod (cty, dty)))
         fun mk_dc ty = Term.mk_const (dc ty, ty --> dty)
         val n = ref 0
         val a0 = define_assert0 sthy pred_ty
         val a1 = define_assert1 sthy pred_ty
         val define_component =
            fn ((s, []), tm) =>
                let
                   val tm1 = Term.mk_const (s, cty)
                   val tm2 = mk_dc (type_of tm)
                in
                   ((tm1, Term.mk_comb (tm2, tm)), a0 (tm1, tm2))
                end
             | ((s, [a]), tm) =>
                let
                   val aty = ParseDatatype.pretypeToType a
                   val v = Term.mk_var ("v" ^ Int.toString (!n), aty)
                   val tm_v = Term.mk_comb (tm, v)
                   val bty = utilsLib.rng (Term.type_of tm)
                   val () = Portable.inc n
                   val tm1 = Term.mk_comb (Term.mk_const (s, aty --> cty), v)
                   val tm2 = mk_dc (Term.type_of tm_v)
                in
                   ((tm1, Term.mk_comb (tm2, tm_v)), a1 (tm1, tm2))
                end
             | _ => raise ERR "define_component" "too many arguments"
         val l = List.map define_component (ListPair.zip (components, tms))
         val (cs, defs) = ListPair.unzip l
         val proj_r = TypeBase.mk_pattern_fn cs
         val proj_s = sthy ^ "_proj"
         val proj_f = Term.mk_var (proj_s, state_ty --> cty --> dty)
         val proj_l = Term.mk_comb (proj_f, mk_state_var state_ty)
         val proj_def =
            Definition.new_definition
               (sthy ^ "_proj_def", boolSyntax.mk_eq (proj_l, proj_r))
         val () =
            Theory.adjoin_to_theory
               {sig_ps =
                  SOME (fn ppstrm =>
                           PP.add_string ppstrm "val component_defs: thm list"),
                struct_ps =
                  SOME (fn ppstrm =>
                          (PP.add_string ppstrm "val component_defs = ["
                           ; PP.begin_block ppstrm PP.INCONSISTENT 0
                           ; Portable.pr_list
                                 (PP.add_string ppstrm)
                                 (fn () => PP.add_string ppstrm ",")
                                 (fn () => PP.add_break ppstrm (1, 0))
                                 (comp_names defs)
                           ; PP.add_string ppstrm "]"
                           ; PP.end_block ppstrm
                           ; PP.add_newline ppstrm))}
      in
         proj_def :: defs
      end
end

(*

open arm_stepTheory

val sthy = "arm"
val expnd = [["CPSR"], ["FP", "FPSCR"]]
val hide = [["undefined"], ["CurrentCondition"]]
val thm = arm_stepTheory.NextStateARM_def

val (x as ((path, ty), tm), es) = ((([], state_ty), s), expnd)
val SOME l = Lib.total TypeBase.fields_of ty
val (x as ((n, t), f)) = hd l

val hs = [["Architecture"]]

*)

(* ------------------------------------------------------------------------
   define_map_component (name, f, p, def)

   Given a definition of the form

    |- !c d. model_X c d = {{(model_c_X, model_d_Y)}}

   this function generates a map version, as defined by

    !df f. name df f = {BIGUNION {BIGUNION (model_X c (f c)) | c IN df /\ p c}}

   and it also proves the theorem

    |- c IN df /\ p c ==>
       (model_X c d * name (df DELETE c) f = name df ((c =+ d) f))

   When argument "p" is NONE the term "p c" does not occur.
   ------------------------------------------------------------------------ *)

local
   val MAPPED_COMPONENT_INSERT_K_T =
      stateTheory.MAPPED_COMPONENT_INSERT
      |> Q.SPEC `K T`
      |> REWRITE_RULE [combinTheory.K_THM]
in
   fun define_map_component (s, f, p, def) =
      let
         val (c, d, e) =
            case boolSyntax.strip_forall (Thm.concl def) of
               ([c, d], e) => (c, d, boolSyntax.dest_eq e)
             | _ => raise ERR "" "bad definition"
         val component =
            e |> snd
              |> pred_setSyntax.strip_set |> hd
              |> pred_setSyntax.strip_set |> hd
              |> pairSyntax.dest_pair |> fst
              |> Term.rator
         val c_ty = Term.type_of c
         val d_ty = Term.type_of d
         val c_set_ty = pred_setSyntax.mk_set_type c_ty
         val comp_11 =
            let
               val a = Term.mk_var ("a", c_ty)
               val b = Term.mk_var ("b", c_ty)
            in
               simpLib.SIMP_PROVE (srw_ss()) []
                 (boolSyntax.list_mk_forall
                    ([a, b],
                     boolSyntax.mk_eq
                       (boolSyntax.mk_eq
                          (Term.mk_comb (component, a),
                           Term.mk_comb (component, b)),
                        boolSyntax.mk_eq (a, b))))
            end
         val df = Term.mk_var ("d" ^ f, c_set_ty)
         val f = Term.mk_var (f, c_ty --> d_ty)
         val e = fst e
         val sep_ty = Term.type_of e
         val c_in_df = pred_setSyntax.mk_in (c, df)
         val (c_tm, insert_thm) =
            case p of
               SOME tm => (boolSyntax.mk_conj (c_in_df, Term.mk_comb (tm, c)),
                           stateTheory.MAPPED_COMPONENT_INSERT)
             | NONE => (c_in_df, MAPPED_COMPONENT_INSERT_K_T)
         val t = e |> Term.subst [d |-> Term.mk_comb (f, c)]
                   |> pred_setSyntax.mk_bigunion
         val t = pred_setSyntax.mk_set
                   [pred_setSyntax.mk_bigunion
                      (boolSyntax.mk_icomb
                        (pred_setSyntax.gspec_tm,
                         Term.mk_abs (c, pairSyntax.mk_pair (t, c_tm))))]
         val v_ty = c_set_ty --> (c_ty --> d_ty) --> sep_ty
         val v = Term.mk_var (s, v_ty)
         val mdef =
           Definition.new_definition
              (s, boolSyntax.mk_eq (Term.list_mk_comb (v, [df, f]), t))
         val thm =
            Theory.save_thm
               (s ^ "_INSERT",
                MATCH_MP insert_thm (Drule.LIST_CONJ [comp_11, def, mdef])
                |> Conv.BETA_RULE
                |> Drule.SPECL [f, df])
      in
         (mdef, thm)
      end
      handle HOL_ERR {message, ...} => raise ERR "define_map_component" message
end

(* ------------------------------------------------------------------------
   mk_code_pool: make term ``CODE_POOL f {(v, opc)}``
   ------------------------------------------------------------------------ *)

local
   val code_pool_tm = Term.prim_mk_const {Thy = "prog", Name = "CODE_POOL"}
in
   fun mk_code_pool (f, v, opc) =
      let
         val x = pred_setSyntax.mk_set [pairSyntax.mk_pair (v, opc)]
      in
         boolSyntax.list_mk_icomb (code_pool_tm, [f, x])
      end
      handle HOL_ERR {message, ...} => raise ERR "mk_code_pool" message
end

(* ------------------------------------------------------------------------
   list_mk_code_pool: make term ``CODE_POOL f {(v, [opc0, ...])}``
   ------------------------------------------------------------------------ *)

fun list_mk_code_pool (f, v, l) =
   mk_code_pool (f, v, listSyntax.mk_list (l, Term.type_of (hd l)))

(* ------------------------------------------------------------------------
   is_code_access:
   test if term is of the form ``s.mem v`` or ``s.mems (v + x)``
   ------------------------------------------------------------------------ *)

fun is_code_access (s, v) tm =
   case boolSyntax.dest_strip_comb tm of
      (c, [_, a]) =>
         c = s andalso
         (a = v orelse
            (case Lib.total wordsSyntax.dest_word_add a of
                SOME (x, y) => x = v andalso wordsSyntax.is_word_literal y
              | NONE => false))
    | _ => false

(* ------------------------------------------------------------------------
   dest_code_access:
   ``s.mem a = r``       -> (0, ``r``)
   ``s.mem (a + i) = r`` -> (i, ``r``)
   ------------------------------------------------------------------------ *)

fun dest_code_access tm =
   let
      val (l, r) = boolSyntax.dest_eq tm
      val a = boolSyntax.rand l
      val a = case Lib.total (snd o wordsSyntax.dest_word_add) a of
                 SOME x => wordsSyntax.uint_of_word x
               | NONE => 0
   in
      (a, case Lib.total optionSyntax.dest_some r of SOME v => v | NONE => r)
   end

(* ------------------------------------------------------------------------
   read_footprint proj_def comp_defs cpool extras

   Generate a map from step-theorem to

      (component pre-conditions,
       code-pool,
       Boolean pre-condition,
       processed next-state term)

   ------------------------------------------------------------------------ *)

local
   val vnum =
      ref (Redblackmap.mkDict String.compare : (string, int) Redblackmap.dict)
in
   fun gvar s ty =
      let
         val i = case Redblackmap.peek (!vnum, s) of
                    SOME i => (vnum := Redblackmap.insert (!vnum, s, i + 1)
                               ; Int.toString i)
                  | NONE => (vnum := Redblackmap.insert (!vnum, s, 0); "")
      in
         Term.mk_var (s ^ i, ty)
      end
   val vvar = gvar "%v"
   fun varReset () = vnum := Redblackmap.mkDict String.compare
   fun is_gen s = String.sub (s, 0) = #"%"
   fun is_vvar tm =
      case Lib.total Term.dest_var tm of
         SOME (s, _) => is_gen s
       | NONE => false
   fun is_nvvar tm =
      case Lib.total Term.dest_var tm of
         SOME (s, _) => not (is_gen s)
       | NONE => false
   fun build_assert (f: term * term -> term) g =
      fn ((d, (c, pat)), (a, tm)) =>
         let
            val v = vvar (utilsLib.dom (Term.type_of d))
         in
            (f (c, Term.mk_comb (d, v)) :: a, Term.subst [pat |-> g v] tm)
         end
end

type footprint_extra = (term * term) * (term -> term) * (term -> term)

local
   fun entry (c, d) = let val (d, pat) = Term.dest_comb d in (d, (c, pat)) end

   fun component_assoc_list proj_def =
      proj_def |> Thm.concl
               |> boolSyntax.strip_forall |> snd
               |> boolSyntax.rhs
               |> Term.dest_abs |> snd
               |> TypeBase.strip_case |> snd
               |> List.map entry
               |> List.partition (fn (_, (t, _)) => Term.is_comb t)

   fun prim_pat_match (c, pat) tm =
      HolKernel.bvk_find_term (K true)
        (fn t =>
            let val m = fst (Term.match_term pat t) in (Term.subst m c, t) end)
        tm

   fun pat_match s_tm (c, pat) tm =
      HolKernel.bvk_find_term (Term.is_comb o snd)
        (fn t =>
            let
               val m = fst (Term.match_term pat t)
               val _ = List.length (HolKernel.find_terms (Lib.equal s_tm) t) < 2
                       orelse raise ERR "" ""
            in
               (Term.subst m c, t)
            end) tm

   fun read_extra x =
      fn [] => x
       | l as ((cpat, f, g) :: r) =>
           (case prim_pat_match cpat (snd x) of
               SOME (d, pat) =>
                  read_extra
                     (build_assert (f o snd) g ((d, (boolSyntax.T, pat)), x)) l
             | NONE => read_extra x r)

   fun map_rws rws =
      List.concat o
        (List.map (boolSyntax.strip_conj o utilsLib.rhsc o
                   Conv.QCONV (REWRITE_CONV rws)))

   val tidyup = map_rws [optionTheory.SOME_11]

   fun is_ok_rhs tm =
      is_nvvar tm orelse
      (case Lib.total optionSyntax.dest_some tm of
          SOME v => is_nvvar v
        | NONE => List.null (Term.free_vars tm))

   fun mk_rewrite1 (l, r) =
      Lib.assert
         (fn {redex, residue} =>
             Term.is_var redex andalso is_ok_rhs residue andalso
             Term.type_of redex = Term.type_of residue) (l |-> r)

   fun mk_rewrite tm =
      case Lib.total boolSyntax.dest_eq tm of
         SOME x => mk_rewrite1 x
       | NONE => (case Lib.total boolSyntax.dest_neg tm of
                     SOME v => mk_rewrite1 (v, boolSyntax.F)
                   | NONE => mk_rewrite1 (tm, boolSyntax.T))

   val is_rewrite = Lib.can mk_rewrite

   fun make_subst tms =
      tms |> List.map mk_rewrite
          |> List.partition (Term.is_var o #residue)
          |> (fn (l1, l2) => Term.subst (l2 @ l1))

   fun not_some_none tm =
      case Lib.total optionSyntax.dest_is_some tm of
         SOME t => not (optionSyntax.is_some t)
       | NONE => true

in
   fun read_footprint proj_def comp_defs cpool (extras: footprint_extra list) =
      let
         val (l1, l2) = component_assoc_list proj_def
         val sty = utilsLib.dom (Term.type_of (utilsLib.get_function proj_def))
         val b_assert =
            build_assert
              (utilsLib.rhsc o REWRITE_CONV (List.map GSYM comp_defs) o
               mk_state_pred) Lib.I
         val mtch = pat_match (Term.mk_var ("s", sty))
      in
         fn thm: thm =>
            let
               val () = varReset ()
               val (b, c: term, tm) = cpool thm
               val x =
                  List.foldl
                     (fn e as ((_, cpat), x) =>
                         if Option.isSome (prim_pat_match cpat (snd x))
                            then b_assert e
                         else x) ([], tm) l2
               fun loop modified x =
                  fn [] => if modified then loop false x l1 else x
                   | l as ((d, cpat) :: r) =>
                       (case mtch cpat (snd x) of
                           NONE => loop modified x r
                         | SOME m => loop true (b_assert ((d, m), x)) l)
               val (a, tm) = read_extra (loop false x l1) extras
               val a = b :: a
               val (p, tm) = boolSyntax.strip_imp tm
               val (eqs, rest) = List.partition is_rewrite (tidyup p)
               val rest = List.filter not_some_none rest
               val sbst = make_subst eqs
               val a = List.map sbst a
               val p = if List.null rest
                          then boolSyntax.T
                       else sbst (boolSyntax.list_mk_conj rest)
            in
               (a, c, p, sbst (optionSyntax.dest_some (boolSyntax.rhs tm)))
            end
      end
end

(* ------------------------------------------------------------------------
   write_footprint syntax1 syntax2 l1 l2 l3 l4 P (p, q, tm)

   Extend p (pre) and q (post) proposition lists with entries for
   component updates.

   l1 is a list of updates for map components
   l2 is a list of updates for regular components
   l3 is a list of updates for regular components (known to be read)
   l4 is a list of user defined updates for sub components

   P is a predicate this is used to test whether all updates have been
   considered
   ------------------------------------------------------------------------ *)

local
   fun strip_assign (a, b) =
      let
         val (x, y) = combinSyntax.strip_update (combinSyntax.dest_K_1 a)
      in
         if b <> y
            then (Parse.print_term b
                  ; print "\n\n"
                  ; Parse.print_term y
                  ; raise ERR "write_footprint" "strip_assign")
         else ()
         ; x
      end
   fun not_in_asserts p (dst: term -> term) =
      List.filter
         (fn x =>
            let
               val d = dst x
            in
               not (Lib.exists (fn y => case Lib.total dst y of
                                           SOME c => c = d
                                         | NONE => false) p)
            end)
   fun prefix tm = case boolSyntax.strip_comb tm of
                      (a, [_]) => a
                    | (a, [b, _]) => Term.mk_comb (a, b)
                    | _ => raise ERR "prefix" ""
   fun fillIn f ty =
      fn []: term list => []
       | _ => [f (vvar ty)]: term list
   datatype footprint =
       MapComponent of
          term * (term * term -> term) * (term -> term) * (term -> term)
     | Component of term list * term list * term -> term list * term list
   fun mk_map_footprint syntax2 (c:string, t) =
      let
         val (tm, mk, dst:term -> term * term, _:term -> bool) = syntax2 c
         val ty = utilsLib.dom (utilsLib.rng (Term.type_of tm))
         val c = fst o dst
         fun d tm = mk (c tm, vvar ty)
      in
         MapComponent (t, mk, c, d)
      end
   fun mk_footprint1 syntax1 (c:string) =
      let
         val (tm, mk, _:term -> term, _:term -> bool) = syntax1 c
         val ty = utilsLib.dom (Term.type_of tm)
      in
         Component
            (fn (p, q, v) =>
               let
                   val x = mk v
                   val l = fillIn mk ty (not_in_asserts p Term.rator [x])
               in
                  (l @ p, x :: q)
               end)
      end
   fun mk_footprint1b syntax1 (c:string) =
      let
         val (_, mk, _, _) = syntax1 c
      in
         Component (fn (p, q, v) => (p, mk v :: q))
      end
in
   fun sort_finish psort (p, q) =
      let
         val q = psort (q @ not_in_asserts q prefix p)
      in
         (psort p, q)
      end
   fun write_footprint syntax1 syntax2 l1 l2 l3 l4 P =
      let
         val mk_map_f = mk_map_footprint syntax2
         val l1 = List.map (fn (s, c, tm) => (s, mk_map_f (c, tm))) l1
         val l2 = List.map (I ## mk_footprint1 syntax1) l2
         val l3 = List.map (I ## mk_footprint1b syntax1) l3
         val l4 = List.map (I ## Component) l4
         val m = Redblackmap.fromList String.compare (l1 @ l2 @ l3 @ l4)
         fun default (s, l, p, q) =
            if P (s, l) then (p, q) else raise ERR "write_footprint" s
         fun loop (p, q, tm) =
            (case boolSyntax.dest_strip_comb tm of
                (f_upd, l as [v, rst]) =>
                  (case Redblackmap.peek (m, f_upd) of
                      SOME (Component f) =>
                         let
                            val (p', q') = f (p, q, combinSyntax.dest_K_1 v)
                         in
                            loop (p', q', rst)
                         end
                    | SOME (MapComponent (t, mk, c, d)) =>
                         let
                            val l = List.map mk (strip_assign (v, t))
                            val l2 = List.map d (not_in_asserts p c l)
                         in
                            loop (l2 @ p, l @ q, rst)
                         end
                    | NONE => default (f_upd, l, p, q))
              | (s, l) => default (s, l, p, q) : (term list * term list))
            handle HOL_ERR {message = "not a const", ...} => (p, q)
      in
         loop
      end
end

(* ------------------------------------------------------------------------
   mk_pre_post

   Generate pre-codition, code-pool and post-condition for step-theorem
   ------------------------------------------------------------------------ *)

local
   fun mk_part_spec m = boolSyntax.mk_icomb (progSyntax.spec_tm, m)
   fun get_def tm =
      let
         val {Name, Thy, ...} = Term.dest_thy_const (Term.rand tm)
      in
         DB.fetch Thy (Name ^ "_def")
      end
   (*
   fun snoc_cond c =
      fn [] => c
       | p as h :: _ =>
           let
              val c_tm = progSyntax.mk_cond c
              val sbst = Type.match_type (Term.type_of c_tm) (Term.type_of h)
              val c_tm = Term.inst sbst c_tm
           in
              progSyntax.list_mk_star (p @ [c_tm])
           end
   *)
in
   fun mk_pre_post model_def comp_defs cpool extras write_fn psort =
      let
         val (model_tm, tm) = boolSyntax.dest_eq (Thm.concl model_def)
         val proj_def = case pairSyntax.strip_pair tm of
                           [a, _, _, _] => get_def a
                         | _ => raise ERR "mk_pre_post" "bad model definition"
         val read = read_footprint proj_def comp_defs cpool extras
         val mk_spec = HolKernel.list_mk_icomb (mk_part_spec model_tm)
         val write = (progSyntax.list_mk_star ## progSyntax.list_mk_star) o
                     sort_finish psort o write_fn
      in
         fn thm: thm =>
            let
               val (p, pool, c, tm) = read thm
               val (p, q) = write (p, []: term list, tm)
               val p = if c = boolSyntax.T
                          then p
                       else (* snoc_cond (c, progSyntax.strip_star p) *)
                            progSyntax.mk_star (progSyntax.mk_cond c, p)
            in
               mk_spec [p, pool, q]
            end
      end
end

(* ------------------------------------------------------------------------
   rename_vars (rename1, rename2, bump)

   Rename generated variables "%v" is a SPEC theorem.
   ------------------------------------------------------------------------ *)

fun rename_vars (rename1, rename2, bump) =
   let
      fun rename f tm =
         case boolSyntax.dest_strip_comb tm of
            (c, [v]) =>
               (case Lib.total (fst o Term.dest_var) v of
                  SOME q =>
                     if is_gen q
                        then case rename1 c of
                                SOME s => SOME (v |-> f (s, Term.type_of v))
                              | NONE => NONE
                     else NONE
                 | NONE => NONE)
          | (c, [x, v]) =>
               (case Lib.total (fst o Term.dest_var) v of
                   SOME q =>
                     if is_gen q
                        then case rename2 c of
                                SOME g =>
                                   (case Lib.total g x of
                                       SOME s =>
                                         SOME (v |-> f (s, Term.type_of v))
                                     | NONE => NONE)
                              | NONE => NONE
                     else NONE
                 | NONE => NONE)
          | _ => NONE
   in
      fn thm =>
         let
            val p = progSyntax.dest_pre (Thm.concl thm)
            val () = varReset()
            val () =
               List.app (fn s => General.ignore (gvar s Type.alpha))
                 bump
            val avoid =
               utilsLib.avoid_name_clashes p o Lib.uncurry gvar
            val p = progSyntax.strip_star p
         in
            Thm.INST (List.mapPartial (rename avoid) p) thm
         end
         handle e as HOL_ERR _ => Raise e
   end

(* ------------------------------------------------------------------------
   introduce_triple_definition (duplicate, thm_def) thm

   Given a thm_def of the form

    |- !x. f x = p1 * ... * pn * cond c1 * ... cond cm

   (where the conds need not be at the end) and a theorem "thm" of the form

    |- SPEC (cond r * p) c q

   the function introduce_triple_definition gives a theorem of form

    |- SPEC (cond r' * p' * f x1) c (q' * f x2)

   The condition "r'" is related to "r" but will no longer incorporate
   conditions found in "c1" to "cm". Similarly "p'" and "q'" will no
   longer contain components "p1" to "pn".

   The "duplicate" flag controls whether or not conditions in "r" are
   added to the postcondition in order to introduce "f".
   ------------------------------------------------------------------------ *)

local
   val get_conds = List.filter progSyntax.is_cond o progSyntax.strip_star
   val err = ERR "introduce_triple"
   fun move_match (pat, t) =
      helperLib.MOVE_COND_RULE
        (case Lib.mk_set (find_terms (Lib.can (Term.match_term pat)) t) of
            [] => raise (err "missing condition")
          | [m] => m
          | l => Lib.with_exn (Lib.first (Lib.equal pat)) l
                   (err "ambiguous condition"))
in
   fun introduce_triple_definition (duplicate, thm_def) =
      let
         val ts = thm_def
                  |> Thm.concl
                  |> boolSyntax.strip_forall |> snd
                  |> boolSyntax.dest_eq |> snd
                  |> progSyntax.strip_star
         val (cs, ps) = List.partition progSyntax.is_cond ts
         val cs = List.map progSyntax.dest_cond cs
         val rule =
            helperLib.PRE_POST_RULE (helperLib.STAR_REWRITE_CONV (GSYM thm_def))
         val d_rule = if duplicate
                         then MATCH_MP progTheory.SPEC_DUPLICATE_COND
                      else Lib.I
      in
         fn thm =>
            let
               val p = progSyntax.dest_pre (Thm.concl thm)
               val move_cs =
                  List.map
                     (fn t => List.map (fn c => d_rule o move_match (c, t)) cs)
                     (get_conds p)
            in
               thm |> helperLib.SPECL_FRAME_RULE ps
                   |> Lib.C (List.foldl (fn (f, t) => f t))
                            (List.concat move_cs)
                   |> rule
            end
      end
end

(* ------------------------------------------------------------------------
   introduce_map_definition (insert_thm, dom_eq_conv) thm

   Given an insert_thm of the form

     |- c IN df ==> (model_X c d * name (df DELETE c) f = name df ((c =+ d) f))

   (which may be generated by define_map_component) and a theorem "thm" of the
   form

     |- SPEC (cond r * p) c q

   where "p" and "q" contain instances of "model_X c d", a theorem new is
   generated of the form

     |- SPEC (p' * name df f * cond (r /\ z)) x (q' * name df f')

   where "p'" and "q'" are modified versions of "p" and "q" that no longer
   contain any instances of "model_X c d".

   The predicate "z" will specify which values are contained in "df",
   which represents the domain of the newly intoruced map "f".

   The conversion "dom_eq_conv" can be used to simplify "z" by deciding
   equality over elements of the domain of "f".
   ------------------------------------------------------------------------ *)

local
   fun strip2 f = case boolSyntax.strip_comb f of
                     (f, [a, b]) => (f, (a, b))
                   | _ => raise ERR "strip2" ""
   val tidy_up_rule =
      SIMP_RULE (bool_ss++helperLib.sep_cond_ss) [] o
      PURE_REWRITE_RULE [GSYM progTheory.SPEC_MOVE_COND] o
      Drule.DISCH_ALL o
      PURE_REWRITE_RULE [updateTheory.APPLY_UPDATE_ID]
in
   fun introduce_map_definition (insert_thm, dom_eq_conv) =
      let
         val insert_thm = Drule.SPEC_ALL insert_thm
         val ((f_tm, (c, d)), (m_tm, (df, f))) =
            insert_thm
            |> Thm.concl
            |> boolSyntax.dest_imp |> snd
            |> boolSyntax.dest_eq |> fst
            |> progSyntax.dest_star
            |> (strip2 ## strip2)
         val is_f = Lib.equal f_tm o fst o boolSyntax.strip_comb
         val get_f =
            List.filter is_f o progSyntax.strip_star o progSyntax.dest_pre o
            Thm.concl
         val c_ty = Term.type_of c
         val d_ty = Term.type_of d
         val c_set_ty = pred_setSyntax.mk_set_type c_ty
         val df = fst (pred_setSyntax.dest_delete df)
         val df_intro = List.foldl (pred_setSyntax.mk_delete o Lib.swap) df
         fun mk_frame cs = Term.mk_comb (Term.mk_comb (m_tm, df_intro cs), f)
         val insert_conv =
            utilsLib.INST_REWRITE_CONV [Drule.UNDISCH_ALL insert_thm]
      in
         fn th =>
            let
               val xs = get_f th
            in
               if List.null xs
                  then th
               else let
                       val xs =
                          List.map
                             (fn t =>
                                let
                                   val (g, d) = Term.dest_comb t
                                   val c = Term.rand g
                                in
                                   (Term.mk_comb (g, Term.genvar d_ty),
                                    (Term.rand g, d |-> Term.mk_comb (f, c)))
                                end) xs
                       val (xs, cs_ds) = ListPair.unzip xs
                       val (cs, ds) = ListPair.unzip cs_ds
                       val frame = mk_frame cs
                       val rwt =
                          List.foldr progSyntax.mk_star frame xs
                          |> insert_conv
                          |> utilsLib.ALL_HYP_CONV_RULE
                                (PURE_REWRITE_CONV [pred_setTheory.IN_DELETE]
                                 THENC dom_eq_conv)
                    in
                       th |> helperLib.SPECC_FRAME_RULE frame
                          |> helperLib.PRE_POST_RULE
                               (helperLib.STAR_REWRITE_CONV rwt)
                          |> Thm.INST ds
                          |> tidy_up_rule
                    end
            end
      end
      handle HOL_ERR _ => raise ERR "introduce_map_definition" ""
end

(* ------------------------------------------------------------------------
   get_pc_inc is_pc
   ------------------------------------------------------------------------ *)

fun get_pc_inc is_pc =
   let
      val get_pc = Term.rand o Lib.first is_pc o progSyntax.strip_star
   in
      fn th =>
         let
            val (p, q) = progSyntax.dest_pre_post (Thm.concl th)
            val pc_var = get_pc p
            val pc = get_pc q
         in
            case Lib.total wordsSyntax.dest_word_add pc of
               SOME (x, n) =>
                  if x = pc_var
                     then Lib.total wordsSyntax.uint_of_word n
                  else NONE
             | NONE =>
                 (case Lib.total wordsSyntax.dest_word_sub pc of
                     SOME (x, n) =>
                        if x = pc_var
                           then Lib.total (Int.~ o wordsSyntax.uint_of_word) n
                        else NONE
                   | NONE => if pc = pc_var then SOME 0 else NONE)
         end
   end

(* ------------------------------------------------------------------------
   spec

   Generate a tool for proving theorems of the form

     |- SPEC p c q

   The goal is expected to be generated by mk_pre_post based on a
   step-theorem, which is in turn used to prove the goal.
   ------------------------------------------------------------------------ *)

(*
open lcsymtacs
val () = set_trace "Goalstack.print_goal_at_top" 0
val () = set_trace "Goalstack.print_goal_at_top" 1
*)

local
   val spec_debug = ref false
   val () = Feedback.register_btrace ("stateLib.spec", spec_debug)
   val PRINT_TAC =
      RULE_ASSUM_TAC (CONV_RULE PRINT_CONV) THEN CONV_TAC PRINT_CONV
   val WEAK_STRIP_TAC = DISCH_THEN (REPEAT_TCL CONJUNCTS_THEN ASSUME_TAC)
   val AND_IMP_INTRO_RULE =
      Conv.CONV_RULE (Conv.DEPTH_CONV Conv.AND_IMP_INTRO_CONV)
   fun is_ineq tys =
      fn thm =>
         (thm |> Thm.concl
              |> boolSyntax.dest_neg
              |> boolSyntax.dest_eq |> fst
              |> Term.type_of
              |> Lib.C Lib.mem tys)
         handle HOL_ERR _ => false
   val ADDRESS_EQ_CONV =
      PURE_REWRITE_CONV [wordsTheory.WORD_EQ_ADD_LCANCEL,
                         wordsTheory.WORD_ADD_INV_0_EQ]
      THENC (Conv.TRY_CONV wordsLib.word_EQ_CONV)
   fun UPDATE_TAC tys =
      fn thms =>
         CONV_TAC
            (Conv.DEPTH_CONV
                (updateLib.UPDATE_APPLY_CONV
                    (PURE_REWRITE_CONV (List.filter (is_ineq tys) thms)
                     THENC ADDRESS_EQ_CONV)))
   val cond_STAR1 = CONJUNCT1 (Drule.SPEC_ALL set_sepTheory.cond_STAR)
   val STAR_ASSOC_CONV =
      Conv.REDEPTH_CONV (Conv.REWR_CONV (GSYM set_sepTheory.STAR_ASSOC))
   val cond_STAR1_I =
      utilsLib.qm [cond_STAR1, combinTheory.I_THM]
         ``(cond c * p) (s:'a set) = I c /\ p s``
in
   fun spec imp_spec read_thms write_thms select_state_thms frame_thms
            component_11 map_tys EXTRA_TAC STATE_TAC =
      let
         open lcsymtacs
         val MP_SPEC_TAC = MATCH_MP_TAC imp_spec
         val sthms = cond_STAR1_I :: select_state_thms
         val pthms = [boolTheory.DE_MORGAN_THM, pred_setTheory.NOT_IN_EMPTY,
                      pred_setTheory.IN_DIFF, pred_setTheory.IN_INSERT]
         val UPD_TAC = UPDATE_TAC map_tys
         val PRE_TAC =
            MP_SPEC_TAC
            \\ GEN_TAC
            \\ GEN_TAC
            \\ CONV_TAC
                  (Conv.LAND_CONV
                     (Conv.RATOR_CONV STAR_ASSOC_CONV
                      THENC REWRITE_CONV (component_11 @ sthms @ pthms)))
            \\ WEAK_STRIP_TAC
         val POST_TAC =
            PURE_ASM_REWRITE_TAC write_thms
            \\ Tactical.REVERSE CONJ_TAC
            >- (
                ASM_SIMP_TAC pure_ss frame_thms
                \\ (
                    REFL_TAC
                    ORELSE (RW_TAC pure_ss frame_thms
                            \\ (REFL_TAC ORELSE PRINT_TAC))
                   )
               )
            \\ CONV_TAC (Conv.RATOR_CONV STAR_ASSOC_CONV)
            (* For testing:
                   val tac = ref ALL_TAC
                   ASSUM_LIST (fn thms => (tac := UPD_TAC thms; ALL_TAC))
                   val update_TAC = !tac
            *)
            \\ ASSUM_LIST
                   (fn thms =>
                      let
                         val update_TAC = UPD_TAC thms
                      in
                         REPEAT
                           (
                            ONCE_REWRITE_TAC sthms
                            \\ CONJ_TAC
                            >- (
                                STATE_TAC
                                \\ update_TAC
                                \\ ASM_REWRITE_TAC [boolTheory.COND_ID]
                               )
                            \\ CONJ_TAC
                            >- ASM_REWRITE_TAC (component_11 @ pthms)
                           )
                      end
                   )
            \\ POP_ASSUM SUBST1_TAC
            \\ (REFL_TAC ORELSE ALL_TAC)
         val NEXT_TAC =
            RULE_ASSUM_TAC (PURE_REWRITE_RULE [combinTheory.I_THM])
            \\ ASM_REWRITE_TAC read_thms
            \\ EXTRA_TAC
            \\ PRINT_TAC
         fun tac (v, dthm) =
            PRE_TAC
            \\ Tactic.EXISTS_TAC v
            \\ CONJ_TAC
            >- (
                MATCH_MP_TAC dthm
                \\ NEXT_TAC
               )
            \\ POST_TAC
      in
         fn (thm, t) =>
            let
               val v = optionSyntax.dest_some (utilsLib.rhsc thm)
               val dthm = AND_IMP_INTRO_RULE (Drule.DISCH_ALL thm)
            in
               (*
                  set_goal ([], t)
               *)
               prove (t, tac (v, dthm))
            end
            handle e as HOL_ERR _ =>
                   (if !spec_debug
                       then (proofManagerLib.set_goal ([], t); thm)
                    else raise e)
      end
end

(* ------------------------------------------------------------------------ *)

end

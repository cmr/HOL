(* utility functions for working with bdd's and term-bdd's *)

structure bddTools =
struct

local

open Globals HolKernel Parse goalstackLib;
infixr 3 -->;
infix ## |-> THEN THENL THENC ORELSE ORELSEC THEN_TCL ORELSE_TCL;
open Psyntax;

open bossLib;
open pairTheory;
open pred_setTheory;
open pred_setLib;
open stringLib;
open listTheory;
open simpLib;
open pairSyntax;
open pairLib;
open PrimitiveBddRules;
open DerivedBddRules;
open Binarymap;
open PairRules;
open pairTools;
open setLemmasTheory;
open boolSyntax;
open Drule;
open Tactical;
open Conv;
open Rewrite;
open Tactic;
open boolTheory;
open listSyntax;
open stringTheory;
open stringBinTree;
open boolSimps;
open pureSimps;
open listSimps;
open numLib;
open reachTheory;
open HolSatLib;
open defCNF;
open holCheckTools

val dbgbt = holCheckTools.dbgall

fun DMSG m v = if v then let val _ = print "bddTools: " val _ = holCheckTools.DMSG m v in () end else ()

in

fun t2tb vm t = DerivedBddRules.GenTermToTermBdd (!DerivedBddRules.termToTermBddFun) vm t

fun mk_tb_res_subst red res vm = ListPair.map (fn (v,c) => (BddVar true vm v,BddCon (c=T) vm)) (red,res)


fun BddListConj vm (h::t) = if (List.null t) then h else PrimitiveBddRules.BddOp (bdd.And, h, (BddListConj vm t))
|   BddListConj vm [] = PrimitiveBddRules.BddCon true vm;

fun BddListDisj vm (h::t) = if (List.null t) then h else PrimitiveBddRules.BddOp (bdd.Or, h, (BddListDisj vm t))
|   BddListDisj vm [] = PrimitiveBddRules.BddCon false vm;


(* return bdd b as a DNF term (this is similar to the output of bdd.printset and in fact mimics the code) *)
(* used when the term part of bdd is higher order but we need the boolean equivalent                      *)
(* and it would be inefficient to unwind the higher order bits                                            *)
(* bddToTerm returns a nested i-t-e term that can get way too big                                         *) 
fun b2t vm b =
    if (bdd.equal b bdd.TRUE) then ``T``  
    else if (bdd.equal b bdd.FALSE) then ``F`` 
    else let val pairs = Binarymap.listItems vm
	     fun get_var n =
		 case assoc2 n pairs of
		     SOME(str,_) => mk_var(str,bool)
		   | NONE        => (failwith("b2t: Node "^(Int.toString n)^" has no name"))
	     fun b2t_aux b assl =
		 if (bdd.equal b bdd.TRUE)
		 then [assl]
		 else
		     if (bdd.equal b bdd.FALSE)
		     then []
		     else let val v = get_var(bdd.var b)
			  in (b2t_aux (bdd.high b) (v::assl))@(b2t_aux (bdd.low b) ((mk_neg v)::assl)) end
	 in
	     list_mk_disj (List.map list_mk_conj (b2t_aux b []))
	 end;

fun getIntForVar vm (s:string) =  Binarymap.find(vm,s);

fun getVarForInt vm (i:int) = 
    let val l = List.filter (fn (ks,ki) => ki=i) (Binarymap.listItems vm)
in if List.null l then NONE else SOME (fst(List.hd l)) end

fun termToBdd vm t = let val (_,_,_,b) = PrimitiveBddRules.dest_term_bdd(DerivedBddRules.GenTermToTermBdd (!DerivedBddRules.termToTermBddFun) vm t) in b end

(* transform term part of term-bdd using the supplied conversion; suppress UNCHANGED exceptions *)
fun BddConv conv tb = DerivedBddRules.BddApConv conv tb handle Conv.UNCHANGED => tb;

(* spells out one state in the bdd b *)
fun gba b vm = 
let val al = bdd.getAssignment (bdd.toAssignment_ b)
    fun lkp i = fst(List.hd (List.filter (fn (k,j) => j=i) (Binarymap.listItems vm)))
    in List.map (fn (i,bl) => (lkp i, bl)) al end

(* given a string from the output of bdd.printset (less the angle brackets), constructs equivalent bdd *)
fun mk_bdd s = 
let val vars = List.map (fn (vr,vl) => if vl=0 then bdd.nithvar vr else bdd.ithvar vr) 
			(List.map (fn arg =>
				      let val var = List.hd arg
					  val vl = List.last arg 
				      in ((Option.valOf o Int.fromString) var,
					  (Option.valOf o Int.fromString) vl) 
				      end) 
				  (List.map (String.tokens (fn c => Char.compare(c,#":")=EQUAL)) 
					    (String.tokens (fn c =>  Char.compare(c,#",")=EQUAL) s)))
    in List.foldl (fn (abdd,bdd) => bdd.AND(abdd,bdd)) (bdd.TRUE) vars end

(* constructs the bdd of one of the states of b, including only the vars in vm *)
fun mk_pt b vm = 
    let 
	val _ = DMSG (ST "mk_pt\n") (dbgbt)(*DBG*)
	val res = 
	    if bdd.equal bdd.FALSE b then bdd.FALSE
	    else let val b1 =  List.map (fn (vi,tv) => if tv then bdd.ithvar vi else bdd.nithvar vi) 
					(List.filter (fn (vi,tv) => Option.isSome(getVarForInt vm vi))
						 (bdd.getAssignment (bdd.fullsatone b)))
		 in List.foldl (fn (abdd,bdd) => bdd.AND(abdd,bdd)) (bdd.TRUE) b1 end
	val _ = if (dbgbt) then bdd.printset res else ()(*DBG*)
	val _ = DMSG (ST "mk_pt done\n") (dbgbt)(*DBG*)
    in res end

(* computes the image under bR of b1 *)
fun mk_next state bR vm b1 = 
    let 
	val _ = DMSG (ST "mk_next\n") (dbgbt)(*DBG*)
	fun getIntForVar v = Binarymap.find(vm,v)
	val sv = List.map term_to_string (strip_pair state)
	val svi =  List.map getIntForVar sv
	val spi = List.map getIntForVar (List.map (fn v => v^"'") sv)
	val s = bdd.makeset svi
	val sp2s =  bdd.makepairSet (ListPair.zip(List.foldl (fn (h,t) => h::t) [] (spi),List.foldl (fn (h,t) => h::t) [] (svi)))
	val res = bdd.replace (bdd.appex bR b1 bdd.And s) sp2s  
	val _ = DMSG (ST "mk_next done\n") (dbgbt)(*DBG*)
    in res end

(* computes the preimage under bR of b1 *)
fun mk_prev state bR vm b1 = 
    let 
	val _ = DMSG (ST "mk_prev\n") (dbgbt)(*DBG*)
	fun getIntForVar v = Binarymap.find(vm,v)
	val sv = List.map term_to_string (strip_pair state)
	val svi =  List.map getIntForVar sv
	val spi = List.map getIntForVar (List.map (fn v => v^"'") sv)
	val sp = bdd.makeset spi
	val s2sp =  bdd.makepairSet (ListPair.zip(List.foldl (fn (h,t) => h::t) [] (svi),List.foldl (fn (h,t) => h::t) [] (spi)))
	val res = bdd.appex bR (bdd.replace b1 s2sp) bdd.And sp 
	val _ = DMSG (ST "mk_prev done\n") (dbgbt)(*DBG*)
    in res end

fun mk_g'' ((fvt',t')::fvl) (fvt,t) ofvl = 
       if (Binaryset.isEmpty(Binaryset.intersection(fvt,fvt'))) 
       then mk_g'' fvl (fvt,t) ofvl
       else let val ofvl' = List.filter (fn (_,t) => not(Term.compare(t,t')=EQUAL)) ofvl 
	    in Binaryset.add(mk_g'' ofvl' (Binaryset.union(fvt,fvt'),t) ofvl',(fvt',t')) end
| mk_g'' [] (fvt,t) ofvl = Binaryset.add (Binaryset.empty (Term.compare o (snd ## snd)),(fvt,t))

fun mk_g' ((fvt,t)::fvl) = 
    let val fvs' = mk_g'' fvl (fvt,t) fvl
	val fvs = Binaryset.addList(Binaryset.empty (Term.compare o (snd ## snd)),fvl)
    in (fvs'::(mk_g' (Binaryset.listItems (Binaryset.difference(fvs,fvs'))))) end
| mk_g' [] = [] 

(* group terms in tc by free_vars *)
fun mk_g tc =
    let val fvl = ListPair.zip(List.map (fn t => Binaryset.addList(Binaryset.empty Term.compare, free_vars t)) tc,tc)
	val vcfc = mk_g' fvl 
    in List.map (fn l => List.foldl (fn ((fvt,t),(fvta,ta)) => (Binaryset.union(fvt,fvta),t::ta)) (Binaryset.empty Term.compare,[]) l) (List.map Binaryset.listItems vcfc) end
  
(* given a string*bool list and a term list, uses the first list as a set of substitutions for the terms, and simplify,
   filtering out any that simplify to true  *)
(* this is used with the output of gba (t being the conjuncts of R as grouped by mk_g) to get a term representation for the next state of the state given by sb *)
fun mk_sb sb t = 
 let val hsb = List.map (fn (t1,t2) => (mk_var(t1,``:bool``)) |-> (if t2 then ``T:bool`` else ``F:bool``)) sb
 in List.map (fn (t,t') => if (Term.compare(``F:bool``,t)=EQUAL) then (t,SOME t') else (t,NONE)) 
	 (List.filter (fn (t,t') => not (Term.compare(``T:bool``,t)=EQUAL)) 
	 (List.map (fn (t,t') => (rhs(concl(SIMP_CONV std_ss [] (Term.subst hsb t))) handle ex => (Term.subst hsb t),t')) 
	  (ListPair.zip(t,t)))) 
 end

(* return a satisfying assignment for t, as a HOL subst *)
fun findAss t = 
    let val th = satProve zchaff (snd(strip_exists(rhs(concl(DEF_CNF_CONV t)))))
	val t = strip_conj (fst(dest_imp (concl th)))
        val t1 = List.filter (fn v =>  (if is_neg v then not (is_genvar(dest_neg v)) else not (is_genvar v))) t
	fun ncompx v = not (String.compare(term_to_string v, "x")=EQUAL)
	val t2 = List.filter (fn v => if is_neg v then ncompx (dest_neg v) else ncompx v) t1
    in  List.map (fn v => if is_neg v then (dest_neg v) |-> ``F`` else v |-> ``T``) t2 end

(* given a list of vars and a HOL assignment to perhaps not all the vars in the list, return an order preserving list of bool assgns *)
(* this is for use with MAP_EVERY EXISTS_TAC *)
fun exv l ass = 
let val t1 = List.map (fn v => subst ass v) l
    in List.map (fn v => if is_var v then ``T`` else v) t1 end;

(* take a point bdd (i.e. just one state) and return it as concrete instance of state *)
fun pt_bdd2state state vm pb = 
    let val i2val = list2imap((bdd.getAssignment o bdd.toAssignment_) pb)
    in list_mk_pair (List.map (fn v => if Binarymap.find(i2val,Binarymap.find(vm,v)) then ``T`` else ``F``) 
			      (List.map term_to_string2 (strip_pair state))) 
    end

(* make varmap. if ordering is not given, just shuffle the current and next state vars. FIXME: do a better default *)
fun mk_varmap state bvm = 
    let val bvm = if (Option.isSome bvm) then Option.valOf bvm 
		  else let val st = strip_pair state
			   val st' = List.map prime st
			   val bvm = List.map (term_to_string2) (List.concat (List.map (fn (v,v') => [v',v]) (ListPair.zip(st,st'))))
		       in bvm end
	val vm = List.foldr (fn(v,vm') => Varmap.insert v vm') (Varmap.empty) (ListPair.zip(bvm,(List.tabulate(List.length bvm,I))))
	val _ = bdd.setVarnum (List.length bvm) (* this tells BuDDy where and what the vars are *)	  
    in vm end

end
end

(* 
(*FIXME: move this comment into documentation *)
(* debugging usage example *)
(* this assumes I1, R1, T1, ks_def and wfKS_ks have been computed... see alu.sml or ahb_total.sml or scratch.sml on howto for that*)
load "cearTools"; 
load "debugTools";
open cearTools; 
open debugTools;
val sc = DerivedBddRules.statecount;
val dtb = PrimitiveBddRules.dest_term_bdd;
open PrimitiveBddRules;
        val vm = List.foldr (fn(v,vm') => Varmap.insert v vm') (Varmap.empty)
			    (ListPair.zip(bvm,(List.tabulate(List.length bvm,fn x => x))))
	val _ = bdd.setVarnum (List.length bvm) (* this tells BuDDy where and what the vars are *)
	val tbRS = muTools.RcomputeReachable (R1,I1) vm;
	val brs = Primiti#veBddRules.getBdd tbRS;
	val Ree = Array.fromList []
	val RTm = muCheck.RmakeTmap T1 vm	
        val Tm = List.map (fn (nm,tb) => (nm,getTerm tb)) (Binarymap.listItems RTm) (* using nontotal R for ahbapb composition *)
	val (dks_def,wfKS_dks) = muCheck.mk_wfKS Tm I1 NONE NONE
	val chk = fn mf => muCheck.muCheck RTm Ree I1 mf (dks_def,wfKS_dks) vm NONE handle ex => Raise ex;
(* note how dbg below returns debugging info such as a bad state, it's forward and rear states and more readable versions of those *)
fun chk2 cf = let val tb2 = chk (ctl2mu cf) 
		  val bb2 = PrimitiveBddRules.getBdd tb2 
		  val bd = bdd.DIFF(brs,bdd.AND(brs,bb2))
		  val dbg = if bdd.equal bi (bdd.AND(bi,bdd.AND(brs,bb2))) then NONE
			    else let val Rtb = Binarymap.find (RTm,".") 
				     val b2 = mk_pt bd vm
				     val bn = mk_next I1 (getBdd Rtb) vm b2
				     val bp = mk_prev I1 (getBdd Rtb) vm b2
				     val sb = mk_sb (gba b2 vm) (strip_conj (getTerm Rtb)) 
				 in SOME (Rtb,b2,bn,bp,sb) end
	      in (tb2,bdd.AND(brs,bb2),bd,dbg) end;

*)



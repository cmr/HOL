(* Author: Michael Norrish *)

structure Arbintcore :> Arbintcore =
struct

open IntInf

type num = Arbnumcore.num

val zero = 0
val one = 1
val two = 2

fun toString x =
   (if x < 0
       then "-" ^ (IntInf.toString (~x))
    else IntInf.toString x) ^ "i"

fun fromString s =
   let
      open Substring
      val (pfx, rest) = splitl (fn c => c = #"-" orelse c = #"~") (full s)
      val is_positive = Int.mod (size pfx, 2) = 0
      val res = Arbnumcore.toLargeInt (Arbnumcore.fromString (string rest))
   in
      if is_positive then res else ~res
   end

val fromInt = IntInf.fromInt
fun fromLargeInt x = x
fun fromNat x = Arbnumcore.toLargeInt x
val toInt = IntInf.toInt
fun toLargeInt x = x
fun toNat x =
   if x < 0
      then raise Fail "Attempt to make negative integer a nat"
   else Arbnumcore.fromLargeInt x

val divmod = divMod
val quotrem = quotRem
fun negate x = ~x

end

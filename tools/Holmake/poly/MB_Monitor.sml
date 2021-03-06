structure MB_Monitor :> MB_Monitor =
struct

open ProcessMultiplexor Holmake_tools

val five_sec = Time.fromSeconds 5
val W_EXITED = Posix.Process.W_EXITED

(* thanks to Rob Arthan for this function *)
fun strmIsTTY (outstream : TextIO.outstream) =
  let
    val (wr as TextPrimIO.WR{ioDesc,...},buf) =
	TextIO.StreamIO.getWriter(TextIO.getOutstream outstream);
    val _ =
        TextIO.setOutstream (outstream, TextIO.StreamIO.mkOutstream(wr, buf))
  in
    case ioDesc of
	NONE => false
      | SOME desc => (OS.IO.kind desc = OS.IO.Kind.tty)
  end

val green = boldgreen
val red = boldred

fun nextchar #"|" = #"/"
  | nextchar #"/" = #"-"
  | nextchar #"-" = #"\\"
  | nextchar #"\\" = #"|"
  | nextchar c = c

fun stallstr "|" = "!"
  | stallstr ":" = "|"
  | stallstr "." = ":"
  | stallstr "!" = "!!"
  | stallstr "!!" = "!!!"
  | stallstr "!!!" = red "!!!"
  | stallstr s = s

datatype monitor_status = MRunning of char
                        | Stalling of string * Time.time
fun statusString (MRunning c) = StringCvt.padLeft #" " 3 (str c) ^ " "
  | statusString (Stalling(s, _)) = StringCvt.padLeft #" " 3 s ^ " "

fun rtrunc n s =
  if String.size s > n then
    "... " ^ String.substring(s, String.size s - (n - 4), n - 4)
  else StringCvt.padRight #" " n s

fun polish0 tag =
  if String.isSuffix "Theory" tag then
    String.substring(tag,0,String.size tag - 6)
  else tag

fun truncate width s =
  if String.size s > width then
    let
      open OS.Path
      val {arcs,isAbs,vol} = fromString s
      fun t s = truncate width s
    in
      if length arcs > 1 andalso String.size (hd arcs) >= 3 then
        t (".. " ^ toString {arcs=tl arcs,isAbs = false, vol = vol})
      else
        let
          val e = case ext s of NONE => "" | SOME s => s
        in
          if String.size e > 2 then t (base s ^ "..")
          else String.substring(s,0,14) ^ ".."
        end
    end
  else s

fun polish s = StringCvt.padRight #" " 16 (truncate 16 (polish0 s))

fun new {info,warn,genLogFile,keep_going} =
  let
    val monitor_map = ref (Binarymap.mkDict String.compare)
    fun ttydisplay_map () =
      let
        val _ = print "\r"
      in
        if Binarymap.numItems (!monitor_map) > 1 then
          (Binarymap.app (fn (k,(_,v)) =>
                             print (polish k ^ statusString v))
                         (!monitor_map);
           print "\027[0K" (* ANSI clear to EOL code *))
        else
          case Binarymap.listItems (!monitor_map) of
              [] => ()
            | (k,((strm,tb),stat)) :: _ =>
              let
                val s = case tailbuffer.last_line tb of NONE => "" | SOME s => s
              in
                print (polish k ^ rtrunc 57 (": " ^ s))
              end
      end
    fun id (s:string) = s
    val (startmsg, infopfx, display_map, green, red, boldyellow, dim) =
        if strmIsTTY TextIO.stdOut then
          ((fn s => ()), "\r", ttydisplay_map, green, red, boldyellow, dim)
        else
          ((fn s => info ("Starting work on " ^ s)), "", (fn () => ()),
           id, id, id, id)
    fun stdhandle tag f =
      case Binarymap.peek (!monitor_map, tag) of
          NONE => (warn ("Lost monitor info for "^tag); NONE)
        | SOME info => f info
    fun monitor msg =
      case msg of
          StartJob (_, tag) =>
          let
            val strm = TextIO.openOut (genLogFile{tag = tag})
            val tb =
                tailbuffer.new {numlines = 10, pattern = SOME "CHEAT"}
          in
            monitor_map :=
              Binarymap.insert(!monitor_map, tag, ((strm, tb), MRunning #"|"));
            startmsg tag;
            display_map();
            NONE
          end
        | Output((_, tag), t, chan, msg) =>
          stdhandle tag
            (fn ((strm,tb),stat) =>
                let
                  val stat' = case stat of MRunning c => MRunning (nextchar c)
                                         | Stalling _ => MRunning #"|"
                  open tailbuffer
                in
                  TextIO.output(strm,msg);
                  monitor_map :=
                    Binarymap.insert(!monitor_map, tag,
                                     (((strm,append msg tb), stat')));
                  display_map();
                  NONE
                end)
        | NothingSeen((_, tag), {delay,...}) =>
          stdhandle tag
            (fn (strm,stat) =>
                let
                  val stat' =
                      case stat of
                          MRunning c => if Time.>(delay, five_sec) then
                                          Stalling(".", delay)
                                        else MRunning c
                        | Stalling (s, sofar) =>
                          if Time.>(delay, Time.+(sofar, five_sec)) then
                            Stalling(stallstr s, delay)
                          else stat
                in
                  monitor_map :=
                    Binarymap.insert(!monitor_map, tag, (strm, stat'));
                  display_map();
                  NONE
                end)
        | Terminated((_, tag), st, _) =>
          stdhandle tag
            (fn ((strm,tb),stat) =>
                let
                  val {fulllines,lastpartial,pattern_seen} =
                      tailbuffer.output tb
                in
                  if st = W_EXITED then
                    if pattern_seen then
                      info ("\r" ^ StringCvt.padRight #" " 73 tag ^
                            boldyellow "CHEATED")
                    else
                      info (infopfx ^ StringCvt.padRight #" " 78 tag ^
                            green "OK")
                  else (info (infopfx ^ StringCvt.padRight #" " 73 tag ^
                              red "FAILED!");
                        List.app (fn s => info (" " ^ dim s)) fulllines;
                        if lastpartial <> "" then info (" " ^ dim lastpartial)
                        else ());
                  TextIO.closeOut strm;
                  monitor_map := #1 (Binarymap.remove(!monitor_map, tag));
                  display_map();
                  if st = W_EXITED orelse keep_going then NONE
                  else SOME KillAll
                end)
        | MonitorKilled((_, tag), _) =>
          stdhandle tag
            (fn ((strm,tb), stat) =>
                (info (infopfx ^ StringCvt.padRight #" " 72 tag ^
                       red "M-KILLED");
                 TextIO.closeOut strm;
                 monitor_map := #1 (Binarymap.remove(!monitor_map, tag));
                 display_map();
                 NONE))
        | _ => NONE
  in
    monitor
  end



end

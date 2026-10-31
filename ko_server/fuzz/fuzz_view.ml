open Ko_server

type source = Lines | Soup | Corpus of int | Osc8 | Wide | Kitty | Alt | Binary
type reader = Fast | Slow of int | Stalled

type op =
  | Feed of source * int * int
  | Resize of int * int
  | Open of Protocol.history * reader * bool * bool
  | Resume of int * Protocol.history * reader
  | Resync of int * Protocol.history
  | Reader of int * reader
  | Close of int * [ `Client | `Server ]
  | Eof
  | Crash
  | Settle of int
  | Check

let corpus =
  lazy
    (let dir = "../../bench/streams" in
     Sys.readdir dir |> Array.to_list
     |> List.filter (fun name -> Filename.check_suffix name ".vt")
     |> List.sort String.compare
     |> List.map (fun name ->
         In_channel.with_open_bin (Filename.concat dir name) In_channel.input_all))

let words =
  [| "alpha"; "beta"; "gamma"; "delta"; "x"; "日本語"; "naïve"; "👩‍👩‍👧"; "e\204\129"; "tab\t"; "" |]

let pick rand a = a.(Random.State.int rand (Array.length a))

let params rand =
  String.concat ";"
    (List.init (Random.State.int rand 4) (fun _ ->
         if Random.State.int rand 8 = 0 then "" else string_of_int (Random.State.int rand 300)))

let csi rand =
  let prefix = pick rand [| ""; ""; ""; "?"; ">"; "="; "<"; " "; "!" |] in
  let final =
    pick rand
      [|
        "m";
        "H";
        "J";
        "K";
        "A";
        "B";
        "C";
        "D";
        "r";
        "h";
        "l";
        "n";
        "c";
        "t";
        "d";
        "G";
        "X";
        "S";
        "T";
        "P";
        "L";
        "M";
        "@";
        "u";
        "s";
        "q";
        "g";
        "f";
        "E";
        "F";
        "b";
        "Z";
      |]
  in
  let params =
    if String.equal final "h" || String.equal final "l" then
      pick rand
        [|
          "?1049";
          "?1047";
          "?47";
          "?1000";
          "?1002";
          "?1006";
          "?2004";
          "?25";
          "?1";
          "?7";
          "?6";
          "?69";
          "?1004";
          "?2027";
          "?1003";
          "?9";
        |]
    else params rand
  in
  "\027[" ^ prefix ^ params ^ final

let terminator rand = if Random.State.bool rand then "\007" else "\027\\"

let osc rand =
  let code =
    pick rand
      [| "0"; "2"; "7"; "8"; "10"; "11"; "52"; "104"; "133"; "633"; "1337"; "9"; "777"; "99" |]
  in
  "\027]" ^ code ^ ";"
  ^ pick rand
      [|
        "";
        "title";
        ";https://example.org/a";
        "file://localhost/tmp";
        "A";
        "C;cmdline_url=ls";
        "D;0";
        "id=1;http://x";
        "?";
      |]
  ^ terminator rand

let dcs rand =
  "\027P"
  ^ pick rand
      [| "$qm"; "$q\"p"; "+q544e"; "1;1|17/ab"; "q#0;2;0;0;0#0~~~~"; "=1s"; "tmux;\027\027[0m" |]
  ^ terminator rand

let kitty rand =
  let id = 1 + Random.State.int rand 5 in
  let control =
    pick rand
      [|
        Printf.sprintf "a=T,f=32,s=2,v=2,i=%d,c=3,r=1" id;
        Printf.sprintf "a=p,i=%d,x=%d,y=0" id (Random.State.int rand 4);
        Printf.sprintf "a=d,d=i,i=%d" id;
        Printf.sprintf "a=t,f=24,s=1,v=1,i=%d,q=2" id;
        Printf.sprintf "a=f,i=%d,r=1,s=1,v=1,f=32" id;
        "a=q,i=31,s=1,v=1,t=s";
        "a=T,f=100,i=9";
        "a=d,d=A";
      |]
  in
  "\027_G" ^ control ^ ";"
  ^ pick rand [| "AQIDBA=="; "AAAAAAAAAAAAAAAA"; ""; "!!!"; String.make 40 'A' |]
  ^ "\027\\"

let piece rand = function
  | Lines ->
      String.concat " " (List.init (1 + Random.State.int rand 10) (fun _ -> pick rand words))
      ^ pick rand [| "\r\n"; "\r\n"; "\n"; "\r"; "\027[0m\r\n"; "\027[1;31mred\027[0m\r\n" |]
  | Soup -> (
      match Random.State.int rand 12 with
      | 0 | 1 | 2 | 3 -> csi rand
      | 4 -> osc rand
      | 5 -> dcs rand
      | 6 -> kitty rand
      | 7 ->
          pick rand
            [|
              "\027c";
              "\0277";
              "\0278";
              "\027M";
              "\027D";
              "\027E";
              "\027=";
              "\027>";
              "\027(0";
              "\027(B";
              "\027#8";
              "\027\\";
              "\027";
            |]
      | 8 -> String.make 1 (Char.chr (Random.State.int rand 32))
      | 9 -> pick rand words
      | 10 ->
          String.init
            (1 + Random.State.int rand 4)
            (fun _ -> Char.chr (0x80 + Random.State.int rand 128))
      | _ -> "\r\n")
  | Corpus i ->
      let corpus = Lazy.force corpus in
      let s = List.nth corpus (i mod List.length corpus) in
      let start = Random.State.int rand (String.length s) in
      String.sub s start (min (1 + Random.State.int rand 4096) (String.length s - start))
  | Osc8 ->
      let n = Random.State.int rand 1000 in
      Printf.sprintf "\027]8;%s;https://example.org/%d\027\\link %d\027]8;;\027\\\r\n"
        (pick rand [| ""; "id=a"; "id=b:c" |])
        n n
  | Wide ->
      pick rand
        [|
          "日本語のテキスト"; "😀😃😄"; "👩‍👩‍👧"; "e\204\129\204\130"; "ｱｲｳ"; "\227\128\128"; "a\226\128\139b"; "🇯🇵🇺🇸";
        |]
      ^ pick rand [| "\r\n"; ""; "\027[3G" |]
  | Kitty -> kitty rand ^ pick rand [| ""; "\r\n"; "text" |]
  | Alt ->
      pick rand
        [| "\027[?1049h"; "\027[?1049l"; "\027[?47h"; "\027[?47l"; "\027[?1047h"; "\027[?1047l" |]
      ^ String.concat "" (List.init (Random.State.int rand 5) (fun _ -> pick rand words ^ "\r\n"))
  | Binary ->
      String.init (1 + Random.State.int rand 64) (fun _ -> Char.chr (Random.State.int rand 256))

let chunk rand source size =
  let b = Buffer.create (size + 256) in
  while Buffer.length b < size do
    Buffer.add_string b (piece rand source)
  done;
  Buffer.sub b 0 size

type mirror = {
  mutable term : Ko_vt.t option;
  mutable offset : int option;
  mutable full : bool;
  mutable skipped : bool;
  mutable snapshot : (Buffer.t * int * bool) option;
  mutable snapshots : int;
}

type view = {
  v : View.t;
  fd : Unix.file_descr;
  mutable speed : reader;
  mutable pending : string;
  mutable alive : bool;
  mutable server_closed : bool;
  mutable reason : string;
  mutable expected_close : bool;
  mirror : mirror;
  recorder : mirror;
  frames : int ref;
}

type harness = {
  server : Fuzz_server.server;
  mutable feed : Unix.file_descr option;
  mutable queued : string;
  mutable sent : int;
  frames : int ref;
  mutable fed : int;
  mutable eof : bool;
  mutable crashed : bool;
  mutable views : view list;
  mutable retired : mirror list;
  mutable stable : int;
  mutable seen : int;
}

let fail fmt = Printf.ksprintf failwith fmt

exception Libghostty_decode

let describe m =
  Printf.sprintf "offset %s full %b skipped %b snapshotting %b"
    (match m.offset with Some n -> string_of_int n | None -> "-")
    m.full m.skipped (Option.is_some m.snapshot)

let apply_event m (event : Protocol.Event.view) =
  match event with
  | Marked { offset; marker } -> (
      if Option.is_some m.snapshot then fail "marker inside a snapshot";
      (match m.offset with
      | Some expected when Int.equal expected offset -> ()
      | _ -> fail "marker at offset %d for a mirror at %s" offset (describe m));
      match (marker, m.term) with
      | Resize size, Some term -> Ko_vt.resize term ~cols:size.cols ~rows:size.rows
      | Dead _, _ -> ()
      | Resize _, None -> fail "marker before any terminal")
  | Skipped { offset; from; to_ } ->
      (match m.offset with
      | Some current when Int.equal current from && Int.equal offset to_ && to_ >= from -> ()
      | _ -> fail "skip %d..%d (%d) for a mirror at %s" from to_ offset (describe m));
      m.skipped <- true;
      m.offset <- None
  | Pasted _ -> ()

let apply_record ~recorder m payload =
  let offset = Protocol.Record.offset_of_string payload in
  match Protocol.Record.kind_of_string payload with
  | Output -> (
      if m.skipped || Option.is_some m.snapshot then fail "output between a skip and its snapshot";
      match (m.offset, m.term) with
      | Some expected, Some term ->
          if not (Int.equal expected offset) then
            fail "output at offset %d where %d was due (gap or stale data)" offset expected;
          let size = String.length payload - Protocol.Record.header_size in
          Ko_vt.write term ~off:Protocol.Record.header_size ~len:size payload;
          m.offset <- Some (expected + size)
      | _ -> fail "output before a snapshot")
  | Snapshot ->
      let { Protocol.Record.first; last; screen } =
        Protocol.Record.slice_of_string payload Protocol.Record.header_size
      in
      let used = Protocol.Record.header_size + Protocol.Record.slice_size in
      let data = String.sub payload used (String.length payload - used) in
      let buffer =
        match (first, m.snapshot) with
        | true, None ->
            let b = Buffer.create 4096 in
            m.snapshots <- m.snapshots + 1;
            m.snapshot <- Some (b, offset, screen);
            b
        | false, Some (b, started, flag) ->
            if (not (Int.equal started offset)) || not (Bool.equal flag screen) then
              fail "snapshot slices disagree";
            b
        | true, Some _ -> fail "snapshot restarted inside a snapshot"
        | false, None -> fail "snapshot slice without its first"
      in
      Buffer.add_string buffer data;
      if last then begin
        let decoded =
          try Ko_vt.decode_string ~full:(not screen) (Buffer.contents buffer)
          with Failure message -> (
            let invalid = String.ends_with ~suffix:"(-2)" message in
            match recorder.term with
            | Some r when invalid && not Stdlib.(recorder == m) -> (
                match
                  Ko_vt.decode_string ~full:(not screen) (Ko_vt.snapshot r ~screen ~images:false)
                with
                | _ ->
                    fail "snapshot at %d does not decode, the recorder's own does: %s" offset
                      message
                | exception Failure again when String.equal again message -> raise Libghostty_decode
                )
            | Some _ | None -> fail "snapshot at %d does not decode: %s" offset message)
        in
        Option.iter Ko_vt.close m.term;
        m.term <- Some decoded;
        m.offset <- Some offset;
        m.skipped <- false;
        m.snapshot <- None;
        m.full <- not screen
      end

let deliver (view : view) opcode payload =
  incr view.frames;
  match opcode with
  | 1 -> apply_event view.mirror (Protocol.Event.view_of_json (Yojson.Basic.from_string payload))
  | 2 -> apply_record ~recorder:view.recorder view.mirror payload
  | 8 ->
      view.server_closed <- true;
      view.reason <- payload
  | _ -> ()

let parse view =
  let s = view.pending in
  let rec go pos =
    match Ws.parse s pos with
    | Some { opcode; length; size; _ } when String.length s - pos >= size + length ->
        deliver view opcode (String.sub s (pos + size) length);
        go (pos + size + length)
    | Some _ | None -> pos
  in
  let consumed = go 0 in
  view.pending <- String.sub s consumed (String.length s - consumed)

let read_view view =
  let budget = match view.speed with Fast -> 1 lsl 20 | Slow n -> n | Stalled -> 0 in
  let chunk = Bytes.create 65536 and left = ref budget in
  while view.alive && !left > 0 do
    match Unix.read view.fd chunk 0 (min !left (Bytes.length chunk)) with
    | 0 ->
        view.server_closed <- true;
        view.alive <- false
    | n ->
        left := !left - n;
        view.pending <- view.pending ^ Bytes.sub_string chunk 0 n;
        parse view
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> left := 0
    | exception Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _) ->
        view.server_closed <- true;
        view.alive <- false
  done

let unsent h = String.length h.queued - h.sent

let flush_feed h =
  (match h.feed with
  | None when (not h.eof) || unsent h > 0 -> (
      match Unix.openfile (h.server.dir ^ "/in") [ Unix.O_WRONLY; Unix.O_NONBLOCK ] 0 with
      | fd -> h.feed <- Some fd
      | exception Unix.Unix_error ((Unix.ENXIO | Unix.EINTR), _, _) -> ())
  | _ -> ());
  match h.feed with
  | None -> ()
  | Some fd ->
      (if unsent h > 0 then
         match Unix.single_write_substring fd h.queued h.sent (unsent h) with
         | n -> h.sent <- h.sent + n
         | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> ()
         | exception Unix.Unix_error (Unix.EPIPE, _, _) -> h.sent <- String.length h.queued);
      if h.eof && unsent h = 0 then begin
        Unix.close fd;
        h.feed <- None
      end

let tick h =
  let { Fuzz_server.state; pane; _ } = h.server in
  ignore (State.tick state : bool);
  Event_loop.step Peek;
  flush_feed h;
  ignore (State.tick state : bool);
  Panes.reap (State.panes state);
  List.iter read_view h.views;
  let progress =
    match Pane_proc.life (Pane.proc pane) with
    | Reaped -> !(h.frames)
    | Open | Closed -> !(h.frames) + Ring.head (Pane_proc.ring (Pane.proc pane))
  in
  if Int.equal progress h.seen then h.stable <- h.stable + 1
  else (
    h.seen <- progress;
    h.stable <- 0);
  Unix.sleepf 0.0002

let pane_state h =
  match Pane_proc.dead (Pane.proc h.server.pane) with
  | Some { cause = Failed message; _ } -> "failed: " ^ message
  | Some _ -> "exited"
  | None -> "running"

let until h what cond =
  let deadline = Unix.gettimeofday () +. 10. in
  while not (cond ()) do
    if Float.(Unix.gettimeofday () > deadline) then
      fail "timed out waiting for %s (fed %d, queued %d, pane %s, views: %s)" what h.fed (unsent h)
        (pane_state h)
        (String.concat "; "
           (List.map
              (fun v ->
                Printf.sprintf "[%s alive %b closed %b reason %S]" (describe v.mirror) v.alive
                  v.server_closed v.reason)
              h.views));
    tick h
  done

let open_view h ~history ~speed ~small ~offset ~mirror =
  let server, client = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.setsockopt_int server Unix.SO_SNDBUF (if small then 4096 else 262144);
  Unix.set_nonblock client;
  let connection = Connection.writer server in
  let v = View.create h.server.pane connection ~client:None ~offset ~history in
  let recorder = match h.views with first :: _ -> first.mirror | [] -> mirror in
  let view =
    {
      v;
      recorder;
      frames = h.frames;
      fd = client;
      speed;
      pending = "";
      alive = true;
      server_closed = false;
      reason = "";
      expected_close = h.crashed;
      mirror;
    }
  in
  if not (Connection.is_closed connection) then State.add_view h.server.state v;
  h.views <- h.views @ [ view ];
  view

let fresh_mirror () =
  { term = None; offset = None; full = true; skipped = false; snapshot = None; snapshots = 0 }

let drop h view =
  if view.alive then begin
    view.alive <- false;
    Unix.close view.fd
  end;
  h.views <- List.filter (fun x -> not Stdlib.(x == view)) h.views;
  State.remove_view h.server.state view.v

let retire h view =
  drop h view;
  let m = view.mirror in
  if Option.is_some m.term && Option.is_some m.offset && Option.is_none m.snapshot then
    h.retired <- m :: h.retired

let without_hyperlinks dump =
  let n = String.length dump in
  let b = Buffer.create n in
  let rec go i =
    if i < n then
      if
        i + 4 <= n
        && Char.equal dump.[i] '\027'
        && Char.equal dump.[i + 1] ']'
        && Char.equal dump.[i + 2] '8'
        && Char.equal dump.[i + 3] ';'
      then (
        let j = ref (i + 4) in
        while
          !j < n
          && not
               (Char.equal dump.[!j] '\007'
               || (Char.equal dump.[!j] '\027' && !j + 1 < n && Char.equal dump.[!j + 1] '\\'))
        do
          incr j
        done;
        go (if !j < n && Char.equal dump.[!j] '\027' then !j + 2 else !j + 1))
      else (
        Buffer.add_char b dump.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents b

let first_difference a b =
  let n = min (String.length a) (String.length b) in
  let i = ref 0 in
  while !i < n && Char.equal a.[!i] b.[!i] do
    incr i
  done;
  let around s =
    String.escaped (String.sub s (max 0 (!i - 60)) (min 160 (String.length s - max 0 (!i - 60))))
  in
  Printf.sprintf "at %d:\n  recorder %s\n  other    %s" !i (around a) (around b)

let compare_with reference name m =
  let term x = Option.get x.term in
  let history = reference.full && m.full in
  match Ko_vt.differences ~history ~strip:without_hyperlinks (term reference) (term m) with
  | [] -> ()
  | differences ->
      let dump x = Ko_vt.dump (term x) Plain in
      fail "%s differs from the recorder in %s%s" name (String.concat ", " differences)
        (if List.mem ~eq:String.equal "plain text" differences then
           " " ^ first_difference (dump reference) (dump m)
         else "")

let barrier h =
  let answered = ref false and text = Buffer.create 256 in
  Pane_proc.screen (Pane.proc h.server.pane) ~format:Plain ~history:Visible_only
    ~chunk:(fun chunk ~last:_ -> Buffer.add_string text chunk)
    ~done_:(fun _ -> answered := true);
  until h "the pane to answer" (fun () -> !answered);
  h.stable <- 0;
  Buffer.contents text

let converged h v =
  Int.equal (Option.value ~default:(-1) v.mirror.offset) h.fed
  && Option.is_none v.mirror.snapshot && (not v.mirror.skipped)
  && not (View.waiting v.v)

let check h =
  if h.crashed then List.iter (fun v -> v.speed <- Fast) h.views;
  if h.crashed then
    until h "views closed after a crash" (fun () ->
        List.for_all (fun v -> v.server_closed || not v.alive) h.views)
  else begin
    let r = List.hd h.views in
    until h "the recorder to see every byte while other views stall" (fun () ->
        Int.equal (unsent h) 0 && converged h r);
    let pane_screen = barrier h in
    List.iter (fun v -> v.speed <- Fast) h.views;
    until h "every view to catch up" (fun () ->
        h.stable >= 30 && List.for_all (fun v -> v.server_closed || converged h v) h.views);
    List.iter
      (fun v ->
        if v.server_closed && not v.expected_close then
          fail "the server closed a healthy view: %S, pane %s" v.reason (pane_state h);
        if (not v.server_closed) && not Stdlib.(v == r) then compare_with r.mirror "view" v.mirror)
      h.views;
    let rows text =
      let ascii = String.filter (fun c -> Char.code c < 128) text in
      List.rev
        (List.drop_while String.is_empty
           (List.rev_map String.rtrim (String.split_on_char '\n' ascii)))
    in
    let mirror_screen = rows (Ko_vt.dump (Option.get r.mirror.term) Plain) in
    if not (List.equal String.equal (rows pane_screen) mirror_screen) then
      fail "the pane's own screen differs from its mirror: %s"
        (first_difference pane_screen (String.concat "\n" mirror_screen));
    let snapshots = List.map (fun v -> v.mirror.snapshots) h.views in
    let probe =
      open_view h ~history:History_all ~speed:Fast ~small:true ~offset:None
        ~mirror:(fresh_mirror ())
    in
    until h "a fresh snapshot" (fun () -> h.stable >= 30 && converged h probe);
    if
      not
        (List.equal Int.equal snapshots
           (List.filteri
              (fun i _ -> i < List.length snapshots)
              (List.map (fun v -> v.mirror.snapshots) h.views)))
    then fail "an idle view took a snapshot because another view took one";
    compare_with r.mirror "fresh snapshot" probe.mirror;
    View.close probe.v;
    drop h probe;
    Option.iter Ko_vt.close probe.mirror.term
  end

let live h i =
  match h.views with
  | _ :: (_ :: _ as rest) -> Some (List.nth rest (i mod List.length rest))
  | _ -> None

let pane_open h =
  match Pane_proc.life (Pane.proc h.server.pane) with Open -> true | Closed | Reaped -> false

let step h op =
  match op with
  | Feed (source, size, seed) ->
      if not h.eof then begin
        let data = chunk (Random.State.make [| seed |]) source size in
        h.queued <- String.sub h.queued h.sent (String.length h.queued - h.sent) ^ data;
        h.sent <- 0;
        h.fed <- h.fed + String.length data
      end
  | Resize (cols, rows) ->
      if not h.crashed then
        Pane.resize h.server.pane { cols; rows; cell_px = Some { width = 8; height = 16 } }
  | Open (history, speed, small, bogus) ->
      if pane_open h then
        ignore
          (open_view h ~history ~speed ~small
             ~offset:(if bogus then Some (1 lsl 40) else None)
             ~mirror:(fresh_mirror ())
            : view)
  | Resume (i, history, speed) -> (
      match h.retired with
      | [] -> ()
      | _ when not (pane_open h) -> ()
      | retired ->
          let m = List.nth retired (i mod List.length retired) in
          h.retired <- List.filter (fun x -> not Stdlib.(x == m)) retired;
          ignore (open_view h ~history ~speed ~small:true ~offset:m.offset ~mirror:m : view))
  | Resync (i, history) ->
      Option.iter
        (fun v ->
          if not v.server_closed then
            View.receive v.v
              (Yojson.Basic.to_string
                 (Protocol.Request.view_to_json (Resync { history; images = Images_none }))))
        (live h i)
  | Reader (i, speed) -> Option.iter (fun v -> v.speed <- speed) (live h i)
  | Close (i, who) ->
      Option.iter
        (fun v ->
          v.expected_close <- true;
          (match who with `Client -> () | `Server -> View.close v.v);
          retire h v)
        (live h i)
  | Eof -> h.eof <- true
  | Crash ->
      if not h.crashed then begin
        h.crashed <- true;
        List.iter (fun v -> v.expected_close <- true) h.views;
        Pane_proc.kill (Pane.proc h.server.pane)
      end
  | Settle n ->
      for _ = 1 to n do
        tick h
      done
  | Check -> check h

let with_harness ~seed f =
  let rand = Random.State.make [| seed |] in
  Fuzz_server.with_server
    ~command:(fun dir -> "stty raw -echo; exec cat " ^ dir ^ "/in")
    ~activity:(fun () -> Random.State.bool rand)
    (fun server ->
      let h =
        {
          server;
          feed = None;
          queued = "";
          sent = 0;
          frames = ref 0;
          fed = 0;
          eof = false;
          crashed = false;
          views = [];
          retired = [];
          stable = 0;
          seen = 0;
        }
      in
      Fun.protect
        ~finally:(fun () ->
          List.iter (fun v -> if v.alive then Unix.close v.fd) h.views;
          List.iter (fun v -> View.close v.v) h.views;
          Option.iter Unix.close h.feed;
          List.iter (fun v -> Option.iter Ko_vt.close v.mirror.term) h.views;
          List.iter (fun m -> Option.iter Ko_vt.close m.term) h.retired)
        (fun () -> f h))

let run_exn ~seed ops =
  with_harness ~seed (fun h ->
      ignore
        (open_view h ~history:History_all ~speed:Fast ~small:false ~offset:None
           ~mirror:(fresh_mirror ())
          : view);
      List.iter (step h) ops;
      step h Check)

let run ~seed ops = try run_exn ~seed ops with Libghostty_decode -> QCheck2.assume_fail ()

let source_gen =
  let open QCheck2.Gen in
  oneof_weighted
    [
      (3, return Lines);
      (4, return Soup);
      (3, map (fun i -> Corpus i) (0 -- 6));
      (2, return Osc8);
      (1, return Wide);
      (1, return Kitty);
      (1, return Alt);
      (1, return Binary);
    ]

let reader_gen =
  let open QCheck2.Gen in
  oneof_weighted
    [ (4, return Fast); (2, map (fun n -> Slow (512 + (n * 512))) (0 -- 100)); (2, return Stalled) ]

let history_gen = QCheck2.Gen.oneof_list [ Protocol.History_none; History_all ]

let op_gen =
  let open QCheck2.Gen in
  let size = oneof_weighted [ (6, 1 -- 2000); (3, 2000 -- 60000); (1, 200_000 -- 700_000) ] in
  oneof_weighted
    [
      (10, map3 (fun source size seed -> Feed (source, size, seed)) source_gen size (no_shrink nat));
      ( 3,
        map2
          (fun c r -> if c = 1 && r = 1 then Resize (2, 1) else Resize (c, r))
          (1 -- 200) (1 -- 80) );
      ( 3,
        map3
          (fun h s (small, bogus) -> Open (h, s, small, bogus))
          history_gen reader_gen (pair bool bool) );
      (2, map3 (fun i h s -> Resume (i, h, s)) nat history_gen reader_gen);
      (3, map2 (fun i h -> Resync (i, h)) nat history_gen);
      (3, map2 (fun i s -> Reader (i, s)) nat reader_gen);
      (2, map2 (fun i who -> Close (i, who)) nat (oneof_list [ `Client; `Server ]));
      (1, return Eof);
      (1, return Crash);
      (3, map (fun n -> Settle n) (1 -- 50));
      (3, return Check);
    ]

let print_op =
  let history = function Protocol.History_none -> "screen" | History_all -> "full" in
  let reader = function
    | Fast -> "fast"
    | Slow n -> "slow" ^ string_of_int n
    | Stalled -> "stalled"
  in
  function
  | Feed (source, size, seed) ->
      Printf.sprintf "feed %s %d #%d"
        (match source with
        | Lines -> "lines"
        | Soup -> "soup"
        | Corpus i -> "corpus" ^ string_of_int i
        | Osc8 -> "osc8"
        | Wide -> "wide"
        | Kitty -> "kitty"
        | Alt -> "alt"
        | Binary -> "binary")
        size seed
  | Resize (c, r) -> Printf.sprintf "resize %dx%d" c r
  | Open (h, s, small, bogus) ->
      Printf.sprintf "open %s %s small=%b bogus=%b" (history h) (reader s) small bogus
  | Resume (i, h, _) -> Printf.sprintf "resume %d %s" i (history h)
  | Resync (i, h) -> Printf.sprintf "resync %d %s" i (history h)
  | Reader (i, s) -> Printf.sprintf "reader %d %s" i (reader s)
  | Close (i, who) ->
      Printf.sprintf "close %d %s" i (match who with `Client -> "client" | `Server -> "server")
  | Eof -> "eof"
  | Crash -> "crash"
  | Settle n -> Printf.sprintf "settle %d" n
  | Check -> "check"

let%test_module "Tests" =
  (module struct
    let seed, seconds = Ko_server.Fuzz_run.budget ()

    let%test "two views with a large history do not snapshot each other forever" =
      run ~seed:0
        [
          Open (History_none, Slow 12800, false, false);
          Open (History_all, Fast, false, true);
          Feed (Corpus 3, 419233, 9265);
          Feed (Soup, 469, 7);
          Resize (68, 36);
          Feed (Osc8, 517456, 8);
        ];
      true

    let%test "a signal while a screen reply waits for its pipe does not fail the pane" =
      with_harness ~seed:0 (fun h ->
          step h (Feed (Lines, 300_000, 1));
          let proc = Pane.proc h.server.pane and text = Buffer.create 65536 and result = ref None in
          until h "the pane to consume the feed" (fun () ->
              Int.equal (Ring.end_offset (Pane_proc.ring proc)) h.fed);
          Pane_proc.screen proc ~format:Plain ~history:Full_history
            ~chunk:(fun chunk ~last:_ -> Buffer.add_string text chunk)
            ~done_:(fun r -> result := Some r);
          Event_loop.step Peek;
          (* ko-pane does not report that it is blocked in screen_chunk's poll(POLLOUT) *)
          Unix.sleepf 0.1;
          step h Eof;
          flush_feed h;
          until h "the screen reply" (fun () -> Option.is_some !result);
          match Option.get !result with
          | Ok ()
            when Buffer.length text > 200_000
                 && not (String.starts_with ~prefix:"failed" (pane_state h)) ->
              true
          | result ->
              fail "screen %s, %d bytes, pane %s"
                (match result with Ok () -> "ok" | Error message -> message)
                (Buffer.length text) (pane_state h))

    let%test "libghostty-vt still cannot decode a snapshot of this stream" =
      match
        run_exn ~seed:969
          [
            Open (History_none, Fast, true, false);
            Feed (Osc8, 620, 4);
            Resize (167, 3);
            Feed (Lines, 45116, 3);
            Feed (Binary, 463, 2);
            Settle 26;
            Reader (352, Fast);
            Check;
            Open (History_all, Stalled, false, false);
            Open (History_all, Fast, true, false);
            Feed (Wide, 1860, 7);
            Reader (9, Fast);
            Resize (32, 66);
            Resize (11, 47);
            Feed (Corpus 2, 16010, 30);
          ]
      with
      | () -> false
      | exception Libghostty_decode -> true

    let%test "libghostty-vt still diverges after a full snapshot of a 1x1 terminal" =
      let limits = (Config.scrollback_limits (1 lsl 30)).terminal in
      let before = chunk (Random.State.make [| 6 |]) (Corpus 0) 55893
      and after = chunk (Random.State.make [| 5 |]) Soup 631 in
      let diverges (cols, rows) =
        let live = Ko_vt.create ~cols:80 ~rows:24 ~limits in
        Ko_vt.write live before;
        Ko_vt.resize live ~cols ~rows;
        let restored =
          Ko_vt.decode_string ~full:true (Ko_vt.snapshot live ~screen:false ~images:false)
        in
        List.iter
          (fun t ->
            Ko_vt.write t after;
            Ko_vt.resize t ~cols:39 ~rows:9)
          [ live; restored ];
        not (String.equal (Ko_vt.dump live Plain) (Ko_vt.dump restored Plain))
      in
      diverges (1, 1) && not (List.exists diverges [ (2, 2); (1, 24); (80, 1); (1, 2) ])

    let%test "views and mirrors stay equal to the pane under random operations" =
      Fuzz_check.check ?seed ?seconds ~count:3 ~name:"views"
        ~print:(fun (seed, ops) ->
          Printf.sprintf "seed %d: %s" seed (String.concat "; " (List.map print_op ops)))
        QCheck2.Gen.(pair (no_shrink nat) (list_size (3 -- 25) op_gen))
        (fun (seed, ops) ->
          run ~seed ops;
          true);
      true
  end)

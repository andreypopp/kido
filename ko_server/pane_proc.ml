type kind =
  | Init
  | Tail
  | Resize
  | Text
  | Snapshot
  | Exit
  | Ready
  | Head
  | Title
  | Pwd
  | Dead
  | Snapshot_done
  | Error
  | Full
  | Key
  | Paste
  | Paste_done
  | Mouse
  | Focus
  | Screen
[@@deriving equal]

type layout = { max_frame : int; max_key : int; frames : (string * int) array }

external layout : unit -> layout = "ko_pane_layout"

let layout = layout ()

let kind_of_name = function
  | "init" -> Init
  | "tail" -> Tail
  | "resize" -> Resize
  | "text" -> Text
  | "snapshot" -> Snapshot
  | "exit" -> Exit
  | "ready" -> Ready
  | "head" -> Head
  | "title" -> Title
  | "pwd" -> Pwd
  | "dead" -> Dead
  | "snapshot_done" -> Snapshot_done
  | "error" -> Error
  | "full" -> Full
  | "key" -> Key
  | "paste" -> Paste
  | "paste_done" -> Paste_done
  | "mouse" -> Mouse
  | "focus" -> Focus
  | "screen" -> Screen
  | name -> invalid_arg ("unknown pane frame " ^ name)

let wire = Array.to_list (Array.map (fun (name, code) -> (kind_of_name name, code)) layout.frames)
let to_int kind = List.assoc ~eq:equal_kind kind wire

let of_int code =
  match List.find_opt (fun (_, n) -> n = code) wire with
  | Some (kind, _) -> kind
  | None -> invalid_arg "unknown pane frame"

external spawn : string -> Luv.Buffer.t * Unix.file_descr * int = "ko_pane_start"
external unmap : Luv.Buffer.t -> unit = "ko_pane_unmap"

let number buffer value = function
  | 1 -> Buffer.add_char buffer (Char.chr value)
  | 2 -> Buffer.add_uint16_le buffer value
  | 4 -> Buffer.add_int32_le buffer (Int32.of_int value)
  | 8 -> Buffer.add_int64_le buffer (Int64.of_int value)
  | _ -> invalid_arg "integer width"

let string b s =
  Buffer.add_int32_le b (Int32.of_int (String.length s));
  Buffer.add_string b s

let size b (s : Protocol.size) =
  let cell = Option.value ~default:{ Protocol.width = 0; height = 0 } s.cell_px in
  List.iter (Buffer.add_uint16_le b) [ s.cols; s.rows; cell.width; cell.height ]

let frame kind body =
  let b = Buffer.create (String.length body + 5) in
  Buffer.add_int32_le b (Int32.of_int (String.length body + 1));
  Buffer.add_char b (Char.chr (to_int kind));
  Buffer.add_string b body;
  Buffer.contents b

let init (config : Config.t) ~id ~cwd ~argv ~env ~size:dimensions =
  let b = Buffer.create 512 in
  Buffer.add_uint16_le b 3;
  size b dimensions;
  let limits = config.limits.terminal in
  let max_bytes, max_lines =
    match limits.scrollback with
    | Scrollback_disabled -> (Some 0, None)
    | Scrollback { max_bytes; max_lines } -> (max_bytes, max_lines)
  in
  List.iter
    (fun limit ->
      Buffer.add_uint8 b (if Option.is_some limit then 1 else 0);
      Buffer.add_int64_le b (Int64.of_int (Option.value ~default:0 limit)))
    [ max_bytes; max_lines ];
  List.iter
    (fun n -> Buffer.add_int64_le b (Int64.of_int n))
    [ limits.apc_max_bytes; limits.kitty_images_max_bytes ];
  let media =
    List.fold_left
      (fun bits medium ->
        bits lor match medium with Config.File -> 1 | Temp_file -> 2 | Shared_mem -> 4)
      0 config.limits.media
  in
  Buffer.add_char b (Char.chr media);
  Buffer.add_int64_le b (Int64.of_int limits.continuation_max_bytes);
  string b cwd;
  List.iter
    (fun values ->
      Buffer.add_int32_le b (Int32.of_int (List.length values));
      List.iter (string b) values)
    [ argv; env ];
  string b (Ids.Pane_id.to_string id);
  Buffer.contents b

type life = Open | Closed | Reaped
type event = Title of string | Pwd of string | Output | Dead of Protocol.dead
type paste = { pasted : bool; unsafe : bool }

type reply =
  | Snapshot_reply of (Ring.record -> unit) * ((unit, string) result -> unit)
  | Screen_reply of (string -> last:bool -> unit) * ((unit, string) result -> unit)
  | Paste_reply of ((paste, string) result -> unit)

type t = {
  ring : Ring.t;
  control : Luv.Pipe.t;
  pid : int;
  notify : event -> unit;
  mutable life : life;
  mutable child : int;
  mutable title : string;
  mutable cwd : string;
  mutable dead : Protocol.dead option;
  mutable input : Bigstringaf.t;
  mutable filled : int;
  mutable next_req : int;
  pending : (int, reply) Hashtbl.t;
  snapshots : int Queue.t;
}

let is_open t = match t.life with Open -> true | Closed | Reaped -> false
let is_reaped t = match t.life with Reaped -> true | Open | Closed -> false
let pid t = t.pid
let child_pid t = t.child
let title t = t.title
let cwd t = t.cwd
let dead t = t.dead
let ring t = t.ring
let life t = t.life

let send t kind body =
  if is_open t then
    Luv.Stream.write t.control [ Luv.Buffer.from_string (frame kind body) ] (fun _ _ -> ())

let fail_pending t message =
  let pending = Hashtbl.to_seq_values t.pending |> List.of_seq in
  Hashtbl.clear t.pending;
  Queue.clear t.snapshots;
  List.iter
    (function
      | Snapshot_reply (_, done_) | Screen_reply (_, done_) -> done_ (Stdlib.Error message)
      | Paste_reply done_ -> done_ (Stdlib.Error message))
    pending

let killpg t =
  if t.child > 0 then
    (* macOS can return EPERM for a process group with only zombies or exiting processes. *)
    try Unix.kill (-t.child) Sys.sigkill
    with Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> ()

let die t (dead : Protocol.dead) =
  (match dead.cause with Failed _ -> killpg t | Exited _ | Signaled _ -> ());
  t.dead <- Some dead;
  t.notify (Dead dead)

let failure t message =
  if is_open t then begin
    t.life <- Closed;
    Luv.Handle.close t.control ignore;
    fail_pending t message;
    die t { at = Uv.now (); cause = Failed message }
  end

let scan t =
  if not (is_open t) then false
  else
    match
      Ring.scan t.ring (fun record ->
          match record.data with
          | Slice slice -> (
              match Queue.peek_opt t.snapshots with
              | None -> ()
              | Some req ->
                  (match Hashtbl.find_opt t.pending req with
                  | Some (Snapshot_reply (consume, _)) -> consume record
                  | _ -> ());
                  if slice.last then ignore (Queue.take t.snapshots : int))
          | Bytes | Resize_marker _ | Dead_marker _ -> ())
    with
    | Ok changed ->
        if Ring.pending t.ring then t.notify Output;
        changed
    | Stdlib.Error message ->
        failure t message;
        false

let request t kind body reply =
  if not (is_open t) then
    match reply with
    | Snapshot_reply (_, done_) | Screen_reply (_, done_) ->
        done_ (Stdlib.Error "pane process ended")
    | Paste_reply done_ -> done_ (Stdlib.Error "pane process ended")
  else begin
    let req = t.next_req in
    t.next_req <- req + 1;
    Hashtbl.add t.pending req reply;
    if equal_kind kind Snapshot then Queue.add req t.snapshots;
    let b = Buffer.create (String.length body + 4) in
    Buffer.add_int32_le b (Int32.of_int req);
    Buffer.add_string b body;
    send t kind (Buffer.contents b)
  end

let snapshot t ~history ~consume ~done_ =
  request t Snapshot
    ((match history with Protocol.History_all -> "\000" | History_none -> "\001")
    ^ "\000\000\000\000\000")
    (Snapshot_reply (consume, done_))

let screen t ~format ~history ~chunk ~done_ =
  let b = Buffer.create 5 in
  Buffer.add_char b (match format with Protocol.Request.Plain -> '\000' | Ansi -> '\001');
  Buffer.add_int32_le b
    (Int32.of_int
       (match history with
       | Protocol.Request.Visible_only -> 0
       | Full_history -> 0xffffffff
       | Last_rows n -> n));
  request t Screen (Buffer.contents b) (Screen_reply (chunk, done_))

let string_at buffer at =
  let len = Int32.to_int (Bigstringaf.get_int32_le buffer at) in
  if len < 0 || at + 4 + len > Bigstringaf.length buffer then invalid_arg "invalid pane string";
  Bigstringaf.substring buffer ~off:(at + 4) ~len

let on_frame t kind body =
  ignore (scan t : bool);
  match kind with
  | Ready ->
      if Bigstringaf.length body <> 4 then invalid_arg "invalid ready"
      else t.child <- Int32.to_int (Bigstringaf.get_int32_le body 0)
  | Title ->
      t.title <- string_at body 0;
      t.notify (Title t.title)
  | Pwd ->
      t.cwd <- string_at body 0;
      t.notify (Pwd t.cwd)
  | Head -> t.notify Output
  | Dead ->
      die t
        (match Ring.dead t.ring with
        | Some dead -> dead
        | None -> { at = Uv.now (); cause = Failed "pane exited without a marker" })
  | Full ->
      let b = Buffer.create 8 in
      Buffer.add_int64_le b (Int64.of_int (Ring.tail t.ring));
      send t Tail (Buffer.contents b);
      t.notify Output
  | Snapshot_done | Paste_done | Screen -> (
      let req = Int32.to_int (Bigstringaf.get_int32_le body 0) in
      match Hashtbl.find_opt t.pending req with
      | Some (Snapshot_reply (_, done_)) when equal_kind kind Snapshot_done ->
          Hashtbl.remove t.pending req;
          done_ (Ok ())
      | Some (Paste_reply done_) when equal_kind kind Paste_done ->
          Hashtbl.remove t.pending req;
          done_ (Ok { pasted = Char.code body.{4} = 1; unsafe = Char.code body.{5} = 1 })
      | Some (Screen_reply (chunk, done_)) when equal_kind kind Screen ->
          let last = Char.code body.{4} = 1 in
          chunk (string_at body 5) ~last;
          if last then (
            Hashtbl.remove t.pending req;
            done_ (Ok ()))
      | _ -> ())
  | Error -> failure t (string_at body 0)
  | _ -> ()

let frame_at input ~filled pos =
  if filled - pos < 4 then None
  else
    let len = Int32.to_int (Bigstringaf.get_int32_le input pos) in
    if len < 1 || len > layout.max_frame then invalid_arg "invalid control frame length";
    if len + 4 > filled - pos then None
    else
      let kind = of_int (Char.code input.{pos + 4}) in
      Some (kind, Bigstringaf.sub input ~off:(pos + 5) ~len:(len - 1), pos + 4 + len)

let create config ~id ~cwd ~argv ~env ~notify =
  let buffer, fd, pid = spawn config.Config.pane_exe in
  let control = Uv.ok (Luv.Pipe.init ()) in
  Uv.ok (Luv.Pipe.open_ control (Uv.file fd));
  let t =
    {
      ring = Ring.create buffer;
      control;
      pid;
      notify;
      life = Open;
      child = 0;
      title = "";
      cwd;
      dead = None;
      input = Bigstringaf.create 65536;
      filled = 0;
      next_req = 1;
      pending = Hashtbl.create 8;
      snapshots = Queue.create ();
    }
  in
  let allocate _ =
    if t.filled = Bigstringaf.length t.input then begin
      if t.filled >= layout.max_frame + 4 then invalid_arg "control frame too large";
      let input = Bigstringaf.create (min (layout.max_frame + 4) (2 * t.filled)) in
      Bigstringaf.blit t.input ~src_off:0 input ~dst_off:0 ~len:t.filled;
      t.input <- input
    end;
    Bigstringaf.sub t.input ~off:t.filled ~len:(Bigstringaf.length t.input - t.filled)
  in
  Luv.Stream.read_start ~allocate control (function
    | Ok chunk -> (
        t.filled <- t.filled + Bigstringaf.length chunk;
        try
          let pos = ref 0 in
          let running = ref true in
          while !running && is_open t do
            match frame_at t.input ~filled:t.filled !pos with
            | None -> running := false
            | Some (kind, body, next) ->
                pos := next;
                on_frame t kind body
          done;
          Bigstringaf.blit t.input ~src_off:!pos t.input ~dst_off:0 ~len:(t.filled - !pos);
          t.filled <- t.filled - !pos
        with Invalid_argument message -> failure t message)
    | Error _ -> failure t "pane control socket closed");
  send t Init (init config ~id ~cwd ~argv ~env ~size:Protocol.default_size);
  t

let shutdown t =
  if is_open t then (
    send t Exit "";
    t.life <- Closed;
    fail_pending t "pane removed";
    Luv.Handle.close t.control ignore)

let release t =
  if not (is_reaped t) then (
    unmap (Ring.buffer t.ring);
    t.life <- Reaped)

let reap t =
  if not (is_reaped t) then
    match Unix.waitpid [ Unix.WNOHANG ] t.pid with
    | 0, _ -> ()
    | _, status ->
        failure t
          (match status with
          | Unix.WEXITED n -> Printf.sprintf "pane process exited unexpectedly with status %d" n
          | Unix.WSIGNALED n | Unix.WSTOPPED n ->
              Printf.sprintf "pane process ended unexpectedly by signal %d" (Uv.native_signal n));
        release t
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> release t

let kill t =
  (if not (is_reaped t) then
     try Unix.kill t.pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
  killpg t

let resize t dimensions =
  let b = Buffer.create 8 in
  size b dimensions;
  send t Resize (Buffer.contents b)

let encode_input input =
  let b = Buffer.create 64 in
  let num n width =
    if n < 0 || (width < 8 && n >= 1 lsl (8 * width)) then invalid_arg "input value out of range";
    number b n width
  in
  let kind =
    match input with
    | Protocol.Request.Key key ->
        if key.key > layout.max_key then invalid_arg "invalid key";
        if
          key.unshifted_codepoint > 0x10ffff
          || (key.unshifted_codepoint >= 0xd800 && key.unshifted_codepoint <= 0xdfff)
        then invalid_arg "invalid codepoint";
        num (match key.action with Key_release -> 0 | Key_press -> 1 | Key_repeat -> 2) 1;
        num key.key 2;
        num key.mods 2;
        num key.unshifted_codepoint 4;
        string b key.text;
        num (if key.composing then 1 else 0) 1;
        Key
    | Mouse mouse ->
        num (match mouse.action with Mouse_press -> 0 | Mouse_release -> 1 | Mouse_motion -> 2) 1;
        num
          (match mouse.button with
          | Button_unknown -> 0
          | Button_left -> 1
          | Button_right -> 2
          | Button_middle -> 3
          | Button_four -> 4
          | Button_five -> 5
          | Button_six -> 6
          | Button_seven -> 7
          | Button_eight -> 8
          | Button_nine -> 9
          | Button_ten -> 10
          | Button_eleven -> 11)
          1;
        num mouse.col 2;
        num mouse.row 2;
        num mouse.mods 2;
        Mouse
    | Paste paste ->
        string b paste.text;
        num (if paste.check_safe then 1 else 0) 1;
        Paste
    | Text encoded ->
        (match Base64.decode encoded with
        | Ok text -> Buffer.add_string b text
        | Error (`Msg message) -> invalid_arg message);
        Text
    | Focus focused ->
        num (if focused then 1 else 0) 1;
        Focus
  in
  (kind, Buffer.contents b)

let input t input reply =
  try
    let kind, body = encode_input input in
    (match input with
    | Protocol.Request.Paste paste ->
        request t Paste body
          (Paste_reply
             (function
             | Stdlib.Error message -> reply (Stdlib.Error message)
             | Ok { pasted; unsafe } -> reply (Ok (Some { Protocol.id = paste.id; pasted; unsafe }))))
    | _ ->
        if not (is_open t) then reply (Stdlib.Error "pane process ended")
        else (
          send t kind body;
          reply (Ok None)));
    Ok ()
  with Invalid_argument message -> Stdlib.Error message

let%test_module "Tests" =
  (module struct
    let%expect_test "fragmented and multiple control frames" =
      let f = frame Text "abc" in
      let partial = String.sub f 0 6 in
      let input = Luv.Buffer.from_string partial in
      Printf.printf "%d %d\n"
        (match frame_at input ~filled:6 0 with None -> 0 | Some _ -> 1)
        (String.length partial);
      let input = Luv.Buffer.from_string (f ^ frame Exit "") in
      let pos = ref 0 and frames = ref [] in
      while !pos < Luv.Buffer.size input do
        match frame_at input ~filled:(Luv.Buffer.size input) !pos with
        | Some (kind, body, next) ->
            frames := Printf.sprintf "%d:%s" (to_int kind) (Bigstringaf.to_string body) :: !frames;
            pos := next
        | None -> pos := Luv.Buffer.size input
      done;
      Printf.printf "%s 0\n" (String.concat "," (List.rev !frames));
      (try ignore (frame_at (Luv.Buffer.from_string "\000\000\000\000") ~filled:4 0)
       with Invalid_argument message -> print_endline message);
      [%expect {|
 0 6
 4:abc,6: 0
 invalid control frame length
 |}]

    let%expect_test "typed input stays binary" =
      let kind, body = encode_input (Protocol.Request.Text "AAo=") in
      assert (equal_kind kind Text);
      Printf.printf "%d %d %d\n" (String.length body) (Char.code body.[0]) (Char.code body.[1]);
      let kind, body = encode_input (Protocol.Request.Focus true) in
      assert (equal_kind kind Focus);
      Printf.printf "%d\n" (Char.code body.[0]);
      let kind, body =
        encode_input
          (Protocol.Request.Key
             {
               action = Key_press;
               key = 20;
               mods = 2;
               unshifted_codepoint = 97;
               text = "a";
               composing = false;
             })
      in
      assert (equal_kind kind Key);
      Printf.printf "%d %ld\n" (String.length body) (String.get_int32_le body 5);
      [%expect {|
 2 0 10
 1
 15 97
 |}]
  end)

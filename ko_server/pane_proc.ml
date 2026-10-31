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
let by_code = Array.make 256 None
let () = List.iter (fun (kind, code) -> by_code.(code) <- Some kind) wire

let of_int code =
  match by_code.(code) with Some kind -> kind | None -> invalid_arg "unknown pane frame"

external spawn : string -> Bigstringaf.t * Unix.file_descr * int = "ko_pane_start"
external unmap : Bigstringaf.t -> unit = "ko_pane_unmap"

type claim = Awaiting | Reported of Pid.Group.t option

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

let frame_code code body =
  let b = Buffer.create (String.length body + 5) in
  Buffer.add_int32_le b (Int32.of_int (String.length body + 1));
  Buffer.add_char b (Char.chr code);
  Buffer.add_string b body;
  Buffer.contents b

let frame kind body = frame_code (to_int kind) body

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
type event = Title | Pwd | Output | Dead of Protocol.dead
type text = { mutable bytes : Bytes.t; mutable length : int }

let text_of_string s = { bytes = Bytes.of_string s; length = String.length s }
let text_get text = Bytes.sub_string text.bytes 0 text.length

type paste = { pasted : bool; unsafe : bool }

type reply =
  | Screen_reply of (string -> last:bool -> unit) * ((unit, string) result -> unit)
  | Paste_reply of ((paste, string) result -> unit)

type t = {
  core : Pane_core.pane;
  control : Event_loop.watch;
  outbox : Outbox.t;
  pid : Pid.t;
  notify : event -> unit;
  mutable life : life;
  mutable child : claim;
  title : text;
  cwd : text;
  mutable dead : Protocol.dead option;
  mutable input : Bigstringaf.t;
  mutable filled : int;
  mutable next_req : int;
  pending : (int, reply) Hashtbl.t;
  finishing : (unit -> unit) Queue.t;
}

let is_open t = match t.life with Open -> true | Closed | Reaped -> false
let is_reaped t = match t.life with Reaped -> true | Open | Closed -> false
let pid t = t.pid

let child_pid t =
  match t.child with
  | Reported (Some group) -> Some (Pid.Group.leader group)
  | Awaiting | Reported None -> None

let title t = text_get t.title
let cwd t = text_get t.cwd
let dead t = t.dead
let ring t = Pane_core.ring t.core
let busy t = Pane_core.busy t.core
let life t = t.life

let run_finishing t =
  while not (Queue.is_empty t.finishing) do
    (Queue.take t.finishing) ()
  done

let fail_pending t message =
  let pending = Hashtbl.to_seq_values t.pending |> List.of_seq in
  Hashtbl.clear t.pending;
  Pane_core.fail_requests t.core;
  run_finishing t;
  List.iter
    (function
      | Screen_reply (_, done_) -> done_ (Stdlib.Error message)
      | Paste_reply done_ -> done_ (Stdlib.Error message))
    pending

let kill_group t =
  match t.child with
  | Reported (Some group) -> Pid.Group.signal group Sys.sigkill
  | Awaiting | Reported None -> ()

let die t (dead : Protocol.dead) =
  (match dead.cause with Failed _ -> kill_group t | Exited _ | Signaled _ -> ());
  t.dead <- Some dead;
  t.notify (Dead dead)

let close_control t = Event_loop.close t.control

let failure t message =
  if is_open t then begin
    t.life <- Closed;
    close_control t;
    fail_pending t message;
    die t { at = Native.now (); cause = Failed message }
  end

let flush_control t =
  if is_open t then
    match Outbox.flush t.outbox (Event_loop.fd t.control) with
    | Done -> Event_loop.interest t.control Read
    | Blocked -> Event_loop.interest t.control Read_write
    | Failed -> failure t "pane control socket closed"

let send t kind body =
  if is_open t then begin
    let idle = Outbox.is_empty t.outbox in
    Outbox.add t.outbox (frame kind body);
    if idle then flush_control t
  end

let early_slice = "ko-pane wrote a slice before its request"
let deliver t = if not (Pane_core.deliver t.core (Ring.head (ring t))) then invalid_arg early_slice

let scan t =
  match Pane_core.scan t.core (is_open t) with
  | Changed -> true
  | Unchanged -> false
  | Aborted ->
      failure t early_slice;
      false
  | exception Invalid_argument message ->
      failure t message;
      false

let ended = "pane process ended"

let request_with t kind body register =
  let req = t.next_req in
  t.next_req <- req + 1;
  register req;
  let b = Buffer.create (String.length body + 4) in
  Buffer.add_int32_le b (Int32.of_int req);
  Buffer.add_string b body;
  send t kind (Buffer.contents b)

let request t kind body reply =
  if not (is_open t) then
    match reply with
    | Screen_reply (_, done_) -> done_ (Stdlib.Error ended)
    | Paste_reply done_ -> done_ (Stdlib.Error ended)
  else request_with t kind body (fun req -> Hashtbl.add t.pending req reply)

let snapshot t ~history ~consume ~done_ =
  is_open t
  &&
  let sent = ref false in
  let finish ok =
    if !sent then
      Queue.add
        (fun () -> done_ (if ok then Ok () else Stdlib.Error "snapshot did not complete"))
        t.finishing
  in
  request_with t Snapshot
    ((match history with Protocol.History_all -> "\000" | History_none -> "\001")
    ^ "\000\000\000\000\000")
    (fun req -> Pane_core.note_snapshot t.core { req; consume; finish });
  sent := is_open t;
  !sent

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

let int32_at = Mem.int32
let need len size = if len < size then invalid_arg "short pane frame"

let string_at buffer ~off ~len at =
  need len (at + 4);
  let slen = int32_at buffer (off + at) in
  if slen < 0 || at + 4 + slen > len then invalid_arg "invalid pane string";
  Bigstringaf.substring buffer ~off:(off + at + 4) ~len:slen

let store text buffer ~off ~len at =
  need len (at + 4);
  let slen = int32_at buffer (off + at) in
  if slen < 0 || at + 4 + slen > len then invalid_arg "invalid pane string";
  let source = off + at + 4 in
  let same = ref (slen = text.length) and i = ref 0 in
  while !same && !i < slen do
    if Char.equal (Bigstringaf.get buffer (source + !i)) (Bytes.unsafe_get text.bytes !i) then
      incr i
    else same := false
  done;
  if !same then false
  else begin
    if Bytes.length text.bytes < slen then
      text.bytes <- Bytes.create (max slen (2 * Bytes.length text.bytes));
    Bigstringaf.blit_to_bytes buffer ~src_off:source text.bytes ~dst_off:0 ~len:slen;
    text.length <- slen;
    true
  end

let on_frame t kind ~off ~len =
  let body = t.input in
  match kind with
  | Ready -> (
      if len <> 4 then invalid_arg "invalid ready";
      match t.child with
      | Awaiting -> (
          match Pid.Group.verify ~parent:t.pid (int32_at body off) with
          | Foreign -> invalid_arg "invalid ready"
          | Gone -> t.child <- Reported None
          | Child group -> t.child <- Reported (Some group))
      | Reported _ -> invalid_arg "invalid ready")
  | Title -> if store t.title body ~off ~len 0 then t.notify Title
  | Pwd -> if store t.cwd body ~off ~len 0 then t.notify Pwd
  | Head -> t.notify Output
  | Dead ->
      if len <> 16 then invalid_arg "invalid dead";
      let status = int32_at body off and signal = int32_at body (off + 4) in
      die t
        {
          at = Mem.int64 body (off + 8);
          cause = (if signal = 0 then Exited status else Signaled signal);
        }
  | Full ->
      ignore (scan t : bool);
      let b = Buffer.create 8 in
      Buffer.add_int64_le b (Int64.of_int (Ring.tail (ring t)));
      send t Tail (Buffer.contents b);
      t.notify Output
  | Snapshot_done | Paste_done | Screen -> (
      need len (match kind with Snapshot_done -> 4 | Paste_done -> 6 | _ -> 9);
      deliver t;
      let req = int32_at body off in
      if equal_kind kind Snapshot_done then (
        Pane_core.snapshot_done t.core req;
        run_finishing t);
      match Hashtbl.find_opt t.pending req with
      | Some (Paste_reply done_) when equal_kind kind Paste_done ->
          Hashtbl.remove t.pending req;
          done_
            (Ok { pasted = Char.code body.{off + 4} = 1; unsafe = Char.code body.{off + 5} = 1 })
      | Some (Screen_reply (chunk, done_)) when equal_kind kind Screen ->
          let last = Char.code body.{off + 4} = 1 in
          chunk (string_at body ~off ~len 5) ~last;
          if last then (
            Hashtbl.remove t.pending req;
            done_ (Ok ()))
      | _ -> ())
  | Error -> failure t (string_at body ~off ~len 0)
  | _ -> ()

let frame_size input ~filled pos =
  if filled - pos < 4 then 0
  else
    let len = int32_at input pos in
    if len < 1 || len > layout.max_frame then invalid_arg "invalid control frame length";
    if len + 4 > filled - pos then 0 else len + 4

let consume t =
  let pos = ref 0 and running = ref true in
  while !running && is_open t do
    let size = frame_size t.input ~filled:t.filled !pos in
    if size = 0 then running := false
    else begin
      let at = !pos in
      pos := at + size;
      on_frame t (of_int (Char.code t.input.{at + 4})) ~off:(at + 5) ~len:(size - 5)
    end
  done;
  Bigstringaf.blit t.input ~src_off:!pos t.input ~dst_off:0 ~len:(t.filled - !pos);
  t.filled <- t.filled - !pos

let create config ~id ~cwd ~argv ~env ~notify =
  let buffer, fd, pid = spawn config.Config.pane_exe in
  let pid =
    match Pid.of_int pid with
    | Some pid -> pid
    | None ->
        Unix.close fd;
        unmap buffer;
        ignore (Unix.waitpid [] pid : int * Unix.process_status);
        invalid_arg "pane pid"
  in
  Unix.set_nonblock fd;
  let t =
    {
      core = Pane_core.make (Ring.create buffer) (Delivery_io.pane_io_create ());
      control = Event_loop.watch fd;
      outbox = Outbox.create ();
      pid;
      notify;
      life = Open;
      child = Awaiting;
      title = text_of_string "";
      cwd = text_of_string cwd;
      dead = None;
      input = Bigstringaf.create 65536;
      filled = 0;
      next_req = 1;
      pending = Hashtbl.create 8;
      finishing = Queue.create ();
    }
  in
  let window = { Event_loop.buffer = t.input; off = 0; len = Bigstringaf.length t.input } in
  let refresh () =
    if t.filled = Bigstringaf.length t.input then begin
      if t.filled >= layout.max_frame + 4 then invalid_arg "control frame too large";
      let input = Bigstringaf.create (min (layout.max_frame + 4) (2 * t.filled)) in
      Bigstringaf.blit t.input ~src_off:0 input ~dst_off:0 ~len:t.filled;
      t.input <- input
    end;
    window.buffer <- t.input;
    window.off <- t.filled;
    window.len <- Bigstringaf.length t.input - t.filled
  in
  Event_loop.handle t.control
    (Stream
       {
         window;
         on_data =
           (fun n ->
             try
               t.filled <- t.filled + n;
               consume t;
               if is_open t then refresh ()
             with Invalid_argument message -> failure t message);
         on_end = (fun () -> failure t "pane control socket closed");
       })
    ~on_writable:(fun () -> flush_control t);
  Event_loop.interest t.control Read;
  send t Init (init config ~id ~cwd ~argv ~env ~size:Protocol.default_size);
  t

let shutdown t =
  if is_open t then (
    send t Exit "";
    t.life <- Closed;
    fail_pending t "pane removed";
    close_control t)

let release t =
  if not (is_reaped t) then (
    unmap (Ring.buffer (ring t));
    t.life <- Reaped)

let reap t =
  if not (is_reaped t) then
    match Unix.waitpid [ Unix.WNOHANG ] (Pid.to_int t.pid) with
    | 0, _ -> ()
    | _, status ->
        failure t
          (match status with
          | Unix.WEXITED n -> Printf.sprintf "pane process exited unexpectedly with status %d" n
          | Unix.WSIGNALED n | Unix.WSTOPPED n ->
              Printf.sprintf "pane process ended unexpectedly by signal %d" (Native.native_signal n));
        release t
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> release t

let kill t =
  (if not (is_reaped t) then
     match Pid.signal t.pid Sys.sigkill with
     | Ok () | Error Unix.ESRCH -> ()
     | Error error -> raise (Unix.Unix_error (error, "kill", "")));
  kill_group t

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
    let bigstring s = Bigstringaf.of_string ~off:0 ~len:(String.length s) s

    let%expect_test "fragmented and multiple control frames" =
      let f = frame Text "abc" in
      let partial = String.sub f 0 6 in
      Printf.printf "%d %d\n" (frame_size (bigstring partial) ~filled:6 0) (String.length partial);
      let input = bigstring (f ^ frame Exit "") in
      let pos = ref 0 and frames = ref [] in
      while !pos < Bigstringaf.length input do
        let size = frame_size input ~filled:(Bigstringaf.length input) !pos in
        frames :=
          Printf.sprintf "%d:%s"
            (to_int (of_int (Char.code input.{!pos + 4})))
            (Bigstringaf.substring input ~off:(!pos + 5) ~len:(size - 5))
          :: !frames;
        pos := !pos + size
      done;
      Printf.printf "%s 0\n" (String.concat "," (List.rev !frames));
      (try ignore (frame_size (bigstring "\000\000\000\000") ~filled:4 0)
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

    let small_ring () =
      let buffer = Bigstringaf.create (Ring.layout.data_offset + 64) in
      Bigarray.Array1.fill buffer '\000';
      Bigstringaf.set_int64_le buffer 0 64L;
      Ring.create buffer

    let unsignalled_pid =
      let child = Unix.create_process "true" [| "true" |] Unix.stdin Unix.stdout Unix.stderr in
      ignore (Unix.waitpid [] child);
      Option.get (Pid.of_int child)

    let fake ?(notify = ignore) ?(ring = small_ring ())
        ?(control = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0) () =
      {
        core = Pane_core.make ring (Delivery_io.pane_io_create ());
        control = Event_loop.watch control;
        outbox = Outbox.create ();
        pid = unsignalled_pid;
        notify;
        life = Open;
        child = Awaiting;
        title = text_of_string "";
        cwd = text_of_string "";
        dead = None;
        input = Bigstringaf.create 4096;
        filled = 0;
        next_req = 1;
        pending = Hashtbl.create 1;
        finishing = Queue.create ();
      }

    let feed t data =
      Bigstringaf.blit_from_string data ~src_off:0 t.input ~dst_off:t.filled
        ~len:(String.length data);
      t.filled <- t.filled + String.length data;
      consume t

    let title_frame text =
      let b = Buffer.create 16 in
      string b text;
      frame Title (Buffer.contents b)

    let%expect_test "events fire once per change of the stored title" =
      let events = ref 0 in
      let t = fake ~notify:(fun _ -> incr events) () in
      let report label =
        Printf.printf "%s: %d events, title %S\n" label !events (title t);
        events := 0
      in
      feed t (String.concat "" (List.map title_frame [ "A"; "B"; "A" ]));
      report "A B A in one read";
      feed t (String.concat "" (List.map title_frame [ "A"; "A"; "A" ]));
      report "A A A after A";
      let frame_text = title_frame "split title" in
      feed t (String.sub frame_text 0 7);
      report "first part of a split frame";
      feed t (String.sub frame_text 7 (String.length frame_text - 7));
      report "rest of the frame";
      [%expect
        {|
        A B A in one read: 3 events, title "A"
        A A A after A: 0 events, title "A"
        first part of a split frame: 0 events, title "A"
        rest of the frame: 1 events, title "split title"
      |}]

    let%expect_test "a frame body shorter than its fields fails instead of reading the next frame" =
      let t = fake () in
      let fails kind body =
        t.filled <- 0;
        match feed t (frame kind body ^ frame Head "\000\000\000\000\000\000\000\000") with
        | () -> Printf.printf "accepted a short body\n"
        | exception Invalid_argument message -> print_endline message
      in
      fails Snapshot_done "\001\000";
      fails Paste_done "\001\000\000\000\001";
      fails Title "\005";
      [%expect
        {|
        short pane frame
        short pane frame
        short pane frame
      |}]

    let data_offset = Ring.layout.data_offset
    and record_header = Ring.layout.record_header
    and slice_tag = 3

    let slice_record buffer ~pos ~first ~last =
      let base = data_offset + pos in
      buffer.{base} <- Char.chr slice_tag;
      Bigstringaf.set_int32_le buffer (base + 1) 100l;
      Bigstringaf.set_int64_le buffer (base + 5) 0L;
      buffer.{base + record_header} <- Char.chr ((if first then 1 else 0) lor if last then 2 else 0);
      pos + record_header + 100

    let%expect_test "the tail never passes snapshot slices that were not delivered" =
      let capacity = 2048 in
      let buffer = Bigstringaf.create (data_offset + capacity) in
      Bigarray.Array1.fill buffer '\000';
      Bigstringaf.set_int64_le buffer 0 (Int64.of_int capacity);
      let count = 15 in
      let ends = Array.make count 0 in
      let pos = ref 0 in
      for i = 0 to count - 1 do
        pos := slice_record buffer ~pos:!pos ~first:(i = 0) ~last:(i = count - 1);
        ends.(i) <- !pos
      done;
      let set_head head = Bigstringaf.set_int64_le buffer 8 (Int64.of_int head) in
      let ring = Ring.create buffer in
      let delivered = ref [] in
      let t = fake ~ring () in
      Pane_core.note_snapshot t.core
        {
          req = 1;
          consume =
            (fun pos ->
              delivered := pos :: !delivered;
              set_head ends.(count - 1));
          finish = ignore;
        };
      set_head ends.(2);
      ignore (scan t : bool);
      Printf.printf "delivered %d, tail passed the undelivered slices: %b\n"
        (List.length !delivered)
        (Ring.tail ring > ends.(2));
      ignore (scan t : bool);
      Printf.printf "delivered %d in order: %b\n" (List.length !delivered)
        (List.equal Int.equal (List.rev !delivered)
           (0 :: List.init (count - 1) (fun i -> ends.(i))));
      [%expect
        {|
        delivered 3, tail passed the undelivered slices: false
        delivered 15 in order: true
      |}]

    let%expect_test "a finished snapshot keeps its cursor in the ring until its snapshot_done" =
      let capacity = 2048 in
      let buffer = Bigstringaf.create (data_offset + capacity) in
      Bigarray.Array1.fill buffer '\000';
      Bigstringaf.set_int64_le buffer 0 (Int64.of_int capacity);
      let t = fake ~ring:(Ring.create buffer) () in
      let ring = ring t in
      let cursor = ref 0 in
      let report = ref "" in
      let asked =
        snapshot t ~history:History_none
          ~consume:(fun pos -> cursor := Ring.next ring pos)
          ~done_:(fun _ ->
            report :=
              Printf.sprintf "A done: cursor %d, tail %d, cursor still in the ring: %b" !cursor
                (Ring.tail ring)
                (Ring.tail ring <= !cursor))
        && snapshot t ~history:History_none ~consume:ignore ~done_:ignore
      in
      assert asked;
      let pos = ref 0 in
      for i = 0 to 2 do
        pos := slice_record buffer ~pos:!pos ~first:(i = 0) ~last:(i = 2)
      done;
      let base = data_offset + !pos in
      buffer.{base} <- Char.chr Ring.layout.bytes_tag;
      Bigstringaf.set_int32_le buffer (base + 1) 100l;
      Bigstringaf.set_int64_le buffer (base + 5) 0L;
      pos := !pos + record_header + 100;
      for i = 0 to 13 do
        pos := slice_record buffer ~pos:!pos ~first:(i = 0) ~last:false
      done;
      Bigstringaf.set_int64_le buffer 8 (Int64.of_int !pos);
      ignore (scan t : bool);
      feed t (frame Snapshot_done "\001\000\000\000");
      print_endline !report;
      [%expect {| A done: cursor 339, tail 339, cursor still in the ring: true |}]

    let%expect_test "a snapshot asked for from a snapshot's done callback gets the slices after it"
        =
      let capacity = 2048 in
      let buffer = Bigstringaf.create (data_offset + capacity) in
      Bigarray.Array1.fill buffer '\000';
      Bigstringaf.set_int64_le buffer 0 (Int64.of_int capacity);
      let t = fake ~ring:(Ring.create buffer) () in
      let result = function Ok () -> "ok" | Stdlib.Error message -> message in
      let write slices =
        let pos = ref (Ring.head (ring t)) in
        for i = 0 to slices - 1 do
          pos := slice_record buffer ~pos:!pos ~first:(i = 0) ~last:(i = slices - 1)
        done;
        Bigstringaf.set_int64_le buffer 8 (Int64.of_int !pos);
        ignore (scan t : bool)
      in
      let asked =
        snapshot t ~history:History_none ~consume:(Printf.printf "A slice %d\n") ~done_:(fun r ->
            Printf.printf "A %s\n" (result r);
            assert (
              snapshot t ~history:History_none ~consume:(Printf.printf "B slice %d\n")
                ~done_:(fun r -> Printf.printf "B %s\n" (result r))))
      in
      assert asked;
      write 2;
      feed t (frame Snapshot_done "\001\000\000\000");
      write 2;
      feed t (frame Snapshot_done "\002\000\000\000");
      [%expect
        {|
        A slice 0
        A slice 113
        A ok
        B slice 226
        B slice 339
        B ok
        |}]

    let%expect_test "a snapshot request that cannot be sent is refused, and its callback never runs"
        =
      let t = fake ~control:(Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0) () in
      let asked =
        snapshot t ~history:History_none ~consume:ignore ~done_:(fun r ->
            Printf.printf "done: %s\n" (match r with Ok () -> "ok" | Stdlib.Error m -> m))
      in
      Printf.printf "asked %b, pane open: %b\n" asked (is_open t);
      [%expect {| asked false, pane open: false |}]

    let opened = ref []

    let watched () =
      let log = ref [] in
      let add fmt = Printf.ksprintf (fun line -> log := line :: !log) fmt in
      let result = function Ok () -> "ok" | Stdlib.Error message -> message in
      let t =
        fake
          ~notify:(fun event ->
            add "%s"
              (match event with
              | Title -> "title"
              | Pwd -> "pwd"
              | Output -> "output"
              | Dead _ -> "dead"))
          ()
      in
      Pane_core.note_snapshot t.core
        {
          req = 1;
          consume = (fun pos -> add "slice %d" pos);
          finish = (fun ok -> add "snapshot %s" (result (if ok then Ok () else Stdlib.Error ended)));
        };
      Hashtbl.add t.pending 2
        (Paste_reply
           (function
           | Ok { pasted; unsafe } -> add "paste %b %b" pasted unsafe
           | Stdlib.Error message -> add "paste %s" message));
      Hashtbl.add t.pending 3
        (Screen_reply
           ((fun text ~last -> add "chunk %S %b" text last), fun r -> add "screen %s" (result r)));
      opened := t :: !opened;
      ( t,
        fun () ->
          ( List.rev !log,
            title t,
            cwd t,
            Option.map (fun (d : Protocol.dead) -> d.cause) t.dead,
            child_pid t ) )

    let release () =
      List.iter (fun t -> if is_open t then close_control t) !opened;
      opened := []

    let drive ~fill (t, observe) chunks =
      let raised =
        try
          List.iter
            (fun data ->
              let after = t.filled + String.length data in
              Bigarray.Array1.fill
                (Bigarray.Array1.sub t.input after (Bigstringaf.length t.input - after))
                fill;
              feed t data)
            chunks;
          None
        with Invalid_argument message ->
          failure t message;
          Some message
      in
      (raised, observe ())

    let ready_frame pid =
      let b = Buffer.create 4 in
      Buffer.add_int32_le b (Int32.of_int pid);
      frame Ready (Buffer.contents b)

    let%expect_test "a Ready frame with a foreign pid fails the pane and records no child" =
      List.iter
        (fun (label, pid, child) ->
          let t = fake () in
          t.child <- child;
          (try feed t (ready_frame pid)
           with Invalid_argument message -> Printf.printf "%s: %s, " label message);
          failure t "invalid ready";
          Printf.printf "child %b, dead %b\n" (Option.is_some (child_pid t)) (Option.is_some t.dead))
        [
          ("1", 1, Awaiting);
          ("parent", Unix.getppid (), Awaiting);
          ("after gone", Unix.getppid (), Reported None);
        ];
      [%expect
        {|
        1: invalid ready, child false, dead true
        parent: invalid ready, child false, dead true
        after gone: invalid ready, child false, dead true
      |}]

    let%test "control frames give the documented effects and read only their own bytes" =
      let documented =
        [
          "short pane frame";
          "invalid pane string";
          "invalid dead";
          "invalid control frame length";
          "unknown pane frame";
        ]
      in
      let ids = [| ""; "\001\000\000\000"; "\002\000\000\000"; "\003\000\000\000" |] in
      let bytes l = String.of_list (List.map Char.chr l) in
      let wire_frame code id body =
        frame_code (if code = to_int Ready then to_int Head else code) (ids.(id) ^ bytes body)
      in
      let open Monolith in
      let pane = declare_abstract_type () in
      let body = list (closed_interval 0 255) in
      declare "create" (unit ^> pane) ignore (fun () -> (watched (), watched ()));
      declare "feed_frame"
        (pane ^> closed_interval 0 255 ^> closed_interval 0 3 ^> body ^> closed_interval 0 40
       ^!?> unit)
        (fun () _ _ _ _ result ->
          match result with
          | Ok () -> Valid (Ok ())
          | Error (Invalid_argument message as e) when List.mem ~eq:String.equal message documented
            ->
              Valid (Error e)
          | Error _ -> Invalid (fun _ -> Print.comment (PPrint.string "undocumented exception")))
        (fun (whole, split) code id body cut ->
          let data = wire_frame code id body in
          let cut = min cut (String.length data) in
          let a = drive ~fill:'\000' whole [ data ]
          and b =
            drive ~fill:'\255' split
              [ String.sub data 0 cut; String.sub data cut (String.length data - cut) ]
          in
          if Stdlib.( <> ) a b then
            failwith "a split frame or the bytes after it change the effects";
          match fst a with Some message -> invalid_arg message | None -> ());
      let tail =
        pair (triple (closed_interval 0 255) (closed_interval 0 255) (closed_interval 1 255)) body
      in
      declare "tails"
        (closed_interval 0 255 ^> closed_interval 0 3 ^> body ^> tail ^> tail ^> unit)
        (fun _ _ _ _ _ -> ())
        (fun code id body a b ->
          let after ((x, y, z), rest) = bytes ([ x; y; z; 0 ] @ rest) in
          let outcome tail =
            drive ~fill:'\000' (watched ()) [ wire_frame code id body ^ after tail ]
          in
          let ((raised, _) as first) = outcome a in
          assert (Stdlib.( = ) first (outcome b));
          assert (not (Option.equal String.equal raised (Some "index out of bounds"))));
      Fuzz_run.monolith ~prologue:release ~fuel:40 ()
  end)

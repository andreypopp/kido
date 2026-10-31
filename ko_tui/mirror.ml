type surface = Empty | Full of Ko_vt.t | Partial of Ko_vt.t | Loading_history of Ko_vt.t * int
type drawn = Fresh | Output of int | Held of int
type following = Bytes of string | Marker of Ko_server.Protocol.marker

type t = {
  wire : Wire.t;
  lock : Mutex.t;
  mutable surface : surface;
  mutable generation : int;
  mutable drawn : drawn;
  mutable error : string option;
  mutable closed : bool;
  mutable thread : Thread.t option;
  wake : Condition.t;
  nudge : Unix.file_descr * Unix.file_descr;
  mutable compressor : Thread.t option;
}

exception Restart of string

let terminal = function Empty -> None | Full vt | Partial vt | Loading_history (vt, _) -> Some vt
let send t json = Wire.send t.wire json
let error t = Mutex.protect t.lock (fun () -> t.error)

let to_bottom t =
  let moved = Option.exists Ko_vt.bottom (terminal t.surface) in
  match t.surface with
  | Loading_history (vt, delta) ->
      t.surface <- Loading_history (vt, 0);
      moved || delta <> 0
  | _ -> moved

let bottom t =
  Mutex.protect t.lock (fun () ->
      if to_bottom t then (
        t.generation <- t.generation + 1;
        Condition.broadcast t.wake))

let scroll t delta =
  let resync =
    Mutex.protect t.lock (fun () ->
        t.generation <- t.generation + 1;
        Condition.broadcast t.wake;
        match t.surface with
        | Empty -> false
        | Full vt ->
            Ko_vt.scroll vt delta;
            false
        | Partial vt ->
            t.surface <- Loading_history (vt, delta);
            true
        | Loading_history (vt, pending) ->
            t.surface <- Loading_history (vt, pending + delta);
            false)
  in
  if resync then
    Wire.send t.wire
      (Ko_server.Protocol.Request.view_to_json
         (Resync { history = History_all; images = Images_none }))

let delay t =
  Mutex.protect t.lock (fun () ->
      Option.flat_map
        (fun vt ->
          let delay = Ko_vt.render_delay vt in
          if Float.(delay > 0.) then Some delay else None)
        (terminal t.surface))

let frame t =
  Mutex.protect t.lock (fun () ->
      match terminal t.surface with
      | None -> None
      | Some vt ->
          let next =
            if Float.(Ko_vt.render_delay vt > 0.) then Held (Ko_vt.hold_id vt)
            else Output t.generation
          in
          let same =
            match (t.drawn, next) with
            | Held a, Held b | Output a, Output b -> Int.equal a b
            | _ -> false
          in
          if same then None
          else (
            t.drawn <- next;
            Some (Ko_vt.render vt)))

let compress_loop t =
  Mutex.protect t.lock (fun () ->
      while not t.closed do
        match terminal t.surface with
        | None -> Condition.wait t.wake t.lock
        | Some vt ->
            let began = Ko_vt.now_ns () in
            let rec burst () =
              let now = Ko_vt.now_ns () in
              let next = Ko_vt.compress_tick vt ~now_ns:now in
              if next = 0 && now - began < 1_000_000 then burst () else next
            in
            let next = burst () in
            if next < 0 then Condition.wait t.wake t.lock
            else (
              Mutex.unlock t.lock;
              (try
                 ignore
                   (Unix.select
                      [ fst t.nudge ]
                      [] []
                      (if next = 0 then 0.0005 else float_of_int next /. 1000.))
               with Unix.Unix_error (Unix.EINTR, _, _) -> ());
              Mutex.lock t.lock)
      done)

let close t =
  Mutex.protect t.lock (fun () ->
      t.closed <- true;
      Condition.broadcast t.wake);
  ignore (Unix.write_substring (snd t.nudge) "x" 0 1);
  Wire.close t.wire;
  Option.iter Thread.join t.thread;
  Option.iter Thread.join t.compressor;
  Unix.close (fst t.nudge);
  Unix.close (snd t.nudge);
  Mutex.protect t.lock (fun () ->
      Option.iter Ko_vt.close (terminal t.surface);
      t.surface <- Empty)

let open_view ~socket ~client ~(pane : Ko_server.Ids.Pane_id.t) ~(limits : Ko_server.Config.limits)
    ~notify =
  let wire = Wire.of_fd (Launch.connect ~socket ~deadline:(Unix.gettimeofday () +. 5.)) in
  try
    Wire.upgrade wire ~client
      ~route:(View (pane, { history = History_all; images = Images_none }, None))
      ();
    let t =
      {
        wire;
        lock = Mutex.create ();
        surface = Empty;
        generation = 0;
        drawn = Fresh;
        error = None;
        closed = false;
        thread = None;
        wake = Condition.create ();
        nudge = Unix.pipe ~cloexec:true ();
        compressor = None;
      }
    in
    let update f =
      Mutex.protect t.lock (fun () ->
          f ();
          t.generation <- t.generation + 1;
          Condition.broadcast t.wake);
      notify ()
    in
    let window = ref (Unix.gettimeofday ()) and work = ref 0. in
    let budget duration =
      let now = Unix.gettimeofday () in
      if Float.(now -. !window >= 0.008) then (
        window := now;
        work := 0.);
      work := !work +. duration;
      if Float.(!work >= 0.004) then (
        let left = !window +. 0.008 -. now in
        if Float.(left > 0.) then Thread.delay left;
        window := Unix.gettimeofday ();
        work := 0.)
    in
    let kind s =
      try Ko_server.Protocol.Record.kind_of_string s
      with Invalid_argument message -> raise (Wire.Error message)
    in
    let data_start = Ko_server.Protocol.Record.(header_size + slice_size) in
    let slice s =
      if String.length s < data_start then raise (Wire.Error "short snapshot slice")
      else Ko_server.Protocol.Record.slice_of_string s Ko_server.Protocol.Record.header_size
    in
    let marker text =
      match Ko_server.Protocol.Event.view_of_json (Yojson.Basic.from_string text) with
      | Marked { marker; _ } -> Some marker
      | Skipped _ | Pasted _ -> None
    in
    let apply vt = function
      | Ko_server.Protocol.Resize size -> Ko_vt.resize vt ~cols:size.cols ~rows:size.rows
      | Dead _ -> ()
    in
    let feed s write =
      let rec loop off =
        if off < String.length s && not t.closed then (
          let len = min 16384 (String.length s - off) and began = Unix.gettimeofday () in
          write off len;
          budget (Unix.gettimeofday () -. began);
          loop (off + len))
      in
      loop Ko_server.Protocol.Record.header_size
    in
    let rec snapshot s =
      let first = slice s in
      if not first.first then raise (Wire.Error "snapshot missing first slice");
      let full = not first.screen in
      let piece = ref s and pos = ref data_start and last = ref first.last and following = ref [] in
      let rec read capacity =
        let count = min capacity (String.length !piece - !pos) in
        if count > 0 then (
          let bytes = String.sub !piece !pos count in
          pos := !pos + count;
          bytes)
        else if !last || t.closed then ""
        else
          match Wire.receive wire with
          | `Binary next -> (
              match kind next with
              | Snapshot ->
                  let continuation = slice next in
                  if continuation.first then raise (Restart next);
                  piece := next;
                  pos := data_start;
                  last := continuation.last;
                  read capacity
              | Output ->
                  following := Bytes next :: !following;
                  bottom t;
                  notify ();
                  read capacity)
          | `Text text ->
              Option.iter (fun m -> following := Marker m :: !following) (marker text);
              read capacity
          | _ -> raise (Wire.Error "snapshot interrupted")
      in
      try
        let ready bytes =
          let screen = Ko_vt.decode_string ~full:false bytes in
          update (fun () ->
              let pending = match t.surface with Loading_history (_, delta) -> delta | _ -> 0 in
              Option.iter Ko_vt.close (terminal t.surface);
              t.surface <- Loading_history (screen, pending);
              t.drawn <- Fresh)
        in
        let vt = Ko_vt.decode ~ready read ~full in
        let owned = ref true in
        Fun.protect
          ~finally:(fun () -> if !owned then Ko_vt.close vt)
          (fun () ->
            Ko_vt.configure vt ~limits:limits.terminal;
            while (not !last) || !pos < String.length !piece do
              ignore (read 65536)
            done;
            List.iter
              (function
                | Marker m -> if full then apply vt m
                | Bytes s ->
                    ignore (Ko_vt.bottom vt);
                    feed s (fun off len -> Ko_vt.write vt ~off ~len s))
              (List.rev !following);
            update (fun () ->
                let next =
                  match (full, t.surface) with
                  | true, Loading_history (_, delta) ->
                      Ko_vt.scroll vt delta;
                      Full vt
                  | true, _ -> Full vt
                  | false, Loading_history (_, delta) -> Loading_history (vt, delta)
                  | false, _ -> Partial vt
                in
                Option.iter Ko_vt.close (terminal t.surface);
                t.surface <- next;
                t.drawn <- Fresh;
                owned := false))
      with Restart next -> snapshot next
    in
    let rec run () =
      match Wire.receive wire with
      | `Close -> if not t.closed then raise (Wire.Error "pane view closed")
      | `Text text ->
          Option.iter
            (fun m -> update (fun () -> match t.surface with Full vt -> apply vt m | _ -> ()))
            (marker text);
          run ()
      | `Binary s ->
          (match kind s with
          | Ko_server.Protocol.Record.Output ->
              feed s (fun off len ->
                  update (fun () ->
                      ignore (to_bottom t);
                      Option.iter (fun vt -> Ko_vt.write vt ~off ~len s) (terminal t.surface)))
          | Snapshot -> snapshot s);
          run ()
    in
    t.thread <-
      Some
        (Thread.create
           (fun () ->
             try run ()
             with e ->
               if not t.closed then update (fun () -> t.error <- Some (Printexc.to_string e)))
           ());
    t.compressor <- Some (Thread.create compress_loop t);
    t
  with e ->
    Wire.close wire;
    raise e

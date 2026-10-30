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

let bottom t = Mutex.protect t.lock (fun () -> if to_bottom t then t.generation <- t.generation + 1)

let scroll t delta =
  let resync =
    Mutex.protect t.lock (fun () ->
        t.generation <- t.generation + 1;
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
      (Ko_server.Protocol.yojson_of_resync { resync = { history = "all"; images = "none" } })

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

let close t =
  t.closed <- true;
  Wire.close t.wire;
  Option.iter Thread.join t.thread;
  Mutex.protect t.lock (fun () ->
      Option.iter Ko_vt.close (terminal t.surface);
      t.surface <- Empty)

let open_view ~socket ~client ~pane ~(limits : Ko_server.Config.limits) ~notify =
  let wire = Wire.of_fd (Ko_server.Socket.connect ~socket ~deadline:(Unix.gettimeofday () +. 5.)) in
  try
    Wire.upgrade wire ~client ~path:("/panes/" ^ pane ^ "/view?history=all&images=none") ();
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
      }
    in
    let update f =
      Mutex.protect t.lock (fun () ->
          f ();
          t.generation <- t.generation + 1);
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
    let binary s =
      if String.length s < 9 then raise (Wire.Error "short view record") else Char.code s.[0]
    in
    let marker text =
      let json = Yojson.Safe.from_string text in
      match json with
      | `Assoc fields when List.mem_assoc ~eq:String.equal "marker" fields ->
          Some (Ko_server.Protocol.marked_of_yojson json).marker
      | _ -> None
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
      loop 9
    in
    let rec snapshot s =
      if String.length s < 11 || Char.code s.[9] land 1 = 0 then
        raise (Wire.Error "snapshot missing first slice");
      let full = Char.code s.[10] = 0 in
      let piece = ref s
      and pos = ref 11
      and last = ref (Char.code s.[9] land 2 <> 0)
      and following = ref [] in
      let rec read capacity =
        let count = min capacity (String.length !piece - !pos) in
        if count > 0 then (
          let bytes = String.sub !piece !pos count in
          pos := !pos + count;
          bytes)
        else if !last || t.closed then ""
        else
          match Wire.receive wire with
          | `Binary next when binary next = 2 && String.length next >= 11 ->
              if Char.code next.[9] land 1 <> 0 then raise (Restart next);
              piece := next;
              pos := 11;
              last := Char.code next.[9] land 2 <> 0;
              read capacity
          | `Text text ->
              Option.iter (fun m -> following := Marker m :: !following) (marker text);
              read capacity
          | `Binary next when binary next = 1 ->
              following := Bytes next :: !following;
              bottom t;
              notify ();
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
            Ko_vt.configure vt ~scrollback_max_bytes:limits.scrollback_max_bytes
              ~apc_max_bytes:limits.apc_max_bytes
              ~kitty_image_storage_limit:limits.kitty_image_storage_limit
              ~continuation_max_bytes:limits.continuation_max_bytes;
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
          (match binary s with
          | 1 ->
              feed s (fun off len ->
                  update (fun () ->
                      ignore (to_bottom t);
                      Option.iter (fun vt -> Ko_vt.write vt ~off ~len s) (terminal t.surface)))
          | 2 -> snapshot s
          | _ -> raise (Wire.Error "unknown view record"));
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
    t
  with e ->
    Wire.close wire;
    raise e

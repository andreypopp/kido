module P = Tmux.Pane

let grace () =
  match Option.flat_map Int.of_string (Sys.getenv_opt "KIDO_LINGER_SECONDS") with
  | Some n when n > 0 -> Float.of_int n
  | _ -> 30.

type close = Window of string | Pane of { window : string; pane : string }

let release ?socket = function
  | Window w -> Tmux.Exec.kill_window ?socket w
  | Pane { pane; _ } -> Tmux.Exec.kill_pane ?socket pane

let close_of panes window pane =
  if not (P.last_pane panes window) then Some (Pane { window; pane })
  else if P.last_window panes window then None
  else Some (Window window)

let decide panes window_id =
  if P.window_focused panes window_id then
    Error
      (Printf.sprintf "%s is a client's current window; leaving it for the user to read" window_id)
  else
    match P.run_pane panes window_id with
    | None -> Error (Printf.sprintf "%s has no run pane; leaving it" window_id)
    | Some { dead_at = None; _ } ->
        Error (Printf.sprintf "%s's run is still going; leaving it" window_id)
    | Some run ->
        Option.to_result
          (Printf.sprintf "%s is its session's only window; closing it would destroy the session"
             window_id)
          (close_of panes window_id run.pane_id)

type detail = Bash | Streamed of { unstreamed : int } | Agent of { unreported : bool }
type ending = { meta : Subrun.meta; outcome : Subrun.outcome; detail : detail }

let quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
          Buffer.add_string b (Printf.sprintf "\\x%02x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let body ~dir e =
  let b = Buffer.create 256 in
  let result = Subrun.string_of_result e.outcome.result in
  (match e.detail with
  | (Bash | Streamed _) as detail -> (
      let output = Subrun.output_path ~dir e.meta.id in
      Printf.bprintf b "async run %s %s: %s\n" (quote (Subrun.label e.meta)) result e.outcome.text;
      Printf.bprintf b "run: %s\n" (Subrun.string_of_id e.meta.id);
      Printf.bprintf b "output: %s\n" output;
      match detail with
      | Streamed { unstreamed } ->
          if unstreamed > 0 then
            Printf.bprintf b "%d lines not streamed (the output file above has every one)\n"
              unstreamed
      | _ -> (
          let cap = Msg.max_notice_bytes in
          match
            let ic = open_in_bin output in
            Fun.protect
              ~finally:(fun () -> close_in ic)
              (fun () ->
                let size = in_channel_length ic in
                let omitted = if size > cap then size - cap else 0 in
                seek_in ic omitted;
                let b = really_input_string ic (size - omitted) in
                let skip =
                  if omitted > 0 then String.drop_while (fun c -> Char.code c land 0xC0 = 0x80) b
                  else b
                in
                (Msg.valid_utf_8 skip, omitted + String.length b - String.length skip))
          with
          | exception Sys_error err -> Printf.bprintf b "--- output unreadable: %s ---" err
          | "", _ -> Buffer.add_string b "--- no output ---"
          | tail, omitted when omitted > 0 ->
              Printf.bprintf b "--- last %d bytes of output (%d omitted) ---\n%s"
                (String.length tail) omitted tail
          | tail, _ -> Printf.bprintf b "--- output ---\n%s" tail))
  | Agent { unreported } ->
      if unreported then
        Printf.bprintf b
          "subagent %s %s without reporting: it never called notify_parent, so this is the whole \
           account of it\n"
          (quote (Subrun.label e.meta))
          result
      else
        Printf.bprintf b
          "subagent %s ended without recording an outcome of its own, so kido recorded it as %s; \
           whether it called notify_parent is not known, and any report it sent stands\n"
          (quote (Subrun.label e.meta))
          result;
      if not (String.is_empty e.outcome.text) then Printf.bprintf b "detail: %s\n" e.outcome.text;
      Printf.bprintf b "run: %s\n" (Subrun.string_of_id e.meta.id);
      Printf.bprintf b "resume: spawn_subagent(resume: %s)\n"
        (quote (Subrun.string_of_id e.meta.id)));
  Buffer.contents b

let send ~dir e =
  if String.is_empty e.meta.parent_session then Ok ()
  else
    Msg.notify ~dir ~parent_session:e.meta.parent_session
      ~from:{ session = ""; name = Subrun.label e.meta; pane = "" }
      (body ~dir e)

let record_ending ~dir (meta : Subrun.meta) outcome =
  if not (Subrun.record_outcome ~dir meta.id outcome) then None
  else
    let detail =
      match meta.kind with Subrun.Bash | Stream -> Bash | Agent -> Agent { unreported = false }
    in
    Some { meta; outcome; detail }

let sweep ?socket ~dir ~grace panes sessions ~now =
  let mark ?(text = "ended without its wrapper reporting") ((closing, endings) as acc) (p : P.t) =
    let window = p.window_id in
    let closes = function Window w | Pane { window = w; _ } -> String.equal w window in
    match P.run_pane panes window with
    | Some { run = Some run; _ }
      when not (P.window_focused panes window || List.exists closes closing) -> (
        match (close_of panes window p.pane_id, Subrun.parse_id run) with
        | Some close, Ok run_id ->
            let ending =
              Option.flat_map
                (fun (m : Subrun.meta) ->
                  if not (String.equal m.pane p.pane_id) then None
                  else begin
                    ignore (Subrun.save_screen ?socket ~dir run_id p.pane_id);
                    record_ending ~dir m
                      (match m.kind with
                      | Bash | Stream -> { result = Failed; text; at = Some now }
                      | Agent -> { result = Died; text = ""; at = Some now })
                  end)
                (Subrun.read_meta ~dir run_id)
            in
            (closing @ [ close ], endings @ Option.to_list ending)
        | _ -> acc)
    | _ -> acc
  in
  let acc =
    List.fold_left
      (fun acc (p : P.t) ->
        match p with
        | { run = Some _; dead_at = Some d; _ }
          when Float.(now - d >= grace)
               && Option.exists
                    (fun (r : P.t) -> String.equal r.pane_id p.pane_id)
                    (P.run_pane panes p.window_id) ->
            mark acc p
        | _ -> acc)
      ([], []) panes
  in
  let acc =
    List.fold_left
      (fun acc (_, (s : State.session)) ->
        match s.parent with
        | Some parent when not (List.mem_assoc ~eq:String.equal parent.session sessions) ->
            Option.map_or ~default:acc (mark acc) (P.find panes s.pane)
        | _ -> acc)
      acc sessions
  in
  List.fold_left
    (fun acc (p : P.t) ->
      match
        Option.flat_map
          (fun run ->
            Result.to_opt (Subrun.parse_id run) |> Option.flat_map (Subrun.read_meta ~dir))
          p.run
      with
      | Some { kind = Bash | Stream; parent_session; pane; _ }
        when String.equal pane p.pane_id
             && (not (String.is_empty parent_session))
             && not (List.mem_assoc ~eq:String.equal parent_session sessions) ->
          mark ~text:"its parent ended" acc p
      | _ -> acc)
    acc panes

let collect ?socket ~dir ~grace panes sessions ~now =
  let closing, endings = sweep ?socket ~dir ~grace panes sessions ~now in
  List.iter (fun c -> ignore (release ?socket c)) closing;
  List.iter (fun e -> ignore (send ~dir e)) endings

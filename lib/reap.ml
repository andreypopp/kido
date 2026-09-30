module P = Tmux.Pane

let runs dir = Filename.concat dir "runs"

let grace () =
  match Option.flat_map Int.of_string (Sys.getenv_opt "KIDO_LINGER_SECONDS") with
  | Some n when n > 0 -> Float.of_int n
  | _ -> 30.

type close = { window_id : string; pane_id : string option }

type ops = {
  kill_window : string -> (unit, string) result;
  kill_pane : string -> (unit, string) result;
}

let release ops c =
  match c.pane_id with None -> ops.kill_window c.window_id | Some p -> ops.kill_pane p

let decide panes window_id =
  if P.window_focused panes window_id then
    Error
      (Printf.sprintf "%s is a client's current window; leaving it for the user to read" window_id)
  else
    match P.run_pane panes window_id with
    | Some { dead_at = None; _ } ->
        Error (Printf.sprintf "%s's run is still going; leaving it" window_id)
    | Some run when not (P.last_pane panes window_id) ->
        Ok { window_id; pane_id = Some run.pane_id }
    | None -> Error (Printf.sprintf "%s has no run pane; leaving it" window_id)
    | Some _ when P.last_window panes window_id ->
        Error
          (Printf.sprintf "%s is its session's only window; closing it would destroy the session"
             window_id)
    | Some _ -> Ok { window_id; pane_id = None }

type detail = Bash of { unstreamed : int } | Agent of { unreported : bool }
type ending = { meta : Subrun.meta; outcome : Subrun.outcome; detail : detail }

let label e = if String.is_empty e.meta.name then Subrun.string_of_id e.meta.id else e.meta.name

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

let max_notice_tail_bytes = 4000

let valid_utf8 s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let n = Uchar.utf_decode_length d in
      if Uchar.utf_decode_is_valid d then Buffer.add_substring b s i n
      else Buffer.add_string b "\u{FFFD}";
      go (i + n)
    end
  in
  go 0;
  Buffer.contents b

let tail_of_file path max =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let size = in_channel_length ic in
      let omitted = if size > max then size - max else 0 in
      seek_in ic omitted;
      let b = really_input_string ic (size - omitted) in
      let skip =
        if omitted > 0 then String.drop_while (fun c -> Char.code c land 0xC0 = 0x80) b else b
      in
      (valid_utf8 skip, omitted + String.length b - String.length skip))

let body ~dir e =
  let b = Buffer.create 256 in
  let result = Subrun.string_of_result e.outcome.result in
  (match e.detail with
  | Bash { unstreamed } -> (
      let output = Subrun.output_path ~dir:(runs dir) e.meta.id in
      Printf.bprintf b "async run %s %s: %s\n" (quote (label e)) result e.outcome.text;
      Printf.bprintf b "run: %s\n" (Subrun.string_of_id e.meta.id);
      Printf.bprintf b "output: %s\n" output;
      if unstreamed > 0 then
        Printf.bprintf b "%d lines not streamed (the output file above has every one)\n" unstreamed;
      match tail_of_file output max_notice_tail_bytes with
      | exception Sys_error err -> Printf.bprintf b "--- output unreadable: %s ---" err
      | "", _ -> Buffer.add_string b "--- no output ---"
      | tail, omitted when omitted > 0 ->
          Printf.bprintf b "--- last %d bytes of output (%d omitted) ---\n%s" (String.length tail)
            omitted tail
      | tail, _ -> Printf.bprintf b "--- output ---\n%s" tail)
  | Agent { unreported } ->
      if unreported then
        Printf.bprintf b
          "subagent %s %s without reporting: it never called notify_parent, so this is the whole \
           account of it\n"
          (quote (label e))
          result
      else
        Printf.bprintf b
          "subagent %s ended without recording an outcome of its own, so kido recorded it as %s; \
           whether it called notify_parent is not known, and any report it sent stands\n"
          (quote (label e))
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
      ~from:{ session = ""; name = label e; pane = "" }
      (body ~dir e)

let record_ending ~dir (meta : Subrun.meta) outcome =
  if
    (not (Subrun.record_outcome ~dir:(runs dir) meta.id outcome))
    || String.is_empty meta.parent_session
  then None
  else
    let detail =
      match meta.kind with
      | Some Bash -> Bash { unstreamed = 0 }
      | Some Agent | None -> Agent { unreported = false }
    in
    Some { meta; outcome; detail }

let capture_screen ~dir ~capture run_id pane_ids =
  let b = Buffer.create 1024 in
  List.iter
    (fun pane ->
      match capture pane with
      | None -> ()
      | Some text ->
          if List.length pane_ids > 1 then begin
            if Buffer.length b > 0 then Buffer.add_char b '\n';
            Buffer.add_string b ("=== " ^ pane ^ " ===\n")
          end;
          Buffer.add_string b text)
    pane_ids;
  let data = Subrun.truncate_screen (Buffer.contents b) in
  if not (String.is_empty data) then
    try Subrun.write_screen ~dir:(runs dir) run_id data with Unix.Unix_error _ | Sys_error _ -> ()

let guess_ending ~dir run_id ~now =
  let meta =
    match Subrun.read_meta ~dir:(runs dir) run_id with
    | Some m -> m
    | None ->
        {
          Subrun.id = run_id;
          name = "";
          kind = None;
          parent_session = "";
          depth = 0;
          pane = "";
          pid = 0;
          cwd = "";
          model = "";
          tools = [];
          keep_alive = false;
          started_at = now;
        }
  in
  let outcome : Subrun.outcome =
    match meta.kind with
    | Some Bash -> { result = Failed; text = "ended without its wrapper reporting"; at = Some now }
    | Some Agent | None -> { result = Died; text = ""; at = Some now }
  in
  record_ending ~dir meta outcome

type window = { id : string; pane_ids : string list; run : (P.t * string) option; focused : bool }

let fold_windows panes =
  List.fold_left
    (fun acc (p : P.t) ->
      let w, rest =
        match List.partition (fun w -> String.equal w.id p.window_id) acc with
        | [ w ], rest -> (w, rest)
        | _ -> ({ id = p.window_id; pane_ids = []; run = None; focused = false }, acc)
      in
      let w =
        {
          w with
          pane_ids = w.pane_ids @ [ p.pane_id ];
          run = Option.or_ ~else_:(Option.map (fun r -> (p, r)) p.run) w.run;
          focused = w.focused || P.watched p;
        }
      in
      rest @ [ w ])
    [] panes

let sweep ~dir ~capture ~grace panes sessions ~now =
  if not (List.exists (fun (p : P.t) -> Option.is_some p.run) panes) then ([], [])
  else
    let windows = fold_windows panes in
    let mark ((closing, endings) as acc) id pane_id =
      match List.find_opt (fun w -> String.equal w.id id) windows with
      | Some { run = Some (_, run); focused = false; pane_ids; _ }
        when not (List.exists (fun c -> String.equal c.window_id id) closing) -> (
          let pane_id = match pane_ids with [ _ ] -> None | _ -> Some pane_id in
          match (pane_id, Subrun.parse_id run) with
          | None, _ when P.last_window panes id -> acc
          | _, Error _ -> acc
          | _, Ok run_id ->
              capture_screen ~dir ~capture run_id
                (Option.map_or ~default:pane_ids (fun p -> [ p ]) pane_id);
              ( closing @ [ { window_id = id; pane_id } ],
                endings @ Option.to_list (guess_ending ~dir run_id ~now) ))
      | _ -> acc
    in
    let acc =
      List.fold_left
        (fun acc w ->
          match w.run with
          | Some ({ dead_at = Some d; pane_id; _ }, _) when Float.(now - d >= grace) ->
              mark acc w.id pane_id
          | _ -> acc)
        ([], []) windows
    in
    let live =
      List.filter_map
        (fun (id, (s : State.session)) -> if State.alive s.pid then Some id else None)
        sessions
    in
    let live id = List.mem ~eq:String.equal id live in
    List.fold_left
      (fun acc (id, (s : State.session)) ->
        match s.parent with
        | Some parent when live id && not (live parent.session) ->
            Option.map_or ~default:acc
              (fun (p : P.t) -> mark acc p.window_id s.pane)
              (List.find_opt (fun (p : P.t) -> String.equal p.pane_id s.pane) panes)
        | _ -> acc)
      acc sessions

let collect ~dir ~capture ~grace panes sessions ~now ops =
  let closing, endings = sweep ~dir ~capture ~grace panes sessions ~now in
  List.iter (fun c -> ignore (release ops c)) closing;
  List.iter (fun e -> ignore (send ~dir e)) endings

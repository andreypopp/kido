let run_outcome_usage =
  "usage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>"

type info = { meta : Subrun.meta; outcome : Subrun.outcome option }

let info_to_yojson ?(extra = []) { meta; outcome } =
  match Subrun.meta_to_yojson meta with
  | `Assoc fields ->
      `Assoc
        (fields
        @ Option.map_or ~default:[] (fun o -> [ ("outcome", Subrun.outcome_to_yojson o) ]) outcome
        @ extra)
  | json -> json

let load ~dir id =
  Option.map
    (fun (meta : Subrun.meta) -> { meta; outcome = Subrun.effective_outcome ~dir id ~pid:meta.pid })
    (Subrun.read_meta ~dir id)

let seconds t = Timestamp.to_local_string (Float.of_int (Float.to_int t))

let list ~dir =
  List.filter_map (load ~dir) (Subrun.list ~dir)
  |> List.sort (fun a b -> Float.compare b.meta.started_at a.meta.started_at)

let table ~now infos =
  [ "ID"; "NAME"; "PARENT"; "STARTED"; "DURATION"; "OUTCOME"; "CWD" ]
  :: List.map
       (fun { meta = m; outcome } ->
         let outcome, duration =
           match outcome with
           | None -> ("running", Some now)
           | Some o -> (Subrun.string_of_result o.result, o.at)
         in
         [
           Subrun.string_of_id m.id;
           m.name;
           m.parent_session;
           seconds m.started_at;
           Option.map_or ~default:"-"
             (fun t -> Timestamp.duration (Float.round (t -. m.started_at)))
             duration;
           outcome;
           m.cwd;
         ])
       infos

let show ~dir ~json id_str =
  let open Result.Infix in
  let* id = Subrun.parse_id id_str in
  let+ info = Option.to_result (Printf.sprintf "run %S: no such run" id_str) (load ~dir id) in
  let m = info.meta in
  let task = Option.get_or ~default:"" (Subrun.read_task ~dir id) in
  let screen = Subrun.read_screen ~dir id in
  let cd = "cd " ^ Filename.quote m.cwd ^ " && " in
  let resume = cd ^ "kido spawn_subagent --resume " ^ id_str in
  let fork = cd ^ "pi --fork " ^ id_str in
  if json then
    Yojson.Safe.to_string
      (info_to_yojson info
         ~extra:
           ([ ("task", `String task); ("resume", `String resume); ("fork", `String fork) ]
           @ Option.map_or ~default:[] (fun s -> [ ("screen", `String s) ]) screen))
    ^ "\n"
  else begin
    let b = Buffer.create 1024 in
    let line k v = Printf.bprintf b "%-10s%s\n" (k ^ ":") v in
    line "id" id_str;
    line "name" m.name;
    line "kind" (Option.map_or ~default:"" Subrun.string_of_kind m.kind);
    line "parent" m.parent_session;
    line "depth" (string_of_int m.depth);
    line "cwd" m.cwd;
    if not (String.is_empty m.model) then line "model" m.model;
    if not (List.is_empty m.tools) then line "tools" ("[" ^ String.concat " " m.tools ^ "]");
    if m.keep_alive then Buffer.add_string b "keepAlive: true\n";
    line "started" (seconds m.started_at);
    (match info.outcome with
    | None -> line "outcome" "running"
    | Some o ->
        line "outcome" (Subrun.string_of_result o.result);
        Option.iter (fun at -> line "ended" (seconds at)) o.at;
        if not (String.is_empty o.text) then line "detail" o.text);
    if Subrun.has_report ~dir id then line "report" (Subrun.report_path ~dir id);
    line "resume" resume;
    line "fork" fork;
    Printf.bprintf b "task:\n%s\n" task;
    Option.iter (Printf.bprintf b "screen:\n%s\n") screen;
    Buffer.contents b
  end

(* pi prints this and exits 0 when it cannot resolve a provider for the model it was given: the one
   line that names why no turn ever ran. Matched by substring, since it is pi's wording. *)
let login_line = "Use /login to log into a provider via OAuth or API key"

let refine_no_turn_detail text screen =
  if String.mem ~sub:"no turn ever ran" text && String.mem ~sub:login_line screen then
    Printf.sprintf "%s (the pane showed: \"%s\")" text login_line
  else text

let run_outcome ~dir ~capture ~warn ~result ~text ~unreported id_str =
  let open Result.Infix in
  let* result =
    match result with
    | "completed" -> Ok Subrun.Completed
    | "failed" -> Ok Subrun.Failed
    | _ ->
        Error (Printf.sprintf "--result must be \"completed\" or \"failed\"\n%s" run_outcome_usage)
  in
  let* id = Subrun.parse_id id_str in
  let meta = Subrun.read_meta ~dir id in
  let text =
    match (meta, result) with
    | Some m, Failed ->
        Option.map_or ~default:text (refine_no_turn_detail text)
          (Subrun.capture_own_screen ~dir ~capture id m.pane)
    | _ -> text
  in
  let outcome : Subrun.outcome = { result; text; at = Some (Timestamp.now ()) } in
  match meta with
  | Some meta when unreported ->
      Option.iter
        (fun (e : Reap.ending) ->
          Result.iter_err
            (fun err -> warn (Msg.string_of_error err))
            (Reap.send ~dir { e with detail = Agent { unreported = true } }))
        (Reap.record_ending ~dir meta outcome);
      Ok ()
  | _ ->
      if Subrun.record_outcome ~dir id outcome then Ok ()
      else Error (Printf.sprintf "run %s already has an outcome, or is gone" id_str)

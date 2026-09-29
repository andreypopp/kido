let fail fmt = Printf.ksprintf failwith fmt
let usage = "usage: kido runs [--json] [<run-id>]"

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

let load ~runs id =
  Option.map
    (fun (meta : Subrun.meta) ->
      { meta; outcome = Subrun.effective_outcome ~dir:runs id ~pid:meta.pid })
    (Subrun.read_meta ~dir:runs id)

(* Go's time.RFC3339: whole seconds. *)
let seconds t = Timestamp.to_string (Float.of_int (Float.to_int t))
let width s = String.fold (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1) 0 s

(* text/tabwriter with a padding of two: every column but the last as wide as its widest cell. *)
let print_table rows =
  let widths =
    List.fold_left
      (fun ws row -> List.map2 (fun w cell -> max w (width cell)) ws row)
      (List.map (fun _ -> 0) (List.hd rows))
      rows
  in
  List.iter
    (fun row ->
      let cells = List.combine row widths in
      let last = List.length cells - 1 in
      List.iteri
        (fun i (cell, w) ->
          print_string cell;
          if i < last then print_string (String.make (w - width cell + 2) ' '))
        cells;
      print_newline ())
    rows

let list ~runs ~json ~now =
  let infos =
    List.filter_map (load ~runs) (Subrun.list ~dir:runs)
    |> List.sort (fun a b -> Float.compare b.meta.started_at a.meta.started_at)
  in
  if json then print_endline (Yojson.Safe.to_string (`List (List.map info_to_yojson infos)))
  else
    print_table
      ([ "ID"; "NAME"; "PARENT"; "STARTED"; "DURATION"; "OUTCOME"; "CWD" ]
      :: List.map
           (fun { meta = m; outcome } ->
             (* A guessed died has no end time, and timing it against now would count a finished
                run's duration up. *)
             let outcome, duration =
               match outcome with
               | None -> ("running", Some now)
               | Some o -> (Reap.string_of_result o.result, o.at)
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
           infos)

let show ~runs ~json id_str =
  let id = Result.get_or_failwith (Subrun.parse_id id_str) in
  let info = match load ~runs id with Some i -> i | None -> fail "run %S: no such run" id_str in
  let m = info.meta in
  let task = Option.get_or ~default:"" (Subrun.read_task ~dir:runs id) in
  (* A screen exists only when something captured one before the run's window closed. *)
  let screen = Subrun.read_screen ~dir:runs id in
  (* A bare `pi --session <id>` comes back an orphan, with no parent edge and no run mark; `pi
     --fork` stays bare, since forking into a standalone session is a different, legitimate
     thing. *)
  let cd = "cd " ^ Tmux.Conn.quote m.cwd ^ " && " in
  let resume = cd ^ "kido spawn_subagent --resume " ^ id_str in
  let fork = cd ^ "pi --fork " ^ id_str in
  if json then
    print_endline
      (Yojson.Safe.to_string
         (info_to_yojson info
            ~extra:
              ([ ("task", `String task); ("resume", `String resume); ("fork", `String fork) ]
              @ Option.map_or ~default:[] (fun s -> [ ("screen", `String s) ]) screen)))
  else begin
    let line k v = Printf.printf "%-10s%s\n" (k ^ ":") v in
    line "id" id_str;
    line "name" m.name;
    line "kind" (Option.map_or ~default:"" Subrun.string_of_kind m.kind);
    line "parent" m.parent_session;
    line "depth" (string_of_int m.depth);
    line "cwd" m.cwd;
    if not (String.is_empty m.model) then line "model" m.model;
    if not (List.is_empty m.tools) then line "tools" ("[" ^ String.concat " " m.tools ^ "]");
    if m.keep_alive then print_endline "keepAlive: true";
    line "started" (seconds m.started_at);
    (match info.outcome with
    | None -> line "outcome" "running"
    | Some o ->
        line "outcome" (Reap.string_of_result o.result);
        Option.iter (fun at -> line "ended" (seconds at)) o.at;
        if not (String.is_empty o.text) then line "detail" o.text);
    if Subrun.has_report ~dir:runs id then line "report" (Subrun.report_path ~dir:runs id);
    line "resume" resume;
    line "fork" fork;
    Printf.printf "task:\n%s\n" task;
    Option.iter (Printf.printf "screen:\n%s\n") screen
  end

let runs ~dir ~json args =
  let runs = Filename.concat dir "runs" in
  (match args with
  | [] -> list ~runs ~json ~now:(Timestamp.now ())
  | [ id ] -> show ~runs ~json id
  | _ :: extra :: _ -> fail "unknown argument %S\n%s" extra usage);
  0

(* pi prints this and exits 0 when it cannot resolve a provider for the model it was given: the one
   line that names why no turn ever ran. Matched by substring, since it is pi's wording. *)
let login_line = "Use /login to log into a provider via OAuth or API key"

let refine_no_turn_detail text screen =
  if String.mem ~sub:"no turn ever ran" text && String.mem ~sub:login_line screen then
    Printf.sprintf "%s (the pane showed: \"%s\")" text login_line
  else text

(* died and stopped are kido's verdicts from the outside. A failing run captures its own pane
   first: this runs inside the child, whose pane is alive only until it exits. --unreported goes
   through the ending's own write, which decides who speaks: a run already spoken for (stopped, or
   swept) records and says nothing. *)
let run_outcome ~dir ~capture ~result ~text ~unreported id_str =
  let result : Subrun.result =
    match result with
    | "completed" -> Completed
    | "failed" -> Failed
    | _ -> fail "--result must be \"completed\" or \"failed\"\n%s" run_outcome_usage
  in
  let id = Result.get_or_failwith (Subrun.parse_id id_str) in
  let runs = Filename.concat dir "runs" in
  let meta = Subrun.read_meta ~dir:runs id in
  let text =
    match (meta, result) with
    | Some m, Failed ->
        Option.map_or ~default:text (refine_no_turn_detail text)
          (Reap.capture_own_screen ~dir ~capture id m.pane)
    | _ -> text
  in
  let outcome : Subrun.outcome = { result; text; at = Some (Timestamp.now ()) } in
  (match meta with
  | Some meta when unreported ->
      Option.iter
        (fun (e : Reap.ending) ->
          Result.iter_err
            (fun err -> Cli.error "run-outcome" (Msg.string_of_error err))
            (Reap.send ~dir { e with detail = Agent { unreported = true } }))
        (Reap.record_ending ~dir meta outcome)
  | _ ->
      if not (Subrun.record_outcome ~dir:runs id outcome) then
        fail "run %s already has an outcome, or is gone" id_str);
  0

module P = Tmux.Pane

let grace () =
  match Option.flat_map Int.of_string (Sys.getenv_opt "KIDO_LINGER_SECONDS") with
  | Some n when n > 0 -> Float.of_int n
  | _ -> 30.

type close = Window of Tmux.Window.id | Pane of { window : Tmux.Window.id; pane : Tmux.Pane.id }

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
      (Printf.sprintf "%s is a client's current window; leaving it for the user to read"
         (Tmux.Window.to_string window_id))
  else
    match P.run_pane panes window_id with
    | None ->
        Error (Printf.sprintf "%s has no run pane; leaving it" (Tmux.Window.to_string window_id))
    | Some { dead_at = None; _ } ->
        Error
          (Printf.sprintf "%s's run is still going; leaving it" (Tmux.Window.to_string window_id))
    | Some run ->
        Option.to_result
          (Printf.sprintf "%s is its session's only window; closing it would destroy the session"
             (Tmux.Window.to_string window_id))
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
  let open Result.Infix in
  let* e =
    match State.get_live ~dir (Subrun.string_of_id e.meta.id) with
    | Some ({ agent = Pi; _ } as s) ->
        let+ panes =
          if State.addressable_name s then Ok []
          else Result.map_err (fun m -> Msg.Failed m) (Tmux.Exec.list_panes ())
        in
        { e with meta = { e.meta with name = State.display_name panes s } }
    | _ -> Ok e
  in
  if String.is_empty e.meta.parent_session then Ok ()
  else
    Msg.notify ~dir ~parent_session:e.meta.parent_session
      ~from:{ session = ""; name = Subrun.label e.meta; pane = None }
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
    let closes = function Window w | Pane { window = w; _ } -> Tmux.Window.equal w window in
    match P.run_pane panes window with
    | Some { run = Some run; _ }
      when not (P.window_focused panes window || List.exists closes closing) -> (
        match (close_of panes window p.pane_id, Subrun.parse_id run) with
        | Some close, Ok run_id ->
            let ending =
              Option.flat_map
                (fun (m : Subrun.meta) ->
                  if not (Option.equal P.equal m.pane (Some p.pane_id)) then None
                  else begin
                    ignore (Subrun.save_screen ?socket ~dir run_id (Some p.pane_id));
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
                    (fun (r : P.t) -> P.equal r.pane_id p.pane_id)
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
            Option.map_or ~default:acc (mark acc) (Option.flat_map (P.find panes) s.pane)
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
        when Option.equal P.equal pane (Some p.pane_id)
             && (not (String.is_empty parent_session))
             && not (List.mem_assoc ~eq:String.equal parent_session sessions) ->
          mark ~text:"its parent ended" acc p
      | _ -> acc)
    acc panes

let collect ?socket ~dir ~grace panes sessions ~now =
  let closing, endings = sweep ?socket ~dir ~grace panes sessions ~now in
  List.iter (fun c -> ignore (release ?socket c)) closing;
  List.iter (fun e -> ignore (send ~dir e)) endings

let%test_module "Tests" =
  (module struct
    let now = 1_700_000_000.
    let temp () = Filename.temp_dir "kido-reap" ""

    let pane ?run ?dead ?(watched = false) pane_id window_id : Tmux.Pane.t =
      {
        (Tmux.Fixture.pane ~session:"s" ~created:0. ~window:window_id ~active:watched
           ~attached:watched ?run pane_id)
        with
        dead_at = Option.map (fun secs -> now -. Float.of_int secs) dead;
      }

    let id s = Result.get_exn (Subrun.parse_id s)

    let run ~dir ?(kind = Subrun.Agent) ?(parent = "") name id_s =
      let i = id id_s in
      Subrun.create ~dir i "task";
      Subrun.write_meta ~dir
        {
          id = i;
          name;
          kind;
          parent_session = parent;
          depth = 0;
          pane = Tmux.Pane.of_string "";
          pid = 0;
          cwd = "";
          model = "";
          tools = [];
          keep_alive = false;
          started_at = now;
        };
      i

    let%expect_test "decide: close-run's refusals and closes" =
      let show w panes =
        match decide panes (Option.get_exn_or "id" (Tmux.Window.of_string w)) with
        | Ok (Window w) -> Printf.printf "close %s\n" (Tmux.Window.to_string w)
        | Ok (Pane { window; pane }) ->
            Printf.printf "close %s pane %s\n" (Tmux.Window.to_string window)
              (Tmux.Pane.to_string pane)
        | Error why -> print_endline why
      in
      let focused = pane ~watched:true "%1" "@1" in
      show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane "%3" "@2" ];
      show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2" ];
      show "@2" [ focused; pane ~run:"run-x" "%2" "@2"; pane ~dead:1 "%3" "@2" ];
      show "@2"
        [ pane "%1" "@1"; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane ~watched:true "%3" "@2" ];
      show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1"; pane "%2" "@1" ];
      show "@1" [ focused; pane "%2" "@2" ];
      show "@2" [ focused; pane ~dead:1 "%2" "@2" ];
      show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1" ];
      show "@2"
        [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane ~run:"run-y" ~dead:1 "%3" "@2" ];
      [%expect
        {|
    close @2 pane %2
    close @2
    @2's run is still going; leaving it
    @2 is a client's current window; leaving it for the user to read
    close @1 pane %1
    @1 is a client's current window; leaving it for the user to read
    @2 has no run pane; leaving it
    @1 is its session's only window; closing it would destroy the session
    close @2 pane %2
    |}]

    let%expect_test "a bash ending's notice carries the run's name, status, id and output tail" =
      let dir = temp () in
      let i = run ~dir ~kind:Bash "build" "run-named" in
      Fs.write (Subrun.output_path ~dir i) "boom\n";
      let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir i) in
      let emit e = print_string (String.replace ~sub:dir ~by:"DIR" (body ~dir e)) in
      emit { meta; outcome = { result = Failed; text = "exit status 3"; at = None }; detail = Bash };
      emit
        {
          meta = { meta with name = "" };
          outcome = { result = Completed; text = "exit status 0"; at = None };
          detail = Bash;
        };
      emit
        {
          meta;
          outcome = { result = Completed; text = "exit status 0"; at = None };
          detail = Streamed { unstreamed = 2 };
        };
      emit
        {
          meta;
          outcome = { result = Completed; text = "exit status 0"; at = None };
          detail = Streamed { unstreamed = 0 };
        };
      Fs.remove (Subrun.output_path ~dir i);
      print_string
        (body ~dir { meta; outcome = { result = Failed; text = "x"; at = None }; detail = Bash }
        |> String.split_on_char '\n' |> List.last_opt |> Option.get_exn_or "line"
        |> String.replace ~sub:dir ~by:"DIR");
      [%expect
        {|
    async run "build" failed: exit status 3
    run: run-named
    output: DIR/runs/run-named/output
    --- output ---
    boom
    async run "run-named" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    --- output ---
    boom
    async run "build" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    2 lines not streamed (the output file above has every one)
    async run "build" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    --- output unreadable: DIR/runs/run-named/output: No such file or directory ---
    |}]

    let%expect_test "an agent ending's notice, reported and unreported" =
      let dir = temp () in
      let i = run ~dir ~parent:"root-sess" "kid" "run-agent" in
      let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir i) in
      print_string
        (body ~dir
           {
             meta;
             outcome = { result = Died; text = ""; at = None };
             detail = Agent { unreported = false };
           });
      print_string
        (body ~dir
           {
             meta;
             outcome = { result = Stopped; text = "killed by stop_run"; at = None };
             detail = Agent { unreported = true };
           });
      [%expect
        {|
    subagent "kid" ended without recording an outcome of its own, so kido recorded it as died; whether it called notify_parent is not known, and any report it sent stands
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    subagent "kid" stopped without reporting: it never called notify_parent, so this is the whole account of it
    detail: killed by stop_run
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    |}]

    (* The tail is cut at Msg.max_notice_bytes; a character the cut splits is dropped whole. *)
    let%expect_test "a bash notice keeps the output's tail, whole characters only" =
      let dir = temp () in
      let i = run ~dir ~kind:Bash "build" "run-tail" in
      let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir i) in
      let tail output =
        Fs.write (Subrun.output_path ~dir i) output;
        match
          body ~dir
            {
              meta;
              outcome = { result = Completed; text = "exit status 0"; at = None };
              detail = Bash;
            }
          |> String.lines |> List.drop 3
        with
        | header :: first :: rest ->
            Printf.printf "%s %S..%S\n" header (String.take 12 first)
              (List.last_opt rest |> Option.get_or ~default:first |> String.rev |> String.take 12
             |> String.rev)
        | lines -> List.iter print_endline lines
      in
      tail (String.concat "" (List.init 1000 (Printf.sprintf "line %04d\n")));
      tail "all of it\n";
      List.iter
        (fun keep -> tail ("ab\xf0\x9f\x8e\x89cd" ^ String.make (Msg.max_notice_bytes - keep) 'x'))
        [ 3; 4; 5; 6 ];
      tail (String.repeat "\xe2\x98\x83" ((Msg.max_notice_bytes / 3) + 1));
      [%expect
        {|
    --- last 4000 bytes of output (6000 omitted) --- "line 0600".."line 0999"
    --- output --- "all of it".."all of it"
    --- last 3999 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 3998 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 3997 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 4000 bytes of output (2 omitted) --- "\240\159\142\137cdxxxxxx".."xxxxxxxxxxxx"
    --- last 3999 bytes of output (3 omitted) --- "\226\152\131\226\152\131\226\152\131\226\152\131".."\226\152\131\226\152\131\226\152\131\226\152\131"
    |}]
  end)

module String_map = Map.Make (String)

type result = Success | Failure [@@deriving equal]

let yojson_of_result r = `String (match r with Success -> "success" | Failure -> "failure")

type outcome = { serial : int; result : result } [@@deriving equal, yojson_of]

type source = Blocked of { kind : Tmux.Program_status.kind option } | Ask of { id : Ask.id }
[@@deriving yojson_of]

type agent_state =
  | Running of { progress : int option }
  | Waiting of { source : source; progress : int option }
  | Stalled
  | Idle of { outcome : outcome option }
[@@deriving yojson_of]

type agent = { since : float; msg : string option; state : agent_state } [@@deriving yojson_of]

type report_state =
  | Running of { progress : int option }
  | Waiting of { kind : Tmux.Program_status.kind option; progress : int option }
  | Idle of { outcome : outcome option }
[@@deriving yojson_of]

type report = { since : float; msg : string option; state : report_state } [@@deriving yojson_of]

type exit = { code : int; command : string; started_at : float; ended_at : float }
[@@deriving yojson_of]

type phase =
  | Unknown
  | Idle of { last : exit option }
  | Running of { command : string; started_at : float; fullscreen : bool }
  | Fullscreen

let yojson_of_phase phase =
  let running origin fullscreen =
    `List [ `String "Running"; `Assoc [ ("origin", origin); ("fullscreen", `Bool fullscreen) ] ]
  in
  match phase with
  | Unknown -> `List [ `String "Unknown" ]
  | Idle { last } ->
      `List [ `String "Idle"; `Assoc [ ("last", yojson_of_option yojson_of_exit last) ] ]
  | Running { command; started_at; fullscreen } ->
      running
        (`List
           [
             `String "Command";
             `Assoc [ ("command", `String command); ("started_at", yojson_of_float started_at) ];
           ])
        fullscreen
  | Fullscreen -> running (`List [ `String "Unknown" ]) true

type shell = { phase : phase; report : report option } [@@deriving yojson_of]

type remote =
  | Remote_terminal of { interactive : bool; status : shell }
  | Remote_agent of { name : string; status : agent }
[@@deriving yojson_of]

type kind =
  | Terminal of shell
  | Some_agent of { name : string; status : agent }
  | Pi_agent of { id : Run.id; status : agent }
  | Ssh of { user : string; host : string; pane : remote }
[@@deriving yojson_of]

type tag = [ `Running | `Waiting | `Stalled | `Idle ] [@@deriving equal]
type retained = { outcome : outcome; id : string; at : float }

type episode = {
  finals : result String_map.t;
  retained : retained option;
  shown : (tag * outcome option) option;
  since : float;
}

type command = { start : float; observed : float; promoted : bool }
type root = Agent of string | Program [@@deriving equal]

type identity = { root : root; session : Run.id option; ssh : (string * string) option }
[@@deriving equal]

type track = {
  identity : identity;
  episode : episode;
  last : exit option;
  command : command option;
  interactive : bool;
}

let debounce = 0.2

let advance ~now ~serial ~(tag : tag) (records : Tmux.Program_status.record list) e =
  let final (r : Tmux.Program_status.record) =
    match r.state with Done -> Some Success | Error -> Some Failure | _ -> None
  in
  let entered =
    List.find_map
      (fun (r : Tmux.Program_status.record) ->
        match final r with
        | Some result
          when not (Option.equal equal_result (Some result) (String_map.find_opt r.id e.finals)) ->
            Some { outcome = { serial; result }; id = r.id; at = now }
        | _ -> None)
      records
  in
  let retained =
    match (e.shown, tag) with
    | Some (`Idle, _), (`Running | `Waiting | `Stalled) -> None
    | _ -> e.retained
  in
  let retained = Option.or_ ~else_:retained entered in
  let key = (tag, match tag with `Idle -> Option.map (fun r -> r.outcome) retained | _ -> None) in
  {
    finals =
      List.fold_left
        (fun m (r : Tmux.Program_status.record) ->
          Option.map_or ~default:m (fun f -> String_map.add r.id f m) (final r))
        String_map.empty records;
    retained;
    shown = Some key;
    since =
      (if Option.equal (Pair.equal equal_tag (Option.equal equal_outcome)) e.shown (Some key) then
         e.since
       else now);
  }

let idle_outcome e = match e.shown with Some (`Idle, outcome) -> outcome | _ -> None

let representative retained (records : Tmux.Program_status.record list) =
  let first p = List.find_opt p records in
  let is state (r : Tmux.Program_status.record) =
    match (state, r.state) with
    | `Blocked, Blocked _ | `Working, Working _ | `Idle, Idle -> true
    | _ -> false
  in
  match first (is `Blocked) with
  | Some _ as r -> r
  | None -> (
      match first (is `Working) with
      | Some _ as r -> r
      | None -> (
          match
            Option.flat_map
              (fun k -> first (fun (r : Tmux.Program_status.record) -> String.equal r.id k.id))
              retained
          with
          | Some _ as r -> r
          | None -> Option.or_lazy ~else_:(fun () -> List.head_opt records) (first (is `Idle))))

let blocked records =
  List.find_map
    (fun (r : Tmux.Program_status.record) ->
      match r.state with Blocked { kind; progress } -> Some (kind, progress) | _ -> None)
    records

let working records =
  List.find_map
    (fun (r : Tmux.Program_status.record) ->
      match r.state with Working progress -> Some progress | _ -> None)
    records

let agent ~now ~serial ~ask ~stalled ~msg records e =
  let live : (tag * agent_state) option =
    match (ask, blocked records, stalled, working records) with
    | Some id, _, _, _ -> Some (`Waiting, Waiting { source = Ask { id }; progress = None })
    | None, Some (kind, progress), _, _ ->
        Some (`Waiting, Waiting { source = Blocked { kind }; progress })
    | None, None, true, _ -> Some (`Stalled, Stalled)
    | None, None, false, Some progress -> Some (`Running, Running { progress })
    | None, None, false, None -> None
  in
  let e = advance ~now ~serial ~tag:(Option.map_or ~default:`Idle fst live) records e in
  let state =
    match live with Some (_, state) -> state | None -> Idle { outcome = idle_outcome e }
  in
  let rep = representative (if Option.is_some ask then None else e.retained) records in
  let msg = msg (Option.flat_map (fun (r : Tmux.Program_status.record) -> r.msg) rep) in
  (e, ({ since = e.since; msg; state } : agent))

let report ~now ~serial records e =
  let live : (tag * report_state) option =
    match (blocked records, working records) with
    | Some (kind, progress), _ -> Some (`Waiting, Waiting { kind; progress })
    | None, Some progress -> Some (`Running, Running { progress })
    | None, None -> None
  in
  let e = advance ~now ~serial ~tag:(Option.map_or ~default:`Idle fst live) records e in
  match (records, e.retained) with
  | [], None -> ({ e with shown = None }, None)
  | _ ->
      let state =
        match live with Some (_, state) -> state | None -> Idle { outcome = idle_outcome e }
      in
      let rep = representative e.retained records in
      ( e,
        Some
          ({
             since = e.since;
             msg = Option.flat_map (fun (r : Tmux.Program_status.record) -> r.msg) rep;
             state;
           }
            : report) )

type reading =
  | Unintegrated
  | Exited of exit
  | Prompt
  | Command of { command : string; started_at : float; prompted : bool }

let reading ~transport (p : Tmux_pane.t) =
  match (Tmux_pane.shell p, p.command_start, p.last_exit) with
  | _, Some started_at, _ when transport ->
      Command { command = p.command_line; started_at; prompted = Option.is_some p.last_prompt }
  | _, None, _ when transport -> Unintegrated
  | Running, Some started_at, _ -> Command { command = p.command_line; started_at; prompted = true }
  | Idle, Some started_at, Some { code; at } when Float.(at > 0.) ->
      Exited { code; command = p.command_line; started_at; ended_at = at }
  | Idle, _, _ -> Prompt
  | (Unintegrated | Running), _, _ -> Unintegrated

let shell ~now ~fullscreen ~serial (records : Tmux.Program_status.record list) reading t =
  let fullscreen_unknown otherwise = if fullscreen then Fullscreen else otherwise in
  let t, phase =
    match reading with
    | Command c ->
        let cmd =
          match t.command with
          | Some k when Float.equal k.start c.started_at -> k
          | _ -> { start = c.started_at; observed = now; promoted = false }
        in
        let promote =
          (not cmd.promoted) && (fullscreen || Float.(now - cmd.observed >= debounce))
        in
        let t =
          if promote then
            {
              t with
              last = None;
              episode =
                {
                  t.episode with
                  retained =
                    Option.filter (fun r -> Float.(r.at >= cmd.observed)) t.episode.retained;
                };
            }
          else t
        in
        let cmd = { cmd with promoted = cmd.promoted || promote } in
        ( { t with command = Some cmd },
          if cmd.promoted then
            Running { command = c.command; started_at = c.started_at; fullscreen }
          else if c.prompted then Idle { last = t.last }
          else Unknown )
    | Exited exit ->
        ({ t with last = Some exit; command = None }, fullscreen_unknown (Idle { last = Some exit }))
    | Prompt ->
        let last = if Option.is_some t.command then None else t.last in
        ({ t with last; command = None }, fullscreen_unknown (Idle { last }))
    | Unintegrated -> ({ t with command = None }, fullscreen_unknown Unknown)
  in
  let episode, report = report ~now ~serial records t.episode in
  ({ t with episode }, { phase; report })

let observe ~now ~ask ~stalled (p : Tmux_pane.t) (kind : Pane_kind.t) prev =
  let status = p.program_status in
  let identity =
    {
      root =
        (match kind with
        | Some_agent { name } | Ssh { pane = Remote_agent { name }; _ } -> Agent name
        | Pi_agent _ -> Agent "pi"
        | Terminal | Ssh { pane = Remote_terminal; _ } -> Program);
      session = (match kind with Pi_agent { id; _ } -> Some id | _ -> None);
      ssh = (match kind with Ssh { user; host; _ } -> Some (user, host) | _ -> None);
    }
  in
  let t =
    match prev with
    | Some t when equal_identity t.identity identity -> t
    | _ ->
        {
          identity;
          episode = { finals = String_map.empty; retained = None; shown = None; since = now };
          last = None;
          command = None;
          interactive = false;
        }
  in
  let serial = status.serial and records = status.records in
  let agent ~ask ~stalled ~dedupe ~fallback =
    let title = Option.value ~default:"" (Pane_kind.title p kind) in
    let e, status =
      agent ~now ~serial ~ask ~stalled
        ~msg:(fun msg ->
          match
            Option.filter
              (fun m ->
                not (dedupe && (String.equal title m || String.prefix ~pre:(m ^ " - ") title)))
              msg
          with
          | Some _ as m -> m
          | None -> fallback)
        records t.episode
    in
    ({ t with episode = e }, status)
  in
  let fullscreen = p.alternate_on in
  match kind with
  | Terminal ->
      let t, shell = shell ~now ~fullscreen ~serial records (reading ~transport:false p) t in
      (t, Terminal shell)
  | Some_agent { name } ->
      let t, status = agent ~ask:None ~stalled:false ~dedupe:false ~fallback:None in
      (t, Some_agent { name; status })
  | Pi_agent { id; pi = session } ->
      let t, status =
        agent ~ask ~stalled ~dedupe:true
          ~fallback:(if String.is_empty session.activity then None else Some session.activity)
      in
      (t, Pi_agent { id; status })
  | Ssh { user; host; pane = Remote_agent { name } } ->
      let t, status = agent ~ask:None ~stalled:false ~dedupe:false ~fallback:None in
      (t, Ssh { user; host; pane = Remote_agent { name; status } })
  | Ssh { user; host; pane = Remote_terminal } ->
      let interactive =
        t.interactive
        ||
        match (p.last_prompt, p.command_start) with
        | Some prompt, Some start -> Float.(prompt > start)
        | _ -> false
      in
      let t, status =
        shell ~now ~fullscreen ~serial records
          (reading ~transport:(not interactive) p)
          { t with interactive }
      in
      (t, Ssh { user; host; pane = Remote_terminal { interactive; status } })

let pending t = Option.exists (fun c -> not c.promoted) t.command

let label t (p : Tmux_pane.t) =
  let status = p.program_status in
  match representative t.episode.retained status.records with
  | Some { title = Some title; _ } -> title
  | Some r -> Option.value ~default:p.current_command (Tmux.Program_status.app status r)
  | None -> p.current_command

let%test_module "Tests" =
  (module struct
    open View_fixture

    let records ?(serial = 1) rs (p : Tmux_pane.t) =
      let record (id, state) = Printf.sprintf {|{"id":%S,%s}|} id state in
      {
        p with
        program_status =
          Result.get_exn
            (Tmux.Program_status.parse
               (Printf.sprintf {|{"serial":%d,"records":[%s]}|} serial
                  (String.concat "," (List.map record rs))));
      }

    let outcome = function
      | None -> ""
      | Some { serial; result } ->
          Printf.sprintf ":%s@%d"
            (match result with Success -> "success" | Failure -> "failure")
            serial

    let progress = Option.map_or ~default:"" (Printf.sprintf "(%d%%)")

    let kind_name : Tmux.Program_status.kind option -> string = function
      | None -> "none"
      | Some Permission -> "permission"
      | Some Question -> "question"
      | Some Auth -> "auth"

    let agent_text t0 (a : agent) =
      Printf.sprintf "%s since=+%.1f%s"
        (match a.state with
        | Running { progress = p } -> "running" ^ progress p
        | Waiting { source = Blocked { kind }; progress = p } ->
            "waiting:" ^ kind_name kind ^ progress p
        | Waiting { source = Ask { id }; _ } -> "waiting:ask " ^ Ask.string_of_id id
        | Stalled -> "stalled"
        | Idle { outcome = o } -> "idle" ^ outcome o)
        (a.since -. t0)
        (Option.map_or ~default:"" (Printf.sprintf " msg=%S") a.msg)

    let shell_text t0 (s : shell) =
      (match s.phase with
        | Unknown -> "unknown"
        | Idle { last = None } -> "idle"
        | Idle { last = Some e } ->
            Printf.sprintf "idle last=%d %S %.0f-%.0f" e.code e.command (e.started_at -. test_at)
              (e.ended_at -. test_at)
        | Running { command; started_at; fullscreen } ->
            Printf.sprintf "running %S %.0f" command (started_at -. test_at)
            ^ if fullscreen then " fullscreen" else ""
        | Fullscreen -> "running ? fullscreen")
      ^ Option.map_or ~default:""
          (fun (r : report) ->
            Printf.sprintf " | report %s since=+%.1f%s"
              (match r.state with
              | Running { progress = p } -> "running" ^ progress p
              | Waiting { kind; progress = p } -> "waiting:" ^ kind_name kind ^ progress p
              | Idle { outcome = o } -> "idle" ^ outcome o)
              (r.since -. t0)
              (Option.map_or ~default:"" (Printf.sprintf " msg=%S") r.msg))
          s.report

    let text t0 = function
      | Terminal s -> shell_text t0 s
      | Some_agent { status; _ } | Pi_agent { status; _ } -> agent_text t0 status
      | Ssh { pane = Remote_agent { status; _ }; _ } -> "remote " ^ agent_text t0 status
      | Ssh { pane = Remote_terminal { interactive; status }; _ } ->
          Printf.sprintf "ssh%s %s"
            (if interactive then " interactive" else "")
            (shell_text t0 status)

    let run ?(states = Tmux.Pane_map.empty) steps =
      let track = ref None and now = ref test_at in
      List.iter
        (fun (d, ask, stalled, label, p) ->
          now := !now +. d;
          let t, k = observe ~now:!now ~ask ~stalled p (Pane_kind.classify ~states p) !track in
          track := Some t;
          Printf.printf "%-22s %s\n" label (text test_at k))
        steps

    let pi = {|"app":"pi","state":|}
    let claude = {|"app":"claude-code","state":|}

    let agent ?(serial = 1) ?(d = 1.) label rs =
      (d, None, false, label, records ~serial rs (pane "%1"))

    let%expect_test "agent precedence: waiting > stalled > running > idle, ties bytewise" =
      let pane rs = records rs (pane ~title:"agent" "%1") in
      let states = states [ ("%1", ("pi-1", session "")) ] in
      let ask = Some (Result.get_exn (Ask.parse_id "A1")) in
      run ~states
        [
          (0., None, false, "idle", pane [ ("", pi ^ {|"idle"|}) ]);
          (1., None, false, "working", pane [ ("", pi ^ {|"working","progress":10|}) ]);
          (1., None, true, "stalled", pane [ ("", pi ^ {|"working","progress":10|}) ]);
          ( 1.,
            None,
            true,
            "blocked child > stall",
            pane
              [
                ("", pi ^ {|"working"|});
                ("b", {|"state":"blocked","kind":"question"|});
                ("a", {|"state":"blocked","kind":"auth","progress":3|});
              ] );
          ( 1.,
            ask,
            true,
            "ask > blocked",
            pane
              [ ("", pi ^ {|"working"|}); ("a", {|"state":"blocked","kind":"auth","progress":3|}) ]
          );
          ( 1.,
            None,
            false,
            "working ties by id",
            pane
              [
                ("", pi ^ {|"idle"|});
                ("z", {|"state":"working","progress":9|});
                ("y", {|"state":"working","progress":8|});
              ] );
        ];
      [%expect
        {|
        idle                   idle since=+0.0
        working                running(10%) since=+1.0
        stalled                stalled since=+2.0
        blocked child > stall  waiting:auth(3%) since=+3.0
        ask > blocked          waiting:ask A1 since=+3.0
        working ties by id     running(8%) since=+5.0
        |}]

    let%expect_test
        "an ask takes its message from blocked, working, then idle, never the outcome's record" =
      let pane rs = records rs (pane ~title:"agent" "%1") in
      let states = states [ ("%1", ("pi-1", session "")) ] in
      let ask = Some (Result.get_exn (Ask.parse_id "A1")) in
      let steps ask =
        [
          ( 0.,
            None,
            false,
            "child done, root works",
            pane [ ("", pi ^ {|"working","msg":"Vw=="|}); ("a", {|"state":"done","msg":"Qw=="|}) ]
          );
          ( 1.,
            ask,
            false,
            "root idle",
            pane [ ("", pi ^ {|"idle","msg":"Ug=="|}); ("a", {|"state":"done","msg":"Qw=="|}) ] );
        ]
      in
      run ~states (steps None);
      run ~states (steps ask);
      [%expect
        {|
        child done, root works running since=+0.0 msg="W"
        root idle              idle:success@1 since=+1.0 msg="C"
        child done, root works running since=+0.0 msg="W"
        root idle              waiting:ask A1 since=+1.0 msg="R"
        |}]

    let%expect_test "since moves only on a tag or idle-outcome change" =
      run
        [
          agent ~d:0. "working" [ ("", claude ^ {|"working","progress":1|}) ];
          agent "progress, msg, serial" ~serial:2
            [ ("", claude ^ {|"working","progress":2,"msg":"TQ=="|}) ];
          agent "representative" ~serial:3
            [ ("", claude ^ {|"idle"|}); ("a", {|"state":"working"|}) ];
          agent "blocked" [ ("", claude ^ {|"blocked","kind":"permission"|}) ];
          agent "kind changes" [ ("", claude ^ {|"blocked","kind":"question"|}) ];
          agent "idle" [ ("", claude ^ {|"idle"|}) ];
          agent "title only" [ ("", claude ^ {|"idle","title":"VA=="|}) ];
          agent "done" ~serial:5 [ ("", claude ^ {|"done"|}) ];
          agent "msg on done" ~serial:6 [ ("", claude ^ {|"done","msg":"TQ=="|}) ];
          agent "done -> error" ~serial:7 [ ("", claude ^ {|"error"|}) ];
        ];
      [%expect
        {|
        working                running(1%) since=+0.0
        progress, msg, serial  running(2%) since=+0.0 msg="M"
        representative         running since=+0.0
        blocked                waiting:permission since=+3.0
        kind changes           waiting:question since=+3.0
        idle                   idle since=+5.0
        title only             idle since=+5.0
        done                   idle:success@5 since=+7.0
        msg on done            idle:success@5 since=+7.0 msg="M"
        done -> error          idle:failure@7 since=+9.0
        |}]

    let%expect_test
        "outcome entries: initial, reappearing, final flips; unrelated updates never re-arm" =
      run
        [
          agent ~d:0. "initial final" ~serial:4 [ ("", claude ^ {|"done"|}) ];
          agent "unchanged, new serial" ~serial:5 [ ("", claude ^ {|"done","msg":"TQ=="|}) ];
          agent "error -> " ~serial:6 [ ("", claude ^ {|"error"|}) ];
          agent "-> done" ~serial:7 [ ("", claude ^ {|"done"|}) ];
          agent "turned idle" ~serial:8 [ ("", claude ^ {|"idle"|}) ];
          agent "simultaneous" ~serial:9
            [ ("", claude ^ {|"idle"|}); ("b", {|"state":"done"|}); ("a", {|"state":"error"|}) ];
          agent "removed" ~serial:10 [ ("", claude ^ {|"idle"|}) ];
          agent "reappears" ~serial:11 [ ("", claude ^ {|"idle"|}); ("b", {|"state":"done"|}) ];
        ];
      [%expect
        {|
        initial final          idle:success@4 since=+0.0
        unchanged, new serial  idle:success@4 since=+0.0 msg="M"
        error ->               idle:failure@6 since=+2.0
        -> done                idle:success@7 since=+3.0
        turned idle            idle:success@7 since=+3.0
        simultaneous           idle:failure@9 since=+5.0
        removed                idle:failure@9 since=+5.0
        reappears              idle:success@11 since=+7.0
        |}]

    let%expect_test "outcomes: cleared by new work, pending during other work, never resurrected" =
      run
        [
          agent ~d:0. "done" ~serial:1 [ ("", claude ^ {|"idle"|}); ("a", {|"state":"done"|}) ];
          agent "new work" ~serial:2 [ ("", claude ^ {|"working"|}); ("a", {|"state":"done"|}) ];
          agent "idle again" ~serial:3 [ ("", claude ^ {|"idle"|}); ("a", {|"state":"done"|}) ];
          agent "child ends, root works" ~serial:4
            [ ("", claude ^ {|"working"|}); ("a", {|"state":"done"|}); ("b", {|"state":"error"|}) ];
          agent "blocked meanwhile" ~serial:5
            [ ("", claude ^ {|"blocked"|}); ("a", {|"state":"done"|}); ("b", {|"state":"error"|}) ];
          agent "root idle" ~serial:6
            [ ("", claude ^ {|"idle"|}); ("a", {|"state":"done"|}); ("b", {|"state":"error"|}) ];
        ];
      [%expect
        {|
        done                   idle:success@1 since=+0.0
        new work               running since=+1.0
        idle again             idle since=+2.0
        child ends, root works running since=+3.0
        blocked meanwhile      waiting:none since=+4.0
        root idle              idle:failure@4 since=+5.0
        |}]

    let%expect_test "a root app, Run session or ssh destination change resets tracking" =
      let track = ref None and now = ref test_at in
      let step label kind p =
        now := !now +. 1.;
        let t, k = observe ~now:!now ~ask:None ~stalled:false p kind !track in
        track := Some t;
        Printf.printf "%-20s %s\n" label (text test_at k)
      in
      let p = pane ~title:"agent" "%1" in
      let pi_kind id : Pane_kind.t = Pi_agent { id = Test_fixture.run_id id; pi = session "" } in
      step "pi done" (pi_kind "a") (records ~serial:1 [ ("", pi ^ {|"done"|}) ] p);
      step "same" (pi_kind "a") (records ~serial:2 [ ("", pi ^ {|"done"|}) ] p);
      step "new session id" (pi_kind "b") (records ~serial:3 [ ("", pi ^ {|"done"|}) ] p);
      let claude_kind : Pane_kind.t = Some_agent { name = "claude-code" } in
      step "claude replaces pi" claude_kind (records ~serial:4 [ ("", claude ^ {|"done"|}) ] p);
      step "same claude" claude_kind (records ~serial:5 [ ("", claude ^ {|"done"|}) ] p);
      step "root cleared" Terminal p;
      step "claude again" claude_kind (records ~serial:6 [ ("", claude ^ {|"done"|}) ] p);
      let ssh host : Pane_kind.t = Ssh { user = "u"; host; pane = Remote_agent { name = "pi" } } in
      step "remote pi" (ssh "one") (records ~serial:7 [ ("", pi ^ {|"done"|}) ] p);
      step "same destination" (ssh "one") (records ~serial:8 [ ("", pi ^ {|"done"|}) ] p);
      step "new destination" (ssh "two") (records ~serial:9 [ ("", pi ^ {|"done"|}) ] p);
      [%expect
        {|
        pi done              idle:success@1 since=+1.0
        same                 idle:success@1 since=+1.0
        new session id       idle:success@3 since=+3.0
        claude replaces pi   idle:success@4 since=+4.0
        same claude          idle:success@4 since=+4.0
        root cleared         unknown
        claude again         idle:success@6 since=+7.0
        remote pi            remote idle:success@7 since=+8.0
        same destination     remote idle:success@7 since=+8.0
        new destination      remote idle:success@9 since=+10.0
        |}]

    let sh ?(d = 0.1) ?prompt ?start ?(running = false) ?exit ?(cmd = "") ?(alternate = false)
        ?(rs = []) ?(serial = 1) label =
      let at = Option.map (fun s -> test_at +. s) in
      ( d,
        None,
        false,
        label,
        records ~serial rs
          (pane ~command:"zsh" ?prompt:(at prompt) ?start:(at start) ~running
             ?exit:(Option.map (fun (code, e) -> (code, test_at +. e)) exit)
             ~command_line:cmd ~alternate "%1") )

    let%expect_test "shell debounce: first observation, successive commands, short commands" =
      run
        [
          sh ~d:0. "prompt" ~prompt:(-9.) ~start:(-10.) ~exit:(0, -9.) ~cmd:"ls";
          sh "make starts" ~prompt:(-9.) ~start:0. ~running:true ~cmd:"make";
          sh ~d:0.15 "debouncing" ~prompt:(-9.) ~start:0. ~running:true ~cmd:"make";
          sh ~d:0.05 "promoted" ~prompt:(-9.) ~start:0. ~running:true ~cmd:"make";
          sh ~d:1. "next start, no prompt" ~prompt:(-9.) ~start:1. ~running:true ~cmd:"test";
          sh ~d:0.25 "promoted" ~prompt:(-9.) ~start:1. ~running:true ~cmd:"test";
          sh ~d:0.5 "finished" ~prompt:2. ~start:1. ~exit:(2, 2.) ~cmd:"test";
          sh "short starts" ~prompt:2. ~start:3. ~running:true ~cmd:"true";
          sh ~d:0.05 "short finished" ~prompt:3. ~start:3. ~exit:(0, 3.) ~cmd:"true";
        ];
      run
        [
          sh ~d:0. "first read running" ~prompt:(-9.) ~start:(-5.) ~running:true ~cmd:"sleep";
          sh ~d:0.19 "still debouncing" ~prompt:(-9.) ~start:(-5.) ~running:true ~cmd:"sleep";
          sh ~d:0.01 "promoted" ~prompt:(-9.) ~start:(-5.) ~running:true ~cmd:"sleep";
        ];
      [%expect
        {|
        prompt                 idle last=0 "ls" -10--9
        make starts            idle last=0 "ls" -10--9
        debouncing             idle last=0 "ls" -10--9
        promoted               running "make" 0
        next start, no prompt  idle
        promoted               running "test" 1
        finished               idle last=2 "test" 1-2
        short starts           idle last=2 "test" 1-2
        short finished         idle last=0 "true" 3-3
        first read running     idle
        still debouncing       idle
        promoted               running "sleep" -5
        |}]

    let%expect_test "a missing D is not an exit; unintegrated is unknown, never idle" =
      run
        [
          sh ~d:0. "failed" ~prompt:1. ~start:0. ~exit:(1, 1.) ~cmd:"false";
          sh "next" ~prompt:1. ~start:2. ~running:true ~cmd:"lost";
          sh ~d:0.3 "running" ~prompt:1. ~start:2. ~running:true ~cmd:"lost";
          sh "healed prompt" ~prompt:3. ~start:2. ~running:true ~cmd:"lost";
          sh "no integration" ~exit:(0, 3.);
        ];
      [%expect
        {|
        failed                 idle last=1 "false" 0-1
        next                   idle last=1 "false" 0-1
        running                running "lost" 2
        healed prompt          idle
        no integration         unknown
        |}]

    let%expect_test "fullscreen runs at once, keeps a known origin, else unknown" =
      run
        [
          sh ~d:0. "prompt" ~prompt:(-1.) ~start:(-2.) ~exit:(1, -1.) ~cmd:"false";
          sh "vim" ~prompt:(-1.) ~start:0. ~running:true ~cmd:"vim" ~alternate:true;
          sh "left fullscreen" ~prompt:(-1.) ~start:0. ~running:true ~cmd:"vim";
          sh "finished" ~prompt:1. ~start:0. ~exit:(0, 1.) ~cmd:"vim";
          sh "alternate at a prompt" ~prompt:1. ~start:0. ~exit:(0, 1.) ~cmd:"vim" ~alternate:true;
          sh "back" ~prompt:1. ~start:0. ~exit:(0, 1.) ~cmd:"vim";
          sh "no integration" ~alternate:true;
          sh "back";
        ];
      [%expect
        {|
        prompt                 idle last=1 "false" -2--1
        vim                    running "vim" 0 fullscreen
        left fullscreen        running "vim" 0
        finished               idle last=0 "vim" 0-1
        alternate at a prompt  running ? fullscreen
        back                   idle last=0 "vim" 0-1
        no integration         running ? fullscreen
        back                   unknown
        |}]

    let%expect_test "a report rides every phase; promotion drops only an outcome from before it" =
      let built = [ ("", {|"app":"make","state":"done","msg":"QnVpbHQ="|}) ] in
      let working = [ ("", {|"app":"make","state":"working","progress":40|}) ] in
      run
        [
          sh ~d:0. "unknown" ~rs:working;
          sh "idle, built" ~prompt:0. ~rs:built ~serial:2;
          sh "records cleared" ~prompt:0. ~serial:3;
          sh "command observed" ~prompt:0. ~start:1. ~running:true ~cmd:"make";
          sh ~d:0.3 "promoted" ~prompt:0. ~start:1. ~running:true ~cmd:"make";
          sh "finished" ~prompt:2. ~start:1. ~exit:(0, 2.) ~cmd:"make";
          sh "next command" ~prompt:2. ~start:3. ~running:true ~cmd:"make" ~rs:working ~serial:4;
          sh "built in debounce" ~prompt:2. ~start:3. ~running:true ~cmd:"make" ~rs:built ~serial:5;
          sh ~d:0.2 "promoted" ~prompt:2. ~start:3. ~running:true ~cmd:"make" ~rs:built ~serial:5;
          sh "blocked fullscreen" ~prompt:2. ~start:3. ~running:true ~cmd:"make" ~alternate:true
            ~rs:[ ("", {|"app":"make","state":"blocked","kind":"auth"|}) ]
            ~serial:6;
          sh "new report episode" ~prompt:4. ~start:3. ~exit:(0, 4.) ~cmd:"make" ~serial:7;
        ];
      [%expect
        {|
        unknown                unknown | report running(40%) since=+0.0
        idle, built            idle | report idle:success@2 since=+0.1 msg="Built"
        records cleared        idle | report idle:success@2 since=+0.1
        command observed       idle | report idle:success@2 since=+0.1
        promoted               running "make" 1
        finished               idle last=0 "make" 1-2
        next command           idle last=0 "make" 1-2 | report running(40%) since=+0.8
        built in debounce      idle last=0 "make" 1-2 | report idle:success@5 since=+0.9 msg="Built"
        promoted               running "make" 3 | report idle:success@5 since=+0.9 msg="Built"
        blocked fullscreen     running "make" 3 fullscreen | report waiting:auth since=+1.2
        new report episode     idle last=0 "make" 3-4
        |}]

    let ssh ?(d = 0.1) ?(host = "box") ~prompt ~start ?(running = true) ?exit ?(cmd = "") label =
      ( d,
        None,
        false,
        label,
        {
          (pane ~command:"ssh" ~prompt:(test_at +. prompt) ~start:(test_at +. start) ~running
             ?exit:(Option.map (fun (code, e) -> (code, test_at +. e)) exit)
             ~command_line:cmd "%1")
          with
          ssh = Some ("deploy", host);
        } )

    let%expect_test
        "ssh: a transport command until a strictly later prompt, latched per destination" =
      run
        [
          ssh ~d:0. "ssh starts" ~prompt:(-1.) ~start:0. ~cmd:"ssh box";
          ssh ~d:0.3 "transport" ~prompt:(-1.) ~start:0. ~cmd:"ssh box";
          ssh "same-second prompt" ~prompt:0. ~start:0. ~cmd:"ssh box";
          ssh "remote prompt" ~prompt:1. ~start:0. ~running:false ~cmd:"ssh box";
          ssh "remote command" ~prompt:1. ~start:2. ~cmd:"sleep 45";
          ssh ~d:0.3 "promoted" ~prompt:1. ~start:2. ~cmd:"sleep 45";
          ssh "remote prompt" ~prompt:3. ~start:2. ~running:false ~exit:(0, 3.) ~cmd:"sleep 45";
          ssh "new destination" ~host:"other" ~prompt:3. ~start:4. ~cmd:"ssh other";
          ssh ~d:0.3 "transport again" ~host:"other" ~prompt:3. ~start:4. ~cmd:"ssh other";
        ];
      [%expect
        {|
        ssh starts             ssh idle
        transport              ssh running "ssh box" 0
        same-second prompt     ssh running "ssh box" 0
        remote prompt          ssh interactive idle
        remote command         ssh interactive idle
        promoted               ssh interactive running "sleep 45" 2
        remote prompt          ssh interactive idle last=0 "sleep 45" 2-3
        new destination        ssh idle
        transport again        ssh running "ssh other" 4
        |}]
  end)

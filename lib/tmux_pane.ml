open Tmux

let optional_id_to_yojson = function None -> `String "" | Some id -> pane_id_to_yojson id

let optional_id_of_yojson = function
  | `String "" -> Ok None
  | json -> Result.map Option.some (pane_id_of_yojson json)

type exit = { code : int; at : float }

type t = {
  session_name : string;
  session_id : session_id;
  session_created : float;
  window_index : int;
  window_id : window_id;
  window_name : string;
  window_layout : string;
  pane_id : pane_id;
  active : bool;
  pane_active : bool;
  pane_pid : int;
  current_command : string;
  current_path : string;
  alternate_on : bool;
  command_running : bool;
  command_start : float option;
  last_prompt : float option;
  last_exit : exit option;
  command_line : string;
  dead_at : float option;
  run : string option;
  ssh : (string * string) option;
  session_attached : bool;
  program_status : Program_status.t;
  title : string;
}

type shell = Unintegrated | Idle | Running

let shell p =
  match (p.last_prompt, p.command_start) with
  | None, _ -> Unintegrated
  | Some prompt, Some start when p.command_running && Float.(prompt <= start) -> Running
  | Some _, _ -> Idle

let run_option = "@kido_run"
let sep = "\x1f"

let format =
  String.concat sep
    [
      "#{session_name}";
      "#{session_id}";
      "#{session_created}";
      "#{window_index}";
      "#{window_id}";
      "#{window_name}";
      "#{window_layout}";
      "#{pane_id}";
      "#{&&:#{window_active},#{pane_active}}";
      "#{pane_pid}";
      "#{pane_current_command}";
      "#{pane_current_path}";
      "#{alternate_on}";
      "#{pane_command_running}";
      "#{pane_command_start_time}";
      "#{pane_last_prompt_time}";
      "#{pane_command_status}";
      "#{pane_command_end_time}";
      "#{pane_command_line}";
      "#{pane_dead}";
      "#{pane_dead_time}";
      "#{session_attached}";
      "#{" ^ run_option ^ "}";
      "#{pane_active}";
      "#{@kido_ssh}";
      "#{pane_program_status}";
      "#{pane_title}";
    ]

let fields = 27

let split_n n s =
  let rec go n from =
    match String.index_from_opt s from sep.[0] with
    | Some i when n > 1 -> String.sub s from (i - from) :: go (n - 1) (i + 1)
    | _ -> [ String.sub s from (String.length s - from) ]
  in
  go n 0

let int s = Option.get_or ~default:0 (int_of_string_opt s)
let time s = match int s with 0 -> None | n -> Some (Float.of_int n)

let parse_line line =
  match Array.of_list (split_n fields line) with
  | f when Array.length f < fields -> None
  | f ->
      let open Option.Infix in
      let* session_id = session_id_of_string f.(1) in
      let* window_id = window_id_of_string f.(4) in
      let* pane_id = pane_id_of_string f.(7) in
      let program_status =
        Result.get_or
          ~default:Program_status.{ serial = 0; records = [] }
          (Program_status.parse f.(25))
      in
      Some
        {
          session_name = f.(0);
          session_id;
          session_created = Float.of_int (int f.(2));
          window_index = int f.(3);
          window_id;
          window_name = f.(5);
          window_layout = f.(6);
          pane_id;
          active = String.equal f.(8) "1";
          pane_pid = int f.(9);
          current_command = f.(10);
          current_path = f.(11);
          alternate_on = String.equal f.(12) "1";
          command_running = String.equal f.(13) "1";
          command_start = time f.(14);
          last_prompt = time f.(15);
          last_exit =
            Option.map
              (fun code -> { code; at = Float.of_int (int f.(17)) })
              (int_of_string_opt f.(16));
          command_line = f.(18);
          dead_at = (if String.equal f.(19) "1" then time f.(20) else None);
          session_attached = not (String.equal f.(21) "" || String.equal f.(21) "0");
          run = (if String.is_empty f.(22) then None else Some f.(22));
          pane_active = String.equal f.(23) "1";
          ssh =
            (match String.rindex_opt f.(24) '@' with
            | Some i when i > 0 && i < String.length f.(24) - 1 ->
                Some
                  (String.sub f.(24) 0 i, String.sub f.(24) (i + 1) (String.length f.(24) - i - 1))
            | _ -> None);
          program_status;
          title = f.(26);
        }

let parse lines = List.filter_map parse_line lines
let find panes id = List.find_opt (fun p -> equal_pane_id p.pane_id id) panes

type session = { name : string; id : session_id; windows : t list list }

let order_sessions panes =
  let add groups p =
    let mine, others =
      List.partition (fun (first, _) -> String.equal first.session_name p.session_name) groups
    in
    let first, windows = match mine with [ g ] -> g | _ -> (p, []) in
    match windows with
    | (q :: _ as w) :: ws when equal_window_id q.window_id p.window_id ->
        (first, (p :: w) :: ws) :: others
    | ws -> (first, [ p ] :: ws) :: others
  in
  List.fold_left add [] panes
  |> List.sort (fun (a, _) (b, _) ->
      match Float.compare a.session_created b.session_created with
      | 0 -> String.compare a.session_name b.session_name
      | c -> c)
  |> List.map (fun (first, windows) ->
      let by_age = List.sort (fun a b -> compare_pane_id a.pane_id b.pane_id) in
      { name = first.session_name; id = first.session_id; windows = List.rev_map by_age windows })

let in_window window_id p = equal_window_id p.window_id window_id

let window_focused panes window_id =
  List.exists (fun p -> in_window window_id p && p.active && p.session_attached) panes

let last_window panes window_id =
  match List.find_opt (in_window window_id) panes with
  | None -> false
  | Some { session_id; _ } ->
      List.filter (fun p -> equal_session_id p.session_id session_id) panes
      |> List.map (fun p -> p.window_id)
      |> List.uniq ~eq:equal_window_id |> List.length <= 1

let last_pane panes window_id = List.count (in_window window_id) panes <= 1

let run_pane panes window_id =
  List.find_opt (fun p -> in_window window_id p && Option.is_some p.run) panes

let active_pane panes session =
  List.find_map
    (fun p -> if String.equal p.session_name session && p.active then Some p.pane_id else None)
    panes

let list_panes tmux = Result.map parse (Tmux.list_panes tmux ~format)

let real_clients lines =
  List.filter_map
    (fun line ->
      match Tmux.client_fields line with
      | Some (name, _, _, _, control) when not (String.is_empty name || String.equal control "1") ->
          Some name
      | _ -> None)
    lines

let resolve_client tmux ~pane ~tmux_env =
  let live =
    match pane with
    | None -> None
    | Some pane -> (
        match
          Tmux.exec tmux [ "display-message"; "-p"; "-t"; pane_id_to_string pane; "#{session_id}" ]
        with
        | Ok id -> session_id_of_string id
        | _ -> None)
  in
  let target =
    match (live, String.split_on_char ',' tmux_env) with
    | Some id, _ -> Some id
    | None, _ :: _ :: id :: _ when not (String.is_empty id) -> session_id_of_string ("$" ^ id)
    | None, _ -> None
  in
  match
    Option.map
      (fun t ->
        Tmux.exec tmux [ "list-clients"; "-t"; session_id_to_string t; "-F"; Tmux.client_format ])
      target
  with
  | Some (Ok out) -> (
      match real_clients (String.split_on_char '\n' out) with [ c ] -> Some c | _ -> None)
  | _ -> None

let mark_ssh tmux pane destination =
  Tmux.run tmux [ "set-option"; "-p"; "-t"; pane_id_to_string pane; "@kido_ssh"; destination ]

let mark_run tmux pane_id run_id =
  Tmux.run tmux [ "set-option"; "-p"; "-t"; pane_id_to_string pane_id; run_option; run_id ]

let%test_module "Tests" =
  (module struct
    let%expect_test "optional pane ids use an empty string for none" =
      List.iter
        (fun json ->
          match optional_id_of_yojson json with
          | Ok id -> print_endline (Yojson.Safe.to_string (optional_id_to_yojson id))
          | Error e -> print_endline e)
        [ `String ""; `String "%0"; `String "%123"; `String "%"; `String "@1"; `Null ];
      [%expect {|
    ""
    "%0"
    "%123"
    pane
    pane
    pane
    |}]

    let%expect_test "standalone inference excludes control and unnamed clients" =
      let line = String.concat "\x1f" in
      let clients =
        [
          line [ "control"; "work"; "$0"; ""; "1" ];
          line [ "/dev/ttys001"; "work"; "$0"; "attached"; "0" ];
          line [ ""; "work"; "$0"; ""; "0" ];
          "junk";
          line [ "invalid"; "work"; "0"; ""; "0" ];
        ]
      in
      List.iter print_endline (real_clients clients);
      [%expect {| /dev/ttys001 |}]

    let pane ?(session = "a") ?(created = 100.) ?(session_id = "$0") ?(index = 0) ?(window = "@1")
        ?(active = false) ?(attached = false) ?(running = false) ?start ?prompt ?run ?(pid = 0)
        ?(cmd = "") ?(cwd = "") ?(title = "") id : t =
      {
        session_name = session;
        session_id = Option.get_exn_or "id" (session_id_of_string session_id);
        session_created = created;
        window_index = index;
        window_id = Option.get_exn_or "id" (window_id_of_string window);
        window_name = "";
        window_layout = "";
        pane_id = Option.get_exn_or "id" (pane_id_of_string id);
        active;
        pane_active = active;
        pane_pid = pid;
        current_command = cmd;
        current_path = cwd;
        alternate_on = false;
        command_running = running;
        command_start = start;
        last_prompt = prompt;
        last_exit = None;
        command_line = "";
        dead_at = None;
        run;
        ssh = None;
        session_attached = attached;
        program_status = { serial = 0; records = [] };
        title;
      }

    let opt f = Option.map_or ~default:"-" f
    let time = opt (Printf.sprintf "%.0f")

    let show (p : t) =
      Printf.printf
        "%s %s created=%.0f win=%d %s %s %s %s active=%b pane_active=%b pid=%d cmd=%s cwd=%s \
         alt=%b running=%b start=%s prompt=%s exit=%s line=%S dead=%s run=%s ssh=%s attached=%b \
         title=%S\n"
        p.session_name
        (session_id_to_string p.session_id)
        p.session_created p.window_index (window_id_to_string p.window_id) p.window_name
        p.window_layout (pane_id_to_string p.pane_id) p.active p.pane_active p.pane_pid
        p.current_command p.current_path p.alternate_on p.command_running (time p.command_start)
        (time p.last_prompt)
        (opt (fun (e : exit) -> Printf.sprintf "%d@%.0f" e.code e.at) p.last_exit)
        p.command_line (time p.dead_at) (opt Fun.id p.run)
        (opt (fun (user, host) -> user ^ "@" ^ host) p.ssh)
        p.session_attached p.title

    let line = String.concat sep

    let%expect_test "the format: title last, no ticking duration, field count pinned" =
      let tokens = String.split ~by:sep format in
      Printf.printf "last=%s duration=%b fields=%d const=%d\n"
        (List.hd (List.rev tokens))
        (String.mem ~sub:"pane_command_duration" format)
        (List.length tokens) fields;
      [%expect {| last=#{pane_title} duration=false fields=27 const=27 |}]

    let%expect_test "a fixture generated from the format parses into every field" =
      let values =
        List.mapi
          (fun i _ ->
            match i with
            | 1 -> "$1"
            | 4 -> "@4"
            | 7 -> "%7"
            | 8 | 12 | 13 | 19 | 21 | 23 -> "1"
            | 16 -> "16"
            | 24 -> "deploy@realm@example.test"
            | 25 -> {|{"serial":7,"records":[{"id":"","state":"working","app":"pi"}]}|}
            | 2 | 3 | 9 | 14 | 15 | 17 | 20 -> string_of_int (1_000_000 + i)
            | _ -> Printf.sprintf "str%d" i)
          (String.split ~by:sep format)
      in
      List.iter
        (fun p ->
          show p;
          Option.iter (fun (user, host) -> Printf.printf "user=%S host=%S\n" user host) p.ssh;
          print_endline (Yojson.Safe.to_string (Program_status.to_yojson p.program_status)))
        (parse [ line values ]);
      [%expect
        {|
    str0 $1 created=1000002 win=1000003 @4 str5 str6 %7 active=true pane_active=true pid=1000009 cmd=str10 cwd=str11 alt=true running=true start=1000014 prompt=1000015 exit=16@1000017 line="str18" dead=1000020 run=str22 ssh=deploy@realm@example.test attached=true title="str26"
    user="deploy@realm" host="example.test"
    {"serial":7,"records":[{"id":"","state":"working","app":"pi"}]}
    |}]

    let%expect_test "rejected program status keeps the pane with no records" =
      List.iter
        (fun status ->
          let values =
            List.mapi
              (fun i _ ->
                match i with
                | 1 -> "$1"
                | 4 -> "@4"
                | 7 -> "%7"
                | 25 -> status
                | 26 -> "kept"
                | _ -> "")
              (String.split ~by:sep format)
          in
          List.iter
            (fun (p : t) ->
              Printf.printf "%s %s %s\n" (pane_id_to_string p.pane_id) p.title
                (Yojson.Safe.to_string (Program_status.to_yojson p.program_status)))
            (parse [ line values ]))
        [
          "invalid JSON";
          {|{"serial":7,"records":[{"id":"","state":"working","msg":"aG Vs bG8="}]}|};
          {|{"serial":0,"records":[]}|};
        ];
      [%expect
        {|
    %7 kept {"serial":0,"records":[]}
    %7 kept {"serial":0,"records":[]}
    %7 kept {"serial":0,"records":[]}
    |}]

    let%expect_test
        "parse: a live pane, a junk line, an empty status, a dead run, a title holding the \
         separator" =
      List.iter show
        (parse
           [
             line
               [
                 "work";
                 "$1";
                 "1700000000";
                 "2";
                 "@7";
                 "win";
                 "layout";
                 "%3";
                 "1";
                 "4242";
                 "claude";
                 "/tmp";
                 "0";
                 "1";
                 "1700000100";
                 "1700000050";
                 "2";
                 "1700000090";
                 "make test";
                 "0";
                 "";
                 "1";
                 "";
                 "1";
                 "";
                 {|{"serial":0,"records":[]}|};
                 "✳ Title";
               ];
             "junk";
             line
               [
                 "work";
                 "$1";
                 "1700000000";
                 "2";
                 "@7";
                 "win";
                 "layout";
                 "%3";
                 "0";
                 "4242";
                 "zsh";
                 "/tmp";
                 "1";
                 "0";
                 "";
                 "1700000050";
                 "";
                 "";
                 "";
                 "0";
                 "";
                 "0";
                 "";
                 "1";
                 "";
                 {|{"serial":0,"records":[]}|};
                 "zsh";
               ];
             line
               [
                 "work";
                 "$1";
                 "1700000000";
                 "2";
                 "@7";
                 "kid";
                 "layout";
                 "%3";
                 "0";
                 "4242";
                 "";
                 "/tmp";
                 "0";
                 "0";
                 "";
                 "";
                 "";
                 "";
                 "";
                 "1";
                 "1700000200";
                 "1";
                 "run-abc";
                 "0";
                 "";
                 {|{"serial":0,"records":[]}|};
                 "kid\x1fmore";
               ];
           ]);
      [%expect
        {|
    work $1 created=1700000000 win=2 @7 win layout %3 active=true pane_active=true pid=4242 cmd=claude cwd=/tmp alt=false running=true start=1700000100 prompt=1700000050 exit=2@1700000090 line="make test" dead=- run=- ssh=- attached=true title="\226\156\179 Title"
    work $1 created=1700000000 win=2 @7 win layout %3 active=false pane_active=true pid=4242 cmd=zsh cwd=/tmp alt=true running=false start=- prompt=1700000050 exit=- line="" dead=- run=- ssh=- attached=false title="zsh"
    work $1 created=1700000000 win=2 @7 kid layout %3 active=false pane_active=false pid=4242 cmd= cwd=/tmp alt=false running=false start=- prompt=- exit=- line="" dead=1700000200 run=run-abc ssh=- attached=true title="kid\031more"
    |}]

    let%expect_test
        "shell: integration, idle, running, the stuck flag healed, a tie read as running" =
      List.iter
        (fun (name, p) ->
          Printf.printf "%s: %s\n" name
            (match shell p with Unintegrated -> "none" | Idle -> "idle" | Running -> "running"))
        [
          ("no integration", pane "%1");
          ("no integration, stale running flag", pane ~running:true ~start:100. "%1");
          ("idle at the prompt", pane ~prompt:200. ~start:100. "%1");
          ("command running", pane ~running:true ~start:300. ~prompt:200. "%1");
          ( "stuck C without D, healed by the next prompt",
            pane ~running:true ~start:300. ~prompt:400. "%1" );
          ( "command started in the prompt's second",
            pane ~running:true ~start:300. ~prompt:300. "%1" );
        ];
      [%expect
        {|
    no integration: none
    no integration, stale running flag: none
    idle at the prompt: idle
    command running: running
    stuck C without D, healed by the next prompt: idle
    command started in the prompt's second: running
    |}]

    let%expect_test
        "order_sessions: oldest session first, windows in list order, panes oldest first" =
      List.iter
        (fun (s : session) ->
          Printf.printf "%s %s:" s.name (session_id_to_string s.id);
          List.iter
            (fun w ->
              Printf.printf " %s[%s]"
                (window_id_to_string (List.hd w).window_id)
                (String.concat " " (List.map (fun (p : t) -> pane_id_to_string p.pane_id) w)))
            s.windows;
          print_newline ())
        (order_sessions
           [
             pane ~session:"b" ~session_id:"$2" ~created:200. ~window:"@3" "%1";
             pane ~session:"b" ~session_id:"$2" ~created:200. ~window:"@4" "%2";
             pane ~session:"a" ~window:"@1" "%3";
             pane ~session:"a" ~window:"@1" "%4";
             pane ~session:"a" ~window:"@2" "%5";
             pane ~session:"c" ~session_id:"$3" ~created:100. ~window:"@5" "%10";
             pane ~session:"c" ~session_id:"$3" ~created:100. ~window:"@5" "%9";
           ]);

      [%expect {|
    a $0: @1[%3 %4] @2[%5]
    c $3: @5[%9 %10]
    b $2: @3[%1] @4[%2]
    |}]

    let focus_panes =
      [
        pane ~session_id:"$0" ~window:"@1" ~active:true ~attached:true "%1";
        pane ~session_id:"$0" ~window:"@2" ~attached:true "%2";
        pane ~session_id:"$1" ~window:"@3" ~active:true "%3";
        pane ~session_id:"$1" ~window:"@3" ~run:"run-1" "%4";
      ]

    let%expect_test "focus, last window, last pane, run pane" =
      List.iter
        (fun w ->
          Printf.printf "%s: focused=%b last_window=%b last_pane=%b run_pane=%s\n" w
            (window_focused focus_panes (Option.get_exn_or "id" (window_id_of_string w)))
            (last_window focus_panes (Option.get_exn_or "id" (window_id_of_string w)))
            (last_pane focus_panes (Option.get_exn_or "id" (window_id_of_string w)))
            (Option.map_or ~default:"-"
               (fun (p : t) -> pane_id_to_string p.pane_id)
               (run_pane focus_panes (Option.get_exn_or "id" (window_id_of_string w)))))
        [ "@1"; "@2"; "@3"; "@999" ];
      [%expect
        {|
    @1: focused=true last_window=false last_pane=true run_pane=-
    @2: focused=false last_window=false last_pane=true run_pane=-
    @3: focused=false last_window=true last_pane=false run_pane=%4
    @999: focused=false last_window=false last_pane=true run_pane=-
    |}]
  end)

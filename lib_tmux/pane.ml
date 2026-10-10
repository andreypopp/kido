type id = string

let of_string s =
  if
    String.length s > 1
    && Char.equal s.[0] '%'
    && String.for_all Char.Ascii.is_digit (String.drop 1 s)
  then Some s
  else None

let to_string id = id
let equal = String.equal

let compare a b =
  Int.compare
    (Option.get_or ~default:0 (int_of_string_opt (String.drop 1 a)))
    (Option.get_or ~default:0 (int_of_string_opt (String.drop 1 b)))

module Map = Map.Make (struct
  type t = id

  let compare = String.compare
end)

let id_to_yojson id = `String (to_string id)
let id_of_yojson = function `String s -> Option.to_result "pane" (of_string s) | _ -> Error "pane"
let optional_id_to_yojson = function None -> `String "" | Some id -> id_to_yojson id

let optional_id_of_yojson = function
  | `String "" -> Ok None
  | json -> Result.map Option.some (id_of_yojson json)

type exit = { code : int; at : float }

type t = {
  session_name : string;
  session_id : Session.id;
  session_created : float;
  window_index : int;
  window_id : Window.id;
  window_name : string;
  window_layout : string;
  pane_id : id;
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
let nonempty s = if String.is_empty s then None else Some s

let parse_line line =
  match Array.of_list (split_n fields line) with
  | f when Array.length f < fields -> None
  | f ->
      let open Option.Infix in
      let* session_id = Session.of_string f.(1) in
      let* window_id = Window.of_string f.(4) in
      let* pane_id = of_string f.(7) in
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
          run = nonempty f.(22);
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
let find panes id = List.find_opt (fun p -> equal p.pane_id id) panes

type session = { name : string; id : Session.id; windows : t list list }

let order_sessions panes =
  let add groups p =
    let mine, others =
      List.partition (fun (first, _) -> String.equal first.session_name p.session_name) groups
    in
    let first, windows = match mine with [ g ] -> g | _ -> (p, []) in
    match windows with
    | (q :: _ as w) :: ws when Window.equal q.window_id p.window_id ->
        (first, (p :: w) :: ws) :: others
    | ws -> (first, [ p ] :: ws) :: others
  in
  List.fold_left add [] panes
  |> List.sort (fun (a, _) (b, _) ->
      match Float.compare a.session_created b.session_created with
      | 0 -> String.compare a.session_name b.session_name
      | c -> c)
  |> List.map (fun (first, windows) ->
      let by_age = List.sort (fun a b -> compare a.pane_id b.pane_id) in
      { name = first.session_name; id = first.session_id; windows = List.rev_map by_age windows })

let watched p = p.active && p.session_attached
let in_window window_id p = Window.equal p.window_id window_id
let window_focused panes window_id = List.exists (fun p -> in_window window_id p && watched p) panes

let last_window panes window_id =
  match List.find_opt (in_window window_id) panes with
  | None -> false
  | Some { session_id; _ } ->
      List.filter (fun p -> Session.equal p.session_id session_id) panes
      |> List.map (fun p -> p.window_id)
      |> List.uniq ~eq:Window.equal |> List.length <= 1

let last_pane panes window_id = List.count (in_window window_id) panes <= 1

let run_pane panes window_id =
  List.find_opt (fun p -> in_window window_id p && Option.is_some p.run) panes

let active_pane panes session =
  List.find_map
    (fun p -> if String.equal p.session_name session && p.active then Some p.pane_id else None)
    panes

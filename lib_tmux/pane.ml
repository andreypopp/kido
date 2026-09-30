type exit = { code : int; at : float }

type t = {
  session_name : string;
  session_id : string;
  session_created : float;
  window_index : int;
  window_id : string;
  window_name : string;
  window_layout : string;
  pane_id : string;
  active : bool;
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
  session_attached : bool;
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
      "#{pane_title}";
    ]

let fields = 24

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
      Some
        {
          session_name = f.(0);
          session_id = f.(1);
          session_created = Float.of_int (int f.(2));
          window_index = int f.(3);
          window_id = f.(4);
          window_name = f.(5);
          window_layout = f.(6);
          pane_id = f.(7);
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
          title = f.(23);
        }

let parse lines = List.filter_map parse_line lines
let find panes id = List.find_opt (fun p -> String.equal p.pane_id id) panes

let is_window_id s =
  String.length s > 1
  && Char.equal s.[0] '@'
  && String.for_all Char.Ascii.is_digit (String.drop 1 s)

type session = { name : string; id : string; windows : t list list }

let pane_num p = int (String.drop 1 p.pane_id)

let order_sessions panes =
  let add groups p =
    let mine, others =
      List.partition (fun (first, _) -> String.equal first.session_name p.session_name) groups
    in
    let first, windows = match mine with [ g ] -> g | _ -> (p, []) in
    match windows with
    | (q :: _ as w) :: ws when String.equal q.window_id p.window_id ->
        (first, (p :: w) :: ws) :: others
    | ws -> (first, [ p ] :: ws) :: others
  in
  List.fold_left add [] panes
  |> List.sort (fun (a, _) (b, _) ->
      match Float.compare a.session_created b.session_created with
      | 0 -> String.compare a.session_name b.session_name
      | c -> c)
  |> List.map (fun (first, windows) ->
      let by_age = List.sort (fun a b -> Int.compare (pane_num a) (pane_num b)) in
      { name = first.session_name; id = first.session_id; windows = List.rev_map by_age windows })

let watched p = p.active && p.session_attached
let in_window window_id p = String.equal p.window_id window_id
let window_focused panes window_id = List.exists (fun p -> in_window window_id p && watched p) panes

let last_window panes window_id =
  match List.find_opt (in_window window_id) panes with
  | None -> false
  | Some { session_id; _ } ->
      List.filter (fun p -> String.equal p.session_id session_id) panes
      |> List.map (fun p -> p.window_id)
      |> List.sort_uniq ~cmp:String.compare
      |> List.length <= 1

let last_pane panes window_id = List.count (in_window window_id) panes <= 1

let run_pane panes window_id =
  List.find_opt (fun p -> in_window window_id p && Option.is_some p.run) panes

let active_pane panes session =
  List.find_map
    (fun p -> if String.equal p.session_name session && p.active then Some p.pane_id else None)
    panes

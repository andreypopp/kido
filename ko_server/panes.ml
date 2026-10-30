type t = {
  config : Config.t;
  mutable next : int;
  mutable panes : Pane.t list;
  mutable removed : Pane.t list;
}

let create config = { config; next = 1; panes = []; removed = [] }
let find t id = List.find_opt (fun p -> String.equal (Pane.id p) id) t.panes
let rows t = List.map Pane.row t.panes
let iter t f = List.iter f t.panes

let add t (request : Protocol.create) ~notify =
  try
    let id = "pane_" ^ string_of_int t.next in
    let cwd = Option.value ~default:t.config.cwd request.cwd in
    let command =
      match request.command with
      | None -> [ t.config.shell; "-l" ]
      | Some (Argv argv) -> argv
      | Some (Shell text) -> [ t.config.shell; "-c"; text ]
    in
    (match command with
    | executable :: _ when not (Filename.is_relative executable) -> ()
    | _ -> invalid_arg "command executable must be absolute");
    if Filename.is_relative cwd then invalid_arg "cwd must be absolute";
    if String.contains cwd '\000' || List.exists (fun s -> String.contains s '\000') command then
      invalid_arg "NUL in pane request";
    (match (Unix.stat cwd).st_kind with
    | Unix.S_DIR -> ()
    | _ -> invalid_arg "cwd must be a directory");
    List.iter
      (fun (k, v) ->
        if
          String.is_empty k || String.contains k '=' || String.contains k '\000'
          || String.contains v '\000'
        then invalid_arg "invalid environment")
      request.env;
    let socket =
      match Config.socket ~create:false t.config.dir with
      | Ok socket -> socket
      | Error message -> invalid_arg message
    in
    let forced =
      [
        ("TERM", "xterm-ghostty");
        ("TERM_PROGRAM", "ko");
        ("TERM_PROGRAM_VERSION", Config.build);
        ("TERMINFO_DIRS", t.config.terminfo ^ ":");
        ("KO_SOCKET", socket);
        ("KO_PANE", id);
      ]
    in
    let overrides =
      forced
      @ List.filter (fun (k, _) -> not (List.mem_assoc ~eq:String.equal k forced)) request.env
    in
    let inherited =
      List.filter
        (fun entry ->
          let name = List.hd (String.split_on_char '=' entry) in
          not (List.mem_assoc ~eq:String.equal name overrides))
        t.config.env
    in
    let env = List.map (fun (k, v) -> k ^ "=" ^ v) overrides @ inherited in
    let pane = Pane.create t.config ~id ~cwd ~command ~env ~notify in
    t.next <- t.next + 1;
    t.panes <- t.panes @ [ pane ];
    Ok pane
  with Invalid_argument message -> Error message

let remove t pane =
  Pane.shutdown pane;
  t.panes <- List.filter (fun p -> not (String.equal (Pane.id p) (Pane.id pane))) t.panes;
  t.removed <- pane :: t.removed

let shutdown t = List.iter Pane.shutdown (t.panes @ t.removed)
let kill t = List.iter Pane.kill (t.panes @ t.removed)

let reap t =
  List.iter (fun p -> Pane_proc.reap (Pane.proc p)) (t.panes @ t.removed);
  t.removed <- List.filter (fun p -> not (Pane_proc.finished (Pane.proc p))) t.removed

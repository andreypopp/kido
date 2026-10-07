type id = string

let parse_id s =
  if
    String.length s > 1
    && String.length s <= 9
    && Char.equal s.[0] 'A'
    && String.for_all
         (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
         (String.sub s 1 (String.length s - 1))
  then Ok s
  else Error (Printf.sprintf "invalid ask id %S" s)

let string_of_id id = id
let id_to_yojson id = `String id
let id_of_yojson = function `String s -> parse_id s | _ -> Error "invalid ask id"

type t = {
  id : id;
  session : string;
  session_file : string; [@key "sessionFile"]
  cwd : string;
  name : string;
  text : string;
  created : Timestamp.t;
}
[@@deriving yojson]

let path ~dir id = Filename.concat (Filename.concat dir "asks") (id ^ ".json")

let read ~dir id =
  Option.flat_map
    (fun text ->
      try Result.to_opt (of_yojson (Yojson.Safe.from_string text))
      with Yojson.Json_error _ -> None)
    (Fs.read (path ~dir id))

let list ~dir =
  let asks = Filename.concat dir "asks" in
  (if Sys.file_exists asks then Array.to_list (Sys.readdir asks) else [])
  |> List.filter_map (fun file ->
      Option.flat_map
        (fun id -> Option.flat_map (read ~dir) (Result.to_opt (parse_id id)))
        (String.chop_suffix ~suf:".json" file))
  |> List.sort (fun a b ->
      let c = Float.compare a.created b.created in
      if c = 0 then String.compare a.id b.id else c)

let caller ~dir ~self ~session =
  let open Result.Infix in
  let live = State.load_live ~dir in
  let* caller =
    if String.is_empty session then
      Ok (Option.flat_map (fun self -> Tmux.Pane.Map.find_opt self (State.by_pane live)) self)
    else
      match List.assoc_opt ~eq:String.equal session live with
      | Some s when Option.equal Tmux.Pane.equal s.pane self -> Ok (Some (session, s))
      | _ -> Error "no calling agent session has reported this pane"
  in
  let* panes, programs =
    if Option.is_none self then Ok ([], Tmux.Pane.Map.empty) else Tmux.Exec.panes_and_programs ()
  in
  let pane = Option.flat_map (Tmux.Pane.find panes) self in
  let id =
    match caller with
    | Some (id, _) -> Some id
    | None -> Option.flat_map (fun (p : Tmux.Pane.t) -> p.run) pane
  in
  let run =
    Option.flat_map
      (fun id -> Option.flat_map (Subrun.read_meta ~dir) (Result.to_opt (Subrun.parse_id id)))
      id
  in
  if Option.exists (fun (m : Subrun.meta) -> not (String.is_empty m.parent_session)) run then
    Error "user asks are for top-level agents only"
  else
    match (caller, pane) with
    | None, _ -> Ok None
    | Some (id, s), Some p -> Ok (Some (id, s, p, programs))
    | Some _, None -> Error "calling pane not found"

let invalidate ?(removed = false) ~dir ~self ask =
  if not (String.equal self ask.session) then
    Option.iter
      (fun (s : State.session) ->
        if not (String.is_empty s.inbox) then
          ignore
            (Msg.deliver ~path:s.inbox
               (Yojson.Safe.to_string
                  (Msg.envelope_to_yojson
                     {
                       kind = Asks;
                       id = Msg.new_id ();
                       from = { session = ""; name = "kido"; pane = None };
                       reply_to = "";
                       text =
                         (if removed then
                            Printf.sprintf "The user removed ask %s: %s" ask.id
                              (List.hd (String.split_on_char '\n' ask.text))
                          else "");
                       run = "";
                       output = "";
                     }))))
      (State.get_live ~dir ask.session)

let record ~dir ~self ~replaces ~session ~session_file ~cwd ~name ~text ~now =
  if String.is_empty (String.trim text) then Error "no question given"
  else if String.is_empty session_file then Error "no pi session file given"
  else if not (String.equal (Msg.valid_utf_8 text) text) then Error "question is not valid UTF-8"
  else
    let write id place =
      let ask = { id; session; session_file; cwd; name; text; created = now } in
      Fs.write_temp ~perm:0o600 (path ~dir id) (Yojson.Safe.to_string (to_yojson ask)) place;
      invalidate ~dir ~self ask;
      Ok id
    in
    match replaces with
    | Some id -> (
        match read ~dir id with
        | None -> Error ("no ask " ^ id)
        | Some old ->
            let result = write id Unix.rename in
            if not (String.equal old.session session) then invalidate ~dir ~self old;
            result)
    | None ->
        Fs.mkdir_p ~perm:0o700 (Filename.concat dir "asks");
        let rec create () =
          let id = "A" ^ String.sub (Msg.new_id ()) 0 8 in
          match write id Unix.link with
          | result -> result
          | exception Unix.Unix_error (EEXIST, _, _) -> create ()
        in
        create ()

let remove ~dir ~self id =
  match read ~dir id with
  | None -> Error ("no ask " ^ id)
  | Some ask -> (
      match Unix.unlink (path ~dir id) with
      | () ->
          invalidate ~removed:true ~dir ~self ask;
          Ok ()
      | exception Unix.Unix_error (ENOENT, _, _) -> Error ("no ask " ^ id))

let to_json ~live ask =
  match to_yojson ask with
  | `Assoc fields ->
      `Assoc (fields @ [ ("ended", `Bool (not (List.mem_assoc ~eq:String.equal ask.session live))) ])
  | json -> json

let revival_error ask =
  let directory =
    try match (Unix.stat ask.cwd).st_kind with Unix.S_DIR -> true | _ -> false
    with Unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> false
  in
  if not directory then Some ("ask directory is gone: " ^ ask.cwd)
  else if not (Tmux.Exec.is_file ask.session_file) then
    Some ("pi session file is gone: " ^ ask.session_file)
  else None

let target ~socket ~dir ~session ask =
  match List.assoc_opt ~eq:String.equal ask.session (State.load_live ~dir) with
  | Some { pane = Some pane; _ } -> Ok pane
  | _ -> (
      match revival_error ask with
      | Some e -> Error e
      | None ->
          Result.map
            (fun (w : Tmux.Exec.window) -> w.pane_id)
            (Tmux.Exec.new_window ?socket ~remain_on_exit:false ~session ~name:("ask-" ^ ask.id)
               ~cwd:ask.cwd ~env:[]
               [ "pi"; "--session"; ask.session_file ]))

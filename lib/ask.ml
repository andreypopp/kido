type id = string [@@deriving yojson_of]

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

let id_of_yojson json =
  match json with
  | `String s when Result.is_ok (parse_id s) -> s
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "invalid ask id" json

type t = { id : id; session : string; text : string; created : Timestamp.t } [@@deriving yojson]

let path ~dir id = Filename.concat (Filename.concat dir "asks") (id ^ ".json")
let read ~dir id = Fs.read_json (path ~dir id) t_of_yojson

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

let caller ~dir caller =
  if
    Option.exists
      (fun (id, _) ->
        Option.is_some
          (Option.flat_map (fun (m : Subrun.meta) -> m.parent) (Subrun.read_meta ~dir id)))
      caller
  then Error "user asks are for top-level agents only"
  else Ok caller

let invalidate ?(removed = false) ~dir ~self ask =
  if not (String.equal self ask.session) then
    Option.iter
      (fun (s : Subrun.pi) ->
        if not (String.is_empty s.inbox) then
          ignore
            (Msg.deliver_envelope ~path:s.inbox
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
               }))
      (Subrun.live_pi ~dir ask.session)

let record ~dir ~replaces ~session ~text ~now =
  if String.is_empty (String.trim text) then Error "no question given"
  else if not (String.equal (Msg.valid_utf_8 text) text) then Error "question is not valid UTF-8"
  else
    let write id place =
      let ask = { id; session; text; created = now } in
      Fs.write_temp ~perm:0o600 (path ~dir id) (Yojson.Safe.to_string (yojson_of_t ask)) place;
      Ok id
    in
    match replaces with
    | Some id -> (
        match read ~dir id with
        | None -> Error ("no ask " ^ id)
        | Some old ->
            let result = write id Unix.rename in
            if not (String.equal old.session session) then invalidate ~dir ~self:session old;
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

let name ~panes run =
  match (Option.flat_map Subrun.holder run, run) with
  | Some pi, _ -> State.display_name panes pi
  | None, Some r -> Subrun.name r
  | None, None -> ""

let to_json ~panes ask run =
  Yojson.Safe.Util.combine (yojson_of_t ask)
    (`Assoc
       [
         ("name", `String (name ~panes run));
         ("ended", `Bool (Option.is_none (Option.flat_map Subrun.holder run)));
       ])

let revival run =
  let cwd = Option.map_or ~default:"" (fun (r : Subrun.run) -> r.meta.cwd) run
  and file =
    Option.map_or ~default:""
      (fun (p : Subrun.pi) -> p.session_file)
      (Option.flat_map (fun (r : Subrun.run) -> r.pi) run)
  in
  let directory =
    try match (Unix.stat cwd).st_kind with Unix.S_DIR -> true | _ -> false
    with Unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> false
  in
  if not directory then Error ("ask directory is gone: " ^ cwd)
  else if not (Fs.is_file file) then Error ("pi session file is gone: " ^ file)
  else Ok (cwd, file)

let target ~tmux ~dir ~session ask =
  let run = Subrun.load ~dir ask.session in
  match Option.flat_map Subrun.holder run with
  | Some { pane = Some pane; _ } -> Ok pane
  | _ ->
      Result.flat_map
        (fun (cwd, file) ->
          Result.map
            (fun (w : Tmux.window) -> w.pane_id)
            (Tmux.new_window tmux ~session ~name:("ask-" ^ ask.id) ~cwd ~env:[]
               [ "pi"; "--session"; file ]))
        (revival run)

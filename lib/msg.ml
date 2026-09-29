let sun_path_max = 103

let inbox_path ~dir name =
  if String.is_empty name then failwith "empty name";
  if String.contains name '/' then Cli.failf "name %S contains a path separator" name;
  if String.mem ~sub:".." name then Cli.failf "name %S contains %S" name "..";
  let dir =
    Filename.concat
      (if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir)
      "inbox"
  in
  let path = Filename.concat dir (name ^ ".sock") in
  if String.length path > sun_path_max then
    Cli.failf "socket path is %d bytes, over the %d-byte limit: %s" (String.length path)
      sun_path_max path;
  Fs.mkdir_p (Filename.dirname dir);
  Fs.mkdir_p ~perm:0o700 dir;
  path

let v1 = 1

type kind = Message | Ask | Reply | Notice | Stream | Steer | Interrupt | Stop | Other of string

let string_of_kind = function
  | Message -> "message"
  | Ask -> "ask"
  | Reply -> "reply"
  | Notice -> "notice"
  | Stream -> "stream"
  | Steer -> "steer"
  | Interrupt -> "interrupt"
  | Stop -> "stop"
  | Other s -> s

let kinds =
  List.map
    (fun k -> (string_of_kind k, k))
    [ Message; Ask; Reply; Notice; Stream; Steer; Interrupt; Stop ]

let kind_of_string s = Option.get_or ~default:(Other s) (List.assoc_opt ~eq:String.equal s kinds)
let kind_to_yojson k = `String (string_of_kind k)
let kind_of_yojson = function `String s -> Ok (kind_of_string s) | _ -> Error "kind"

type from = {
  session : string; [@default ""]
  name : string; [@default ""]
  pane : string; [@default ""]
}
[@@deriving of_yojson { strict = false }]

let optional key v = if String.is_empty v then [] else [ (key, `String v) ]

let from_to_yojson f =
  `Assoc ((("session", `String f.session) :: optional "name" f.name) @ optional "pane" f.pane)

let no_from = { session = ""; name = ""; pane = "" }

type envelope = {
  v : int;
  kind : kind;
  id : string; [@default ""]
  from : from; [@default no_from]
  reply_to : string; [@key "replyTo"] [@default ""]
  text : string; [@default ""]
  run : string; [@default ""]
  output : string; [@default ""]
}
[@@deriving of_yojson { strict = false }]

let envelope_to_yojson e =
  `Assoc
    ([
       ("v", `Int e.v);
       ("kind", kind_to_yojson e.kind);
       ("id", `String e.id);
       ("from", from_to_yojson e.from);
     ]
    @ optional "replyTo" e.reply_to
    @ [ ("text", `String e.text) ]
    @ optional "run" e.run @ optional "output" e.output)

let parse raw =
  match Yojson.Safe.from_string raw with
  | `Assoc fields as json ->
      if List.mem_assoc ~eq:String.equal "v" fields && List.mem_assoc ~eq:String.equal "kind" fields
      then Result.to_opt (envelope_of_yojson json)
      else None
  | _ | (exception _) -> None

let new_id () =
  let buf = Bytes.create 16 in
  let fd = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let rec fill pos = if pos < 16 then fill (pos + Unix.read fd buf pos (16 - pos)) in
      fill 0);
  String.concat "" (List.init 16 (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get buf i))))

type error = Unavailable of string | Refused of string | Failed of string

let string_of_error = function
  | Unavailable why -> "no agent listening on the inbox: " ^ why
  | Refused m | Failed m -> m

exception Timeout

let describe = function Unix.Unix_error (e, _, _) -> Unix.error_message e | _ -> "timed out"

let wait fd ~write deadline =
  let timeout = deadline -. Unix.gettimeofday () in
  if Float.(timeout <= 0.) then raise Timeout;
  let r, w, _ =
    if write then Unix.select [] [ fd ] [] timeout else Unix.select [ fd ] [] [] timeout
  in
  if List.is_empty r && List.is_empty w then raise Timeout

let connect path deadline =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (try
     Unix.set_nonblock fd;
     try Unix.connect fd (Unix.ADDR_UNIX path)
     with Unix.Unix_error (Unix.EINPROGRESS, _, _) -> (
       wait fd ~write:true deadline;
       match Unix.getsockopt_error fd with
       | Some err -> raise (Unix.Unix_error (err, "connect", path))
       | None -> ())
   with e ->
     Unix.close fd;
     raise e);
  fd

let write_all fd s deadline =
  let n = String.length s in
  let pos = ref 0 in
  while !pos < n do
    wait fd ~write:true deadline;
    match Unix.write_substring fd s !pos (n - !pos) with
    | w -> pos := !pos + w
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
  done

let read_all fd deadline =
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 65536 in
  let rec loop () =
    wait fd ~write:false deadline;
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf chunk 0 n;
        loop ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> loop ()
  in
  loop ();
  Buffer.contents buf

let deliver ?(timeout = 2.) ~path text =
  if String.is_empty path then Error (Unavailable "no socket path")
  else if String.length path > sun_path_max then
    Error
      (Unavailable
         (Printf.sprintf "socket path is %d bytes, over the %d-byte limit" (String.length path)
            sun_path_max))
  else
    let deadline = Unix.gettimeofday () +. timeout in
    match connect path deadline with
    | exception ((Timeout | Unix.Unix_error _) as e) ->
        Error (Unavailable (Printf.sprintf "%s: %s" path (describe e)))
    | fd ->
        Fun.protect
          ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
          (fun () ->
            match
              write_all fd text deadline;
              Unix.shutdown fd Unix.SHUTDOWN_SEND;
              read_all fd deadline
            with
            | reply -> (
                match String.trim reply with
                | "ok" -> Ok ()
                | "refused" ->
                    Error
                      (Refused
                         (Printf.sprintf
                            "inbox %s: ask refused: the target already has an ask outstanding to \
                             the asker"
                            path))
                | got ->
                    Error (Failed (Printf.sprintf "inbox %s: answered %S, want \"ok\"" path got)))
            | exception ((Timeout | Unix.Unix_error _) as e) ->
                Error (Failed (Printf.sprintf "inbox %s: %s" path (describe e))))

let send ~id (session : State.session) env =
  if String.is_empty session.inbox then
    Error (Unavailable (Printf.sprintf "session %s has no inbox" id))
  else deliver ~path:session.inbox (Yojson.Safe.to_string (envelope_to_yojson env))

let notify ~dir ~parent_session ~from text =
  let live = State.load_live ~dir in
  match List.assoc_opt ~eq:String.equal parent_session live with
  | None ->
      Error
        (Failed
           (Printf.sprintf "no live process holds session %S; the parent is gone, nothing sent"
              parent_session))
  | Some target ->
      send ~id:parent_session target
        { v = v1; kind = Notice; id = new_id (); from; reply_to = ""; text; run = ""; output = "" }

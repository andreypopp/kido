let sun_path_max = 103

let inbox_path ~dir name =
  let dir =
    Filename.concat
      (if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir)
      "inbox"
  in
  let path = Filename.concat dir (name ^ ".sock") in
  if String.is_empty name then Error "empty name"
  else if String.contains name '/' then
    Error (Printf.sprintf "name %S contains a path separator" name)
  else if String.mem ~sub:".." name then Error (Printf.sprintf "name %S contains %S" name "..")
  else if String.length path > sun_path_max then
    Error
      (Printf.sprintf "socket path is %d bytes, over the %d-byte limit: %s" (String.length path)
         sun_path_max path)
  else Ok path

type kind = Message | Ask | Reply | Notice | Stream | Steer | Interrupt | Stop

let string_of_kind = function
  | Message -> "message"
  | Ask -> "ask"
  | Reply -> "reply"
  | Notice -> "notice"
  | Stream -> "stream"
  | Steer -> "steer"
  | Interrupt -> "interrupt"
  | Stop -> "stop"

let kind_to_yojson k = `String (string_of_kind k)

type from = { session : string; name : string; [@default ""] pane : string [@default ""] }
[@@deriving to_yojson]

type envelope = {
  kind : kind;
  id : string;
  from : from;
  reply_to : string; [@key "replyTo"] [@default ""]
  text : string;
  run : string; [@default ""]
  output : string; [@default ""]
}
[@@deriving to_yojson]

let envelope_to_yojson e =
  Yojson.Safe.Util.combine (`Assoc [ ("v", `Int 1) ]) (envelope_to_yojson e)

let max_notice_bytes = 4000

let utf_8_prefix s n =
  let rec boundary n = if n > 0 && Char.code s.[n] land 0xC0 = 0x80 then boundary (n - 1) else n in
  if String.length s <= n then s else String.sub s 0 (boundary (Int.max 0 n))

let valid_utf_8 s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let n = Uchar.utf_decode_length d in
      if Uchar.utf_decode_is_valid d then Buffer.add_substring b s i n
      else Buffer.add_string b "\u{FFFD}";
      go (i + n)
    end
  in
  go 0;
  Buffer.contents b

let new_id () =
  Digest.to_hex (In_channel.with_open_bin "/dev/urandom" (fun ic -> really_input_string ic 16))

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

let live_parent live session =
  Option.to_result
    (Printf.sprintf "no live process holds session %S; the parent is gone, nothing sent" session)
    (List.assoc_opt ~eq:String.equal session live)

let notify ~dir ~parent_session ~from text =
  match live_parent (State.load_live ~dir) parent_session with
  | Error m -> Error (Failed m)
  | Ok (target : State.session) when String.is_empty target.inbox ->
      Error (Unavailable (Printf.sprintf "session %s has no inbox" parent_session))
  | Ok target ->
      deliver ~path:target.inbox
        (Yojson.Safe.to_string
           (envelope_to_yojson
              { kind = Notice; id = new_id (); from; reply_to = ""; text; run = ""; output = "" }))

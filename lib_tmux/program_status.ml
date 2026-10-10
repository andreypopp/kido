type kind = Permission | Question | Auth

type state =
  | Idle
  | Working of int option
  | Done
  | Blocked of { kind : kind option; progress : int option }
  | Error

type record = {
  id : string;
  state : state;
  app : string option;
  title : string option;
  msg : string option;
}

type t = { serial : int; records : record list }

let root t = List.find_opt (fun r -> String.is_empty r.id) t.records

let decode s =
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let s =
    if String.length s mod 4 = 0 then s
    else if String.contains s '=' || String.length s mod 4 = 1 then raise Exit
    else s ^ String.make (4 - (String.length s mod 4)) '='
  in
  let n = String.length s in
  let out = Buffer.create n in
  let digit c = match String.index_opt alphabet c with Some i -> i | None -> raise Exit in
  for i = 0 to (n / 4) - 1 do
    let at = i * 4 in
    let a = digit s.[at] and b = digit s.[at + 1] in
    let c = s.[at + 2] and d = s.[at + 3] in
    Buffer.add_char out (Char.chr ((a lsl 2) lor (b lsr 4)));
    if Char.equal c '=' then (
      if (not (Char.equal d '=')) || i <> (n / 4) - 1 || b land 15 <> 0 then raise Exit)
    else
      let c = digit c in
      Buffer.add_char out (Char.chr (((b land 15) lsl 4) lor (c lsr 2)));
      if Char.equal d '=' then (if i <> (n / 4) - 1 || c land 3 <> 0 then raise Exit)
      else Buffer.add_char out (Char.chr (((c land 3) lsl 6) lor digit d))
  done;
  let s = Buffer.contents out in
  if not (String.is_valid_utf_8 s) then raise Exit;
  s

let parse json =
  let open Yojson.Safe.Util in
  let optional f key json = match member key json with `Null -> None | v -> Some (f v) in
  let record json =
    let kind =
      optional
        (fun v ->
          match to_string v with
          | "permission" -> Permission
          | "question" -> Question
          | "auth" -> Auth
          | _ -> raise Exit)
        "kind" json
    in
    let progress = optional to_int "progress" json in
    if Option.exists (fun n -> n < 0 || n > 100) progress then raise Exit;
    let state =
      match member "state" json |> to_string with
      | "idle" -> Idle
      | "working" -> Working progress
      | "done" -> Done
      | "blocked" -> Blocked { kind; progress }
      | "error" -> Error
      | _ -> raise Exit
    in
    {
      id = member "id" json |> to_string;
      state;
      app = optional to_string "app" json;
      title = optional (fun v -> decode (to_string v)) "title" json;
      msg = optional (fun v -> decode (to_string v)) "msg" json;
    }
  in
  try
    let json = Yojson.Safe.from_string json in
    let serial = member "serial" json |> to_int in
    if serial < 0 then raise Exit;
    let records =
      member "records" json |> to_list |> List.map record
      |> List.sort (fun a b -> String.compare a.id b.id)
    in
    let rec unique = function
      | a :: (b :: _ as rest) -> (not (String.equal a.id b.id)) && unique rest
      | _ -> true
    in
    if not (unique records) then raise Exit;
    Ok { serial; records }
  with Exit | Yojson.Json_error _ | Type_error _ -> Error "invalid program status"

let representative ?seen t =
  let rank = function Blocked _ -> 0 | Error -> 1 | Working _ -> 2 | Done -> 3 | Idle -> 4 in
  List.fold_left
    (fun best r ->
      match r.state with
      | (Done | Error) when Option.exists (fun serial -> serial >= t.serial) seen -> best
      | _ -> (
          match best with
          | Some b
            when let order = Int.compare (rank b.state) (rank r.state) in
                 (if order = 0 then String.compare b.id r.id else order) <= 0 ->
              best
          | _ -> Some r))
    None t.records

let app t record =
  let rec find id =
    match List.find_opt (fun r -> String.equal r.id id) t.records with
    | Some { app = Some app; _ } -> Some app
    | _ when String.is_empty id -> None
    | _ -> find (match String.rindex_opt id '/' with None -> "" | Some i -> String.sub id 0 i)
  in
  find record.id

let progress r =
  match r.state with
  | Working progress | Blocked { progress; _ } -> progress
  | Idle | Done | Error -> None

let to_yojson t =
  let record r =
    let state =
      match r.state with
      | Idle -> "idle"
      | Working _ -> "working"
      | Done -> "done"
      | Blocked _ -> "blocked"
      | Error -> "error"
    in
    let optional key f = Option.map_or ~default:[] (fun v -> [ (key, f v) ]) in
    `Assoc
      ([ ("id", `String r.id); ("state", `String state) ]
      @ optional "app" (fun s -> `String s) r.app
      @ optional "kind"
          (fun k ->
            `String
              (match k with Permission -> "permission" | Question -> "question" | Auth -> "auth"))
          (match r.state with Blocked { kind; _ } -> kind | _ -> None)
      @ optional "progress" (fun n -> `Int n) (progress r)
      @ optional "title" (fun s -> `String s) r.title
      @ optional "msg" (fun s -> `String s) r.msg)
  in
  `Assoc [ ("serial", `Int t.serial); ("records", `List (List.map record t.records)) ]

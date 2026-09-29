module Int_map = Map.Make (Int)
module Int_set = Set.Make (Int)

type ssh_session = { host : string; interactive : bool }
type scan = { ssh : ssh_session Int_map.t; pi : Int_set.t }
type ssh_args = { opts : string list; letters : string; dest : string; command : string list }
type process = { pid : int; ppid : int; comm : string; args : string list }

let split_fields out =
  String.lines out
  |> List.filter_map (fun line ->
      let spaced = String.map (fun c -> if Char.is_whitespace_ascii c then ' ' else c) line in
      match String.split_on_char ' ' spaced |> List.filter (fun f -> not (String.is_empty f)) with
      | [] -> None
      | fields -> Some fields)

let ps args =
  match Unix.open_process_args_in "ps" (Array.of_list ("ps" :: args)) with
  | exception Unix.Unix_error _ -> []
  | ic -> (
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with Unix.WEXITED 0 -> split_fields out | _ -> [])

let parse_ssh args =
  let dest opts letters dest command = Some { opts = List.rev opts; letters; dest; command } in
  let rec go opts letters = function
    | [] | [ "--" ] -> None
    | "--" :: d :: command -> dest opts letters d command
    | d :: command when String.equal d "-" || not (String.prefix ~pre:"-" d) ->
        dest opts letters d command
    | arg :: rest -> (
        let n = String.length arg in
        let rec scan j letters =
          if j >= n then (letters, false)
          else
            let letters = letters ^ String.make 1 arg.[j] in
            if String.contains "BbcDEeFIiJLlmOoPpQRSWw" arg.[j] then (letters, j = n - 1)
            else scan (j + 1) letters
        in
        match (scan 1 letters, rest) with
        | (letters, true), v :: rest -> go (v :: arg :: opts) letters rest
        | (letters, _), _ -> go (arg :: opts) letters rest)
  in
  go [] "" args

let ssh_session args =
  parse_ssh args
  |> Option.map (fun a ->
      let has c = String.contains a.letters c in
      {
        host = Option.value (String.chop_prefix ~pre:"ssh://" a.dest) ~default:a.dest;
        interactive = has 'N' || has 't' || ((not (has 'T')) && List.is_empty a.command);
      })

let parse_processes rows =
  List.filter_map
    (function
      | pid :: ppid :: comm :: args -> (
          match (Int.of_string pid, Int.of_string ppid, args) with
          | Some pid, Some ppid, _ :: _ -> Some { pid; ppid; comm; args }
          | _ -> None)
      | _ -> None)
    rows

let parse_parent = function
  | (ppid :: comm :: _) :: _ -> Option.map (fun ppid -> (ppid, comm)) (Int.of_string ppid)
  | _ -> None

let is_shell comm = List.mem (Filename.basename comm) [ "sh"; "dash"; "bash"; "zsh"; "ksh" ]

let is_pi p =
  (match p.args with a :: _ -> String.equal (Filename.basename a) "pi" | [] -> false)
  || List.exists (String.suffix ~suf:"/libexec/bin/pi") p.args

let mark_ancestors parent pid set =
  let rec go n pid set =
    if n = 0 || pid <= 1 || Int_set.mem pid set then set
    else
      let set = Int_set.add pid set in
      match Int_map.find_opt pid parent with Some ppid -> go (n - 1) ppid set | None -> set
  in
  go 64 pid set

let sweep () =
  let all = parse_processes (ps [ "-axo"; "pid=,ppid=,comm=,args=" ]) in
  let parent = Int_map.of_list (List.map (fun p -> (p.pid, p.ppid)) all) in
  List.fold_left
    (fun scan p ->
      let ssh =
        match ssh_session (List.tl p.args) with
        | Some s when String.equal (Filename.basename p.comm) "ssh" ->
            scan.ssh |> Int_map.add p.pid s |> Int_map.add p.ppid s
        | _ -> scan.ssh
      in
      { ssh; pi = (if is_pi p then mark_ancestors parent p.pid scan.pi else scan.pi) })
    { ssh = Int_map.empty; pi = Int_set.empty }
    all

let maybe_pi command = String.equal command "node" || String.equal command "pi"

let reporter_pid () =
  let rec go n pid =
    match parse_parent (ps [ "-o"; "ppid=,comm="; "-p"; Int.to_string pid ]) with
    | Some (ppid, comm) when n > 0 && is_shell comm -> go (n - 1) ppid
    | _ -> pid
  in
  go 3 (Unix.getppid ())

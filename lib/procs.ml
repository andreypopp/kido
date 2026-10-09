type ssh_args = { opts : string list; letters : string; dest : string; command : string list }

let split_fields out =
  String.lines out
  |> List.filter_map (fun line ->
      let spaced = String.map (fun c -> if Char.is_whitespace_ascii c then ' ' else c) line in
      match String.split_on_char ' ' spaced |> List.filter (fun f -> not (String.is_empty f)) with
      | [] -> None
      | fields -> Some fields)

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

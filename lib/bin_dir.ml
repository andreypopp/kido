let of_exe exe =
  Tmux.Exec.candidates exe
  |> List.map (fun c ->
      Filename.concat (Filename.dirname (Filename.dirname c)) "share/kido/bin/tmux")
  |> List.find_opt Tmux.Exec.is_file |> Option.map Filename.dirname
  |> Option.filter (fun d -> not (String.contains d ':'))

let own () = of_exe (Lazy.force Tmux.Exec.self)
let split path = if String.is_empty path then [] else String.split_on_char ':' path

let path_with_first dir path =
  String.concat ":" (dir :: List.filter (fun e -> not (String.equal e dir)) (split path))

let stat p = try Some (Unix.stat p) with Unix.Unix_error _ -> None

let same a b =
  match (a, b) with
  | Some (a : Unix.stats), Some (b : Unix.stats) -> a.st_dev = b.st_dev && a.st_ino = b.st_ino
  | _ -> false

let same_file a b = same (stat a) (stat b)

let look_path_past ~path ~dir name =
  let dir_st = stat dir and shim_st = stat (Filename.concat dir name) in
  let is_dir e = same (stat e) dir_st in
  let entries = List.map (fun e -> if String.is_empty e then "." else e) (split path) in
  let search =
    match List.drop_while (fun e -> not (is_dir e)) entries with
    | [] -> entries
    | _ :: after -> after
  in
  List.find_map
    (fun e ->
      let c = Filename.concat e name in
      if (not (is_dir e)) && Tmux.Exec.is_executable c && not (same (stat c) shim_st) then Some c
      else None)
    search

let path_prepend_script dir =
  Printf.sprintf
    {|
# Written by kido shell: its bin directory goes first on PATH, after the
# login files that may have rewritten PATH, and only once.
_kido_bin=%s
_kido_rest=":$PATH:"
while :; do
  case $_kido_rest in
  *":$_kido_bin:"*) _kido_rest="${_kido_rest%%%%":$_kido_bin:"*}:${_kido_rest#*":$_kido_bin:"}" ;;
  *) break ;;
  esac
done
_kido_rest=${_kido_rest#:}
_kido_rest=${_kido_rest%%:}
PATH="$_kido_bin${_kido_rest:+:$_kido_rest}"
export PATH
unset _kido_bin _kido_rest
|}
    (Filename.quote dir)

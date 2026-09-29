type t = float

let now = Unix.gettimeofday

let to_string t =
  let us = Float.to_int (Float.round (t *. 1e6)) in
  let tm = Unix.gmtime (Float.of_int (us / 1_000_000)) in
  let frac =
    match us mod 1_000_000 with
    | 0 -> ""
    | f -> "." ^ String.rdrop_while (Char.equal '0') (Printf.sprintf "%06d" f)
  in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d%sZ" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec frac

let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = (((153 * if m > 2 then m - 3 else m + 9) + 2) / 5) + d - 1 in
  (era * 146097) + (yoe * 365) + (yoe / 4) - (yoe / 100) + doy - 719468

let of_string s =
  try
    Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d:%2d%[.0-9]Z%!" (fun y mo d h mi sec frac ->
        let whole = (((((days_from_civil y mo d * 24) + h) * 60) + mi) * 60) + sec in
        Some
          (Float.of_int whole +. if String.is_empty frac then 0. else Float.of_string ("0" ^ frac)))
  with Scanf.Scan_failure _ | End_of_file | Failure _ -> None

let to_yojson t = `String (to_string t)

let of_yojson = function
  | `String s -> Option.to_result "not an RFC 3339 UTC timestamp" (of_string s)
  | _ -> Error "not a timestamp"

let duration d =
  let ms = Float.to_int (Float.round (d *. 1000.)) in
  if ms = 0 then "0s"
  else if abs ms < 1000 then Printf.sprintf "%dms" ms
  else
    let s = ms / 1000 in
    let secs =
      match ms mod 1000 with
      | 0 -> string_of_int (s mod 60)
      | f ->
          Printf.sprintf "%d.%s" (s mod 60)
            (String.rdrop_while (Char.equal '0') (Printf.sprintf "%03d" f))
    in
    if s >= 3600 then Printf.sprintf "%dh%dm%ss" (s / 3600) (s / 60 mod 60) secs
    else if s >= 60 then Printf.sprintf "%dm%ss" (s / 60) secs
    else secs ^ "s"

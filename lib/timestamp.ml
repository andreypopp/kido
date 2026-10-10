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
    Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d:%2d%[.0-9]%s@!" (fun y mo d h mi sec frac zone ->
        let offset =
          match zone with
          | "Z" -> Some 0
          | _ ->
              Scanf.sscanf zone "%c%2d:%2d%!" (fun sign oh om ->
                  match sign with
                  | '+' -> Some ((oh * 60) + om)
                  | '-' -> Some (-((oh * 60) + om))
                  | _ -> None)
        in
        Option.map
          (fun offset ->
            let whole = (((((days_from_civil y mo d * 24) + h) * 60) + mi - offset) * 60) + sec in
            Float.of_int whole +. if String.is_empty frac then 0. else Float.of_string ("0" ^ frac))
          offset)
  with Scanf.Scan_failure _ | End_of_file | Failure _ -> None

let to_yojson t = `String (to_string t)

let of_yojson = function
  | `String s -> Option.to_result "not an RFC 3339 timestamp" (of_string s)
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

let to_local_string t =
  let whole = Float.to_int (Float.round t) in
  let tm = Unix.localtime (Float.of_int whole) in
  let local =
    ((((days_from_civil (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday * 24) + tm.tm_hour) * 60)
    + tm.tm_min)
    * 60
    + tm.tm_sec
  in
  let offset = (local - whole) / 60 in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d%s" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec
    (if offset = 0 then "Z"
     else
       Printf.sprintf "%c%02d:%02d"
         (if offset < 0 then '-' else '+')
         (abs offset / 60)
         (abs offset mod 60))

let ms_env getenv name default =
  match Option.flat_map Int.of_string (getenv name) with
  | Some ms when ms > 0 -> Float.of_int ms /. 1000.
  | _ -> default

let%test_module "Tests" =
  (module struct
    let%expect_test "timestamps round-trip through RFC 3339" =
      List.iter
        (fun t ->
          let s = to_string t in
          Printf.printf "%s %b\n" s
            (Option.exists (fun t' -> Float.(abs (t' - t) < 1e-6)) (of_string s)))
        [ 0.; 1_700_000_000.; 1_700_000_000.5; 951_782_400.123456 ];
      print_endline (Option.map_or ~default:"none" to_string (of_string "junk"));
      List.iter
        (fun s -> print_endline (Option.map_or ~default:"none" to_string (of_string s)))
        [ "2026-09-29T16:36:24.275927+02:00"; "2026-09-29T11:06:24-03:30"; "2026-09-29T14:36:24+2" ];
      [%expect
        {|
    1970-01-01T00:00:00Z true
    2023-11-14T22:13:20Z true
    2023-11-14T22:13:20.5Z true
    2000-02-29T00:00:00.123456Z true
    none
    2026-09-29T14:36:24.275927Z
    2026-09-29T14:36:24Z
    none
    |}]
  end)

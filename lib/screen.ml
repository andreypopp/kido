let is_rule line =
  let t = String.trim line in
  String.length t >= 4 && String.is_empty (String.replace ~sub:"─" ~by:"" t)

let at_input_prompt lines =
  let lines =
    Array.of_list
      (List.rev (List.drop_while (fun l -> String.is_empty (String.trim l)) (List.rev lines)))
  in
  let n = Array.length lines in
  let rec find_down i stop =
    if i < stop then None else if is_rule lines.(i) then Some i else find_down (i - 1) stop
  in
  match find_down (n - 1) (max 0 (n - 3)) with
  | None -> false
  | Some bottom -> (
      match find_down (bottom - 1) 0 with
      | Some top when top + 1 < bottom ->
          String.prefix ~pre:"❯" (String.ltrim lines.(top + 1))
          && not
               (Array.exists (String.mem ~sub:"to interrupt")
                  (Array.sub lines (bottom + 1) (n - bottom - 1)))
      | Some _ | None -> false)

let order ~id ~parent items =
  let items = Array.of_list items in
  let n = Array.length items in
  let index = Hashtbl.create n in
  Array.iteri (fun i it -> Hashtbl.replace index (id it) i) items;
  let root = -1 in
  let children = Hashtbl.create n in
  Array.iteri
    (fun i it ->
      let p = match Hashtbl.find_opt index (parent it) with Some j when j <> i -> j | _ -> root in
      Hashtbl.replace children p (i :: Option.get_or ~default:[] (Hashtbl.find_opt children p)))
    items;
  let child_list p = List.rev (Option.get_or ~default:[] (Hashtbl.find_opt children p)) in
  let seen = Array.make n false in
  let out = ref [] in
  let rec visit i =
    if not seen.(i) then begin
      seen.(i) <- true;
      out := items.(i) :: !out;
      List.iter visit (child_list i)
    end
  in
  List.iter visit (child_list root);
  for i = 0 to n - 1 do
    visit i
  done;
  List.rev !out

let order ~id ~parent items =
  let items = Array.of_list items in
  let n = Array.length items in
  let index = Hashtbl.create n in
  Array.iteri (fun i it -> Hashtbl.replace index (id it) i) items;
  let root = -1 in
  let children = Hashtbl.create n in
  Array.iteri
    (fun i it ->
      let p =
        match Option.flat_map (Hashtbl.find_opt index) (parent it) with
        | Some j when j <> i -> j
        | _ -> root
      in
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

let%test_module "Tests" =
  (module struct
    let show_order items =
      List.map fst
        (order ~id:fst ~parent:(fun (_, p) -> if String.is_empty p then None else Some p) items)

    let%expect_test "Order keeps every item, whatever the parent edges say" =
      let cases =
        [
          ("empty", []);
          ("one root", [ ("a", "") ]);
          ("self-parent", [ ("a", "a") ]);
          ("two-cycle", [ ("a", "b"); ("b", "a") ]);
          ("three-cycle", [ ("a", "c"); ("b", "a"); ("c", "b") ]);
          ("cycle with a child", [ ("a", "b"); ("b", "a"); ("c", "a") ]);
          ("absent parent", [ ("a", "ghost"); ("b", "") ]);
          ("duplicate ids", [ ("a", ""); ("a", ""); ("b", "a") ]);
          ("chain four deep", [ ("d", "c"); ("c", "b"); ("b", "a"); ("a", "") ]);
          ("two roots, one deep", [ ("a", ""); ("b", "a"); ("c", ""); ("d", "b") ]);
        ]
      in
      List.iter
        (fun (name, items) ->
          let got = show_order items in
          let want = Hashtbl.create 8 in
          List.iter
            (fun (id, _) ->
              Hashtbl.replace want id (1 + Option.get_or ~default:0 (Hashtbl.find_opt want id)))
            items;
          List.iter
            (fun id ->
              Hashtbl.replace want id (Option.get_or ~default:0 (Hashtbl.find_opt want id) - 1))
            got;
          let balanced = Hashtbl.fold (fun _ n ok -> ok && n = 0) want true in
          Printf.printf "%-22s count=%b:%d=%d\n" name balanced (List.length got) (List.length items))
        cases;
      [%expect
        {|
    empty                  count=true:0=0
    one root               count=true:1=1
    self-parent            count=true:1=1
    two-cycle              count=true:2=2
    three-cycle            count=true:3=3
    cycle with a child     count=true:3=3
    absent parent          count=true:2=2
    duplicate ids          count=true:3=3
    chain four deep        count=true:4=4
    two roots, one deep    count=true:4=4
    |}]

    let%expect_test "Order is parent-first and stable" =
      let items =
        [ ("shell", ""); ("kid2", "top"); ("top", ""); ("kid1", "top"); ("grandkid", "kid2") ]
      in
      print_endline (String.concat "," (show_order items));
      [%expect {| shell,top,kid2,grandkid,kid1 |}]

    let%expect_test "Order is deterministic across repeated runs" =
      let items =
        List.init 40 (fun i -> (string_of_int i, if i = 0 then "" else string_of_int (i mod 7)))
      in
      let first = String.concat "," (show_order items) in
      let all_match =
        List.for_all
          (fun _ -> String.equal (String.concat "," (show_order items)) first)
          (List.init 20 Fun.id)
      in
      Printf.printf "%b\n" all_match;
      [%expect {| true |}]
  end)

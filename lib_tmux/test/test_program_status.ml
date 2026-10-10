open Tmux.Program_status

let%expect_test "parse validates and orders full records" =
  List.iter
    (fun json ->
      match parse json with
      | Error e -> print_endline e
      | Ok status -> print_endline (Yojson.Safe.to_string (to_yojson status)))
    [
      {|{"serial":2,"records":[{"id":"z","state":"done","title":"8J+YgA=="},{"id":"","state":"working","app":"pi"}]}|};
      {|{"serial":1,"records":[{"id":"","state":"future"}]}|};
      {|{"serial":1,"records":[{"id":""}]}|};
      {|{"records":[]}|};
      {|{"serial":1,"records":[{"id":"","state":"done","msg":"??=="}]}|};
      {|{"serial":1,"records":[{"id":"","state":"done","msg":"/w=="}]}|};
      {|{"serial":1,"records":[{"id":"","state":"done","progress":101}]}|};
      {|{"serial":1,"records":[{"id":"","state":"done"},{"id":"","state":"idle"}]}|};
    ];
  [%expect
    {| 
    {"serial":2,"records":[{"id":"","state":"working","app":"pi"},{"id":"z","state":"done","title":"😀"}]}
    invalid program status
    invalid program status
    invalid program status
    invalid program status
    invalid program status
    invalid program status
    invalid program status
    |}]

let%expect_test "optional base64 padding" =
  List.iter
    (fun encoded ->
      match
        parse
          (Printf.sprintf {|{"serial":1,"records":[{"id":"","state":"done","title":%S}]}|} encoded)
      with
      | Ok t ->
          Printf.printf "%s: %s\n" encoded (Option.get_exn_or "title" (List.hd t.records).title)
      | Error e -> Printf.printf "%s: %s\n" encoded e)
    [ "QQ"; "QUI"; "QQ=="; "QUI="; "8J+YgA"; "Q"; "Q=="; "QQ="; "QR"; "QUJ" ];
  [%expect
    {|
    QQ: A
    QUI: AB
    QQ==: A
    QUI=: AB
    8J+YgA: 😀
    Q: invalid program status
    Q==: invalid program status
    QQ=: invalid program status
    QR: invalid program status
    QUJ: invalid program status
    |}]

let%expect_test "representative priority, tie ordering and visit acknowledgement" =
  let get s = parse s |> Result.get_or_failwith in
  let status =
    get
      {|{"serial":8,"records":[{"id":"b","state":"blocked"},{"id":"a","state":"blocked"},{"id":"","state":"error"},{"id":"c","state":"working"},{"id":"d","state":"done"},{"id":"e","state":"idle"}]}|}
  in
  let rec show records =
    match representative { status with records } with
    | None -> ()
    | Some r ->
        print_endline r.id;
        show (List.filter (fun x -> not (String.equal x.id r.id)) records)
  in
  show status.records;
  let siblings =
    {
      status with
      records =
        List.filter (fun r -> List.mem ~eq:String.equal r.id [ ""; "c"; "d" ]) status.records;
    }
  in
  Printf.printf "acknowledged terminal siblings: %s\n"
    (Option.get_exn_or "representative" (representative ~seen:8 siblings)).id;
  Printf.printf "newer terminal siblings: %S\n"
    (Option.get_exn_or "representative" (representative ~seen:7 siblings)).id;
  let completed =
    { status with records = List.filter (fun r -> String.equal r.id "d") status.records }
  in
  Printf.printf "acknowledged only: %b\n" (Option.is_none (representative ~seen:8 completed));
  let inherited =
    get
      {|{"serial":1,"records":[{"id":"","state":"working","app":"root"},{"id":"a","state":"idle","app":"nearest"},{"id":"a/b/c","state":"working"}]}|}
  in
  List.iter
    (fun r -> Printf.printf "%s=%s\n" r.id (Option.value ~default:"none" (app inherited r)))
    inherited.records;

  [%expect
    {|
    a
    b

    c
    d
    e
    acknowledged terminal siblings: c
    newer terminal siblings: ""
    acknowledged only: true
    =root
    a=nearest
    a/b/c=nearest
    |}]

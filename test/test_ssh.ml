open Kido

let%expect_test "an option's value is not read as more option letters" =
  let a =
    Option.get_exn_or "parsed" (Procs.parse_ssh [ "-o"; "ProxyCommand=none"; "-p"; "22"; "host" ])
  in
  Printf.printf "%s %b\n" a.letters (Ssh.can_prime a ~tty:true);
  [%expect {| op true |}]

let%expect_test "what cannot be primed reaches ssh as the user spelled it" =
  List.iter
    (fun (args, tty) ->
      Printf.printf "%s: %b\n" (String.concat " " args)
        (List.equal String.equal (Ssh.args args ~tty) ("ssh" :: args)))
    [
      ([ "host" ], false);
      ([ "host"; "uptime" ], true);
      ([ "-V" ], true);
      ([ "-N"; "-L"; "8080:localhost:80"; "host" ], true);
      ([ "-T"; "host" ], true);
      ([ "-W"; "other:22"; "host" ], true);
      ([ "-f"; "host" ], true);
      ([ "-s"; "host"; "sftp" ], true);
      ([ "-O"; "check"; "host" ], true);
    ];
  [%expect
    {|
    host: true
    host uptime: true
    -V: true
    -N -L 8080:localhost:80 host: true
    -T host: true
    -W other:22 host: true
    -f host: true
    -s host sftp: true
    -O check host: true
    |}]

let%expect_test "a primed command line: the user's options, -t, the destination, the bootstrap" =
  match List.rev (Ssh.args [ "-o"; "BatchMode=yes"; "-A"; "deploy@host" ] ~tty:true) with
  | boot :: rest ->
      Printf.printf "%s, bootstrap %b\n"
        (String.concat " " (List.rev rest))
        (String.equal boot Prime.ssh_bootstrap);
      [%expect {| ssh -o BatchMode=yes -A -t deploy@host, bootstrap true |}]
  | [] -> assert false

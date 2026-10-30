external uid_of_fd_storage : nativeint -> int = "ko_spike_peer_uid"

let uid pipe =
  match Luv.Handle.fileno pipe with
  | Error e -> Error (Luv.Error.strerror e)
  | Ok fd -> Ok (uid_of_fd_storage Ctypes.(raw_address_of_ptr (to_voidp (addr fd))))

let%test_module "Tests" =
  (module struct
    let ok = function Ok v -> v | Error e -> failwith (Luv.Error.strerror e)

    let%expect_test "the peer of an accepted unix connection is this uid" =
      let dir = Filename.temp_dir "peer" "" in
      let path = Filename.concat dir "s" in
      let server = ok (Luv.Pipe.init ()) in
      ok (Luv.Pipe.bind server path);
      let seen = ref None in
      Luv.Stream.listen server (fun r ->
          ok r;
          let client = ok (Luv.Pipe.init ()) in
          ok (Luv.Stream.accept ~server ~client);
          seen := Some (uid client);
          Luv.Handle.close client ignore;
          Luv.Handle.close server ignore);
      let conn = ok (Luv.Pipe.init ()) in
      Luv.Pipe.connect conn path (fun r ->
          ok r;
          Luv.Handle.close conn ignore);
      ignore (Luv.Loop.run () : bool);
      Unix.rmdir dir;
      (match !seen with
      | Some (Ok u) -> Printf.printf "uid matches: %b\n" (u = Unix.getuid ())
      | Some (Error e) -> print_endline e
      | None -> print_endline "no connection");
      [%expect {| uid matches: true |}]

    let%expect_test "a plain pipe has no peer credentials" =
      let r, w = ok (Luv.Pipe.pipe ()) in
      let p = ok (Luv.Pipe.init ()) in
      ok (Luv.Pipe.open_ p r);
      (match uid p with
      | Ok _ -> print_endline "uid"
      | Error e -> print_endline e
      | exception Unix.Unix_error (Unix.ENOTSOCK, call, _) -> print_endline ("ENOTSOCK from " ^ call));
      Luv.Handle.close p ignore;
      ignore (Luv.File.close w ignore);
      ignore (Luv.Loop.run () : bool);
      [%expect {| ENOTSOCK from getsockopt |}]
  end)

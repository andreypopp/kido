let ok = function
  | Ok value -> value
  | Error error -> raise (Unix.Unix_error (Unix.EIO, Luv.Error.strerror error, ""))

let file (fd : Unix.file_descr) : Luv.File.t = Obj.magic fd

let fd stream =
  match Luv.Handle.fileno stream with
  | Error error -> Error (Luv.Error.strerror error)
  | Ok storage ->
      Ok (Obj.magic Ctypes.(!@(from_voidp int (to_voidp (addr storage)))) : Unix.file_descr)

(* After a read that filled the buffer, libuv calls the read callback with 0 on EAGAIN and Luv
   reports that as `UNKNOWN. libuv clears the readable flag before it reports a real error. *)
let read_start ?allocate stream callback =
  Luv.Stream.read_start ?allocate stream (function
    | Error `UNKNOWN when Luv.Stream.is_readable stream -> ()
    | result -> callback result)

external peer_uid : Unix.file_descr -> int = "ko_peer_uid"
external peer_pid : Unix.file_descr -> int = "ko_peer_pid"
external now : unit -> int = "ko_now" [@@noalloc]
external sigchld : unit -> int = "ko_sigchld" [@@noalloc]
external native_signal : int -> int = "ko_native_signal" [@@noalloc]

let%test_module "Tests" =
  (module struct
    let%expect_test "a read that fills the buffer and then finds the pipe empty is no error" =
      let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let size = 4096 in
      Printf.printf "wrote %d\n" (Unix.write_substring a (String.make size 'x') 0 size);
      let pipe = ok (Luv.Pipe.init ()) in
      ok (Luv.Pipe.open_ pipe (file b));
      let received = ref 0 and errors = ref [] in
      read_start pipe
        ~allocate:(fun _ -> Luv.Buffer.create size)
        (function
          | Ok chunk -> received := !received + Luv.Buffer.size chunk
          | Error error ->
              errors := Luv.Error.err_name error :: !errors;
              Luv.Handle.close pipe ignore);
      let check = ok (Luv.Check.init ()) in
      ok
        (Luv.Check.start check (fun () ->
             Luv.Handle.close check ignore;
             Luv.Handle.close pipe ignore));
      ignore (Luv.Loop.run () : bool);
      Unix.close a;
      Printf.printf "received %d, errors [%s]\n" !received (String.concat ";" !errors);
      [%expect {|
        wrote 4096
        received 4096, errors []
      |}]
  end)

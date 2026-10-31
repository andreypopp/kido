type identity = { ppid : int; pgid : int; sid : int; start : int }

external identity : int -> identity option = "ko_process_identity"

type t = int

let of_int pid =
  let own_pid = Unix.getpid () in
  if pid <= 1 || pid > 0x7fffffff || pid = own_pid then None
  else
    match identity own_pid with Some own when own.pgid <> pid -> Some pid | Some _ | None -> None

let to_int = Fun.id

let signal pid number =
  match Unix.kill pid number with
  | () -> Ok ()
  | exception Unix.Unix_error (error, _, _) -> Error error

module Group = struct
  type nonrec t = { leader : t; start : int }
  type verdict = Child of t | Gone | Foreign

  let judge ~parent pid found =
    match found with
    | None -> Gone
    | Some i when i.ppid = parent && i.pgid = pid && i.sid = pid ->
        Child { leader = pid; start = i.start }
    | Some _ -> Foreign

  let verify ~parent pid =
    match of_int pid with None -> Foreign | Some pid -> judge ~parent pid (identity pid)

  let leader group = group.leader

  let signal group number =
    match identity group.leader with
    | Some i when i.start = group.start && i.pgid = group.leader -> (
        (* macOS can return EPERM for a process group with only zombies or exiting processes. *)
        try Unix.kill (-group.leader) number
        with Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> ())
    | Some _ | None -> ()
end

let%test_module "Tests" =
  (module struct
    let killed_by_sigkill child =
      let deadline = Unix.gettimeofday () +. 10. in
      let rec loop () =
        match Unix.waitpid [ Unix.WNOHANG ] child with
        | 0, _ when Float.(Unix.gettimeofday () < deadline) ->
            Unix.sleepf 0.005;
            loop ()
        | _, Unix.WSIGNALED n -> n = Sys.sigkill
        | _ -> false
      in
      loop ()

    let%expect_test "of_int refuses what no caller may signal and accepts a child" =
      let own_pgid = (Option.get (identity (Unix.getpid ()))).pgid in
      let show label pid = Printf.printf "%s: %b\n" label (Option.is_some (of_int pid)) in
      show "-1" (-1);
      show "-4294967295" (-4294967295);
      show "4294967295" 4294967295;
      show "2147483648" 0x80000000;
      show "0" 0;
      show "1" 1;
      show "own pid" (Unix.getpid ());
      show "own pgid" own_pgid;
      let child =
        Unix.create_process "sleep" [| "sleep"; "30" |] Unix.stdin Unix.stdout Unix.stderr
      in
      show "child" child;
      (match of_int child with
      | Some pid ->
          Printf.printf "signal: %b\n" (Result.is_ok (signal pid Sys.sigkill));
          Printf.printf "killed by SIGKILL: %b\n" (killed_by_sigkill child)
      | None ->
          Unix.kill child Sys.sigkill;
          ignore (Unix.waitpid [] child));
      [%expect
        {|
        -1: false
        -4294967295: false
        4294967295: false
        2147483648: false
        0: false
        1: false
        own pid: false
        own pgid: false
        child: true
        signal: true
        killed by SIGKILL: true
      |}]

    let%expect_test "only the parent's own session leader is a child" =
      let parent = 4242 in
      let found = Some { ppid = parent; pgid = 900; sid = 900; start = 7 } in
      let show label = function
        | Group.Child { leader; start } -> Printf.printf "%s: child %d at %d\n" label leader start
        | Gone -> Printf.printf "%s: gone\n" label
        | Foreign -> Printf.printf "%s: refused\n" label
      in
      let verdict ?(found = found) label = show label (Group.judge ~parent 900 found) in
      verdict "other parent" ~found:(Some { ppid = 1; pgid = 900; sid = 900; start = 7 });
      verdict "not group leader" ~found:(Some { ppid = parent; pgid = 1; sid = 900; start = 7 });
      verdict "not session leader" ~found:(Some { ppid = parent; pgid = 900; sid = 1; start = 7 });
      verdict "own child";
      verdict "gone" ~found:None;
      [%expect
        {|
        other parent: refused
        not group leader: refused
        not session leader: refused
        own child: child 900 at 7
        gone: gone
      |}]

    let%expect_test "only a group that matches its recorded start is signalled" =
      let out, in_ = Unix.pipe () in
      let program = "use POSIX; $|=1; POSIX::setsid(); print qq(up\\n); exec q(sleep), q(30)" in
      let child =
        Unix.create_process "perl" [| "perl"; "-e"; program |] Unix.stdin in_ Unix.stderr
      in
      Unix.close in_;
      (match Unix.select [ out ] [] [] 10. with
      | [], _, _ -> print_endline "child did not start"
      | _ -> ignore (Unix.read out (Bytes.create 3) 0 3 : int));
      Unix.close out;
      (match Group.verify ~parent:(Unix.getpid ()) child with
      | Child verified ->
          Printf.printf "verified own child: %b\n" (verified.leader = child);
          Group.signal { verified with start = verified.start + 1 } Sys.sigkill;
          Printf.printf "tampered start skipped: %b\n"
            (fst (Unix.waitpid [ Unix.WNOHANG ] child) = 0);
          Group.signal verified Sys.sigkill
      | Gone | Foreign ->
          Unix.kill child Sys.sigkill;
          print_endline "child not verified");
      Printf.printf "killed by SIGKILL: %b\n" (killed_by_sigkill child);
      [%expect
        {|
        verified own child: true
        tampered start skipped: true
        killed by SIGKILL: true
      |}]
  end)

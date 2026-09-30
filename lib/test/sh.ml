let temp () = Filename.temp_dir "kido-test" ""

let write ?(perm = 0o755) path body =
  Kido.Fs.mkdir_p (Filename.dirname path);
  Kido.Fs.write ~perm path body;
  path

(* In its own session, with no controlling terminal: an interactive zsh prefers /dev/tty over a
   piped stdin whenever one is attached. *)
let run ?(stdin = "") ~env prog argv =
  let in_r, in_w = Unix.pipe ~cloexec:true () and out_r, out_w = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 -> (
      try
        ignore (Unix.setsid ());
        Unix.dup2 ~cloexec:false in_r Unix.stdin;
        Unix.dup2 ~cloexec:false out_w Unix.stdout;
        Unix.dup2 ~cloexec:false out_w Unix.stderr;
        Unix.execve prog (Array.of_list argv) (Array.of_list env)
      with _ -> Unix._exit 127)
  | pid ->
      Unix.close in_r;
      Unix.close out_w;
      Tmux.Exec.write_all in_w stdin;
      Unix.close in_w;
      let deadline = Unix.gettimeofday () +. 30. in
      let buf = Buffer.create 4096 and chunk = Bytes.create 4096 in
      let rec read () =
        let left = deadline -. Unix.gettimeofday () in
        match Unix.select [ out_r ] [] [] (Float.max left 0.) with
        | [], _, _ ->
            Unix.kill pid Sys.sigkill;
            ignore (Unix.waitpid [] pid);
            failwith (Printf.sprintf "%s timed out; output so far %S" prog (Buffer.contents buf))
        | _ -> (
            match Unix.read out_r chunk 0 4096 with
            | 0 -> ()
            | n ->
                Buffer.add_subbytes buf chunk 0 n;
                read ())
      in
      read ();
      Unix.close out_r;
      (snd (Unix.waitpid [] pid), Buffer.contents buf)

let output ?stdin ~env prog argv =
  match run ?stdin ~env prog argv with
  | WEXITED 0, out -> out
  | _, out -> failwith (Printf.sprintf "%s failed: %S" prog out)

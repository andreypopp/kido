let temp () = Filename.temp_dir "kido-test" ""

let write ?(perm = 0o755) path body =
  Fs.mkdir_p (Filename.dirname path);
  Fs.write ~perm path body;
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
      Fs.write_all in_w stdin;
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

let check what ok = if not ok then print_endline ("FAILED: " ^ what)
let osc133 out = List.exists (fun c -> String.mem ~sub:("\027]133;" ^ c) out) [ "A"; "C"; "D" ]

let reports what out =
  List.iter
    (fun m -> check (Printf.sprintf "%s reports %S in %S" what m out) (String.mem ~sub:m out))
    [ "\027]133;A"; "\027]133;C;cmdline=true"; "\027]133;D;0" ]

let zsh_home rc =
  let home = temp () in
  ignore (write ~perm:0o644 (Filename.concat home ".zshrc") ("PS1='remote%% '\n" ^ rc));
  home

let interactive_zsh ~path () =
  Fs.look_path ~path "zsh"
  |> Option.map (fun real ->
      write
        (Filename.concat (temp ()) "zsh")
        ("#!/bin/sh\n[ \"$2\" = \"-c\" ] && exit 0\nexec " ^ real ^ " -i \"$@\"\n"))

let base ~path ~home shell = [ "PATH=" ^ path; "HOME=" ^ home; "SHELL=" ^ shell; "TERM=dumb" ]

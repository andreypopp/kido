open Tmux

let now = Unix.gettimeofday

let elapsed f =
  let t0 = now () in
  f ();
  now () -. t0

let show = function
  | Ok lines -> Printf.printf "ok [%s]\n%!" (String.concat " | " lines)
  | Error e -> Printf.printf "error %s\n%!" e

let control_clients () =
  Exec.run [ "list-clients"; "-F"; "#{client_control_mode} #{client_session}" ]
  |> String.split_on_char '\n'
  |> List.filter (String.prefix ~pre:"1 ")

let probe () =
  Sys.set_signal Sys.sigpipe Signal_ignore;
  let conn = Conn.connect "" in
  show (Conn.run conn "display-message -p hello");
  show (Conn.run conn ("display-message -p " ^ Conn.quote "it's #{session_name}"));
  show (Conn.run conn "bogus");
  List.iter
    (fun (p : Pane.t) -> Printf.printf "pane %s %s %s\n" p.session_name p.window_id p.pane_id)
    (Conn.list_panes conn);
  Printf.printf "a fresh connection notifies: %b\n"
    Float.(elapsed (fun () -> Conn.wait conn 5.) < 1.);
  let quiet = elapsed (fun () -> Conn.wait conn 0.3) in
  Printf.printf "a quiet wait runs to its deadline: %b\n" Float.(quiet >= 0.3 && quiet < 1.);
  ignore (Exec.run [ "new-window"; "-d"; "-t"; "work:"; "sleep 600" ]);
  Printf.printf "a new window notifies: %b\n" Float.(elapsed (fun () -> Conn.wait conn 5.) < 1.);
  ignore (Exec.run [ "new-session"; "-d"; "-s"; "other"; "sleep 600" ]);
  Conn.wait conn 0.5;
  ignore (Exec.run [ "split-window"; "-d"; "-t"; "other:"; "sleep 600" ]);
  Printf.printf "a split in an unfollowed session notifies: %b\n"
    Float.(elapsed (fun () -> Conn.wait conn 1.) < 0.9);
  Conn.follow conn "other";
  Printf.printf "control clients after follow: [%s]\n" (String.concat "; " (control_clients ()));
  Conn.wait conn 0.5;
  ignore (Exec.run [ "split-window"; "-d"; "-t"; "other:"; "sleep 600" ]);
  Printf.printf "a split in the followed session notifies: %b\n"
    Float.(elapsed (fun () -> Conn.wait conn 1.) < 0.9);
  show (Conn.run conn "run-shell 'sleep 3'");
  show (Conn.run conn "display-message -p stuck");
  show (Conn.run conn "display-message -p gap");
  Printf.printf "panes through the fallback: %d\n" (List.length (Conn.list_panes conn));
  Unix.sleepf 0.25;
  show (Conn.run conn "display-message -p back");
  Printf.printf "control clients after the redial: [%s]\n" (String.concat "; " (control_clients ()));
  ignore (Exec.run [ "kill-server" ]);
  show (Conn.run conn "display-message -p gone");
  (match Conn.list_panes conn with
  | _ -> print_endline "fallback without a server: panes"
  | exception Failure _ -> print_endline "fallback without a server: failed");
  Conn.close conn;
  show (Conn.run conn "display-message -p closed")

(* The server lives on its own socket: a wrapper passes -S to the fork, and
   the probe runs in a child whose KIDO_TMUX names that wrapper, so no tmux
   call here can reach the server this test was started under. *)
let () =
  match Sys.argv with
  | [| _; "probe" |] -> probe ()
  | _ ->
      let fork = Sys.getenv "KIDO_TMUX" in
      let dir = Filename.temp_dir "kido-conn" "" in
      let sock = Printf.sprintf "/tmp/kido-conn-%d.sock" (Unix.getpid ()) in
      let wrapper = Filename.concat dir "tmux" in
      Out_channel.with_open_bin wrapper (fun oc ->
          Printf.fprintf oc "#!/bin/sh\nexec '%s' -S '%s' \"$@\"\n" fork sock);
      Unix.chmod wrapper 0o755;
      let tmux args =
        let null = Unix.openfile "/dev/null" [ O_WRONLY ] 0 in
        let pid =
          Unix.create_process wrapper (Array.of_list (wrapper :: args)) Unix.stdin null null
        in
        Unix.close null;
        ignore (Unix.waitpid [] pid)
      in
      tmux
        [
          "-f"; "/dev/null"; "new-session"; "-d"; "-s"; "work"; "-x"; "80"; "-y"; "24"; "sleep 600";
        ];
      Fun.protect
        ~finally:(fun () ->
          tmux [ "kill-server" ];
          (try Sys.remove sock with Sys_error _ -> ());
          Sys.remove wrapper;
          Sys.rmdir dir)
        (fun () ->
          let inherited =
            Array.to_list (Unix.environment ())
            |> List.filter (fun kv ->
                not (String.prefix ~pre:"TMUX" kv || String.prefix ~pre:"KIDO_" kv))
          in
          let env = Array.of_list (("KIDO_TMUX=" ^ wrapper) :: inherited) in
          let pid =
            Unix.create_process_env Sys.executable_name
              [| Sys.executable_name; "probe" |]
              env Unix.stdin Unix.stdout Unix.stderr
          in
          match snd (Unix.waitpid [] pid) with
          | WEXITED 0 -> ()
          | WEXITED n -> Printf.printf "probe exited %d\n" n
          | WSIGNALED n | WSTOPPED n -> Printf.printf "probe killed by signal %d\n" n)

open Tmux

let now = Unix.gettimeofday

let elapsed f =
  let t0 = now () in
  f ();
  now () -. t0

let show = function
  | Ok lines -> Printf.printf "ok [%s]\n%!" (String.concat " | " (String.split_on_char '\n' lines))
  | Error e -> Printf.printf "error %s\n%!" e

let tmux args =
  let bin = Sys.getenv "KIDO_TMUX" in
  let ic = Unix.open_process_args_in bin (Array.of_list (bin :: args)) in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  out

let control_clients () =
  tmux [ "list-clients"; "-F"; "#{client_control_mode} #{client_session}" ]
  |> String.lines
  |> List.filter (String.prefix ~pre:"1 ")

let probe () =
  Sys.set_signal Sys.sigpipe Signal_ignore;
  let conn = Tmux.Client.connect (Tmux.create ()) ~client:"" in
  show (Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; "hello" ]);
  show (Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; "it's #{session_name}" ]);
  show (Tmux.exec (Tmux.Client.tmux conn) [ "bogus" ]);
  List.iter
    (fun (p : Kido.Tmux_pane.t) ->
      Printf.printf "pane %s %s %s\n" p.session_name (window_id_to_string p.window_id)
        (pane_id_to_string p.pane_id))
    (Result.get_exn (Kido.Tmux_pane.list_panes (Tmux.Client.tmux conn)));
  Printf.printf "a fresh connection notifies: %b\n"
    Float.(elapsed (fun () -> Tmux.Client.await_notifications conn ~timeout:5.) < 1.);
  let quiet = elapsed (fun () -> Tmux.Client.await_notifications conn ~timeout:0.3) in
  Printf.printf "a quiet wait runs to its deadline: %b\n" Float.(quiet >= 0.3 && quiet < 1.);
  ignore (tmux [ "new-window"; "-d"; "-t"; "work:"; "sleep 600" ]);
  Printf.printf "a new window notifies: %b\n"
    Float.(elapsed (fun () -> Tmux.Client.await_notifications conn ~timeout:5.) < 1.);
  let other =
    tmux [ "new-session"; "-d"; "-P"; "-F"; "#{session_id}"; "-s"; "other"; "sleep 600" ]
    |> String.trim |> session_id_of_string |> Option.get_exn_or "session id"
  in
  Tmux.Client.await_notifications conn ~timeout:0.5;
  ignore (tmux [ "split-window"; "-d"; "-t"; "other:"; "sleep 600" ]);
  Printf.printf "a split in an unfollowed session notifies: %b\n"
    Float.(elapsed (fun () -> Tmux.Client.await_notifications conn ~timeout:1.) < 0.9);
  Tmux.Client.follow conn other;
  Printf.printf "control clients after follow: [%s]\n" (String.concat "; " (control_clients ()));
  Tmux.Client.await_notifications conn ~timeout:0.5;
  ignore (tmux [ "split-window"; "-d"; "-t"; "other:"; "sleep 600" ]);
  Printf.printf "a split in the followed session notifies: %b\n"
    Float.(elapsed (fun () -> Tmux.Client.await_notifications conn ~timeout:1.) < 0.9);
  show (Tmux.exec (Tmux.Client.tmux conn) [ "run-shell"; "sleep 3" ]);
  show (Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; "stuck" ]);
  show (Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; "gap" ]);
  Printf.printf "panes through the fallback: %d\n"
    (List.length (Result.get_exn (Kido.Tmux_pane.list_panes (Tmux.Client.tmux conn))));
  Unix.sleepf 0.25;
  show (Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; "back" ]);
  Printf.printf "control clients after the redial: [%s]\n" (String.concat "; " (control_clients ()));
  ignore (tmux [ "kill-server" ]);
  show (Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; "gone" ]);
  (match Kido.Tmux_pane.list_panes (Tmux.Client.tmux conn) with
  | Ok _ -> print_endline "fallback without a server: panes"
  | Error _ -> print_endline "fallback without a server: failed");
  Tmux.Client.close conn;
  show (Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; "closed" ])

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

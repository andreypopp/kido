open Ko_server

type server = { state : State.t; pane : Pane.t; dir : string }

let with_server ~command ~activity f =
  let sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  let dir = Filename.temp_dir ~perms:0o700 "kofuzz-" "" in
  Unix.mkfifo (dir ^ "/in") 0o600;
  let config =
    {
      Config.dir;
      socket = dir ^ "/socket";
      pane_exe = Filename.concat (Sys.getcwd ()) "../../ko_pane/ko-pane";
      terminfo = dir;
      shell = "/bin/sh";
      limits = Config.scrollback_limits (1 lsl 30);
      env = Array.to_list (Unix.environment ());
      cwd = "/tmp";
    }
  in
  let state = State.create config ~activity in
  let panes = State.panes state in
  let cleanup () =
    Panes.shutdown panes;
    let deadline = Unix.gettimeofday () +. 2. in
    let finished () =
      Panes.reap panes;
      Panes.reaped panes
    in
    ignore (Luv.Loop.run ~mode:`NOWAIT () : bool);
    while Float.(Unix.gettimeofday () < deadline) && not (finished ()) do
      Panes.kill panes;
      ignore (Luv.Loop.run ~mode:`NOWAIT () : bool);
      Unix.sleepf 0.002
    done;
    Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
    Sys.rmdir dir;
    Sys.set_signal Sys.sigpipe sigpipe
  in
  match
    Panes.add panes
      { cwd = None; command = Some (Argv [ "/bin/sh"; "-c"; command dir ]); env = [] }
      ~notify:(State.event state)
  with
  | Error message ->
      cleanup ();
      failwith message
  | Ok pane -> Fun.protect ~finally:cleanup (fun () -> f { state; pane; dir })

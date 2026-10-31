let run config =
  let socket = config.Config.socket in
  let server = Uv.ok (Luv.Pipe.init ()) in
  match Luv.Pipe.bind server socket with
  | Error error ->
      Luv.Handle.close server ignore;
      Error (Luv.Error.strerror error)
  | Ok () ->
      let state = State.create config in
      let connections = ref [] in
      let timer = Uv.ok (Luv.Timer.init ()) and ping = Uv.ok (Luv.Timer.init ()) in
      let term = Uv.ok (Luv.Signal.init ()) and chld = Uv.ok (Luv.Signal.init ()) in
      let tick () =
        let produced = ref false in
        Panes.iter (State.panes state) (fun pane ->
            if Pane_proc.scan (Pane.proc pane) then produced := true);
        State.pump state;
        if (not !produced) && not (State.waiting state) then Uv.ok (Luv.Timer.stop timer)
      in
      State.on_activity state (fun () ->
          if not (Luv.Handle.is_active timer) then Uv.ok (Luv.Timer.start ~repeat:2 timer 2 tick));
      Uv.ok (Luv.Signal.start chld (Uv.sigchld ()) (fun () -> Panes.reap (State.panes state)));
      Uv.ok
        (Luv.Timer.start ~repeat:1000 ping 1000 (fun () ->
             let now = Unix.gettimeofday () in
             List.iter (fun c -> Connection.tick c now) !connections));
      let stopping = ref false in
      Uv.ok
        (Luv.Signal.start term Luv.Signal.sigterm (fun () ->
             if not !stopping then begin
               stopping := true;
               Luv.Handle.close server ignore;
               List.iter Connection.close !connections;
               Panes.shutdown (State.panes state);
               Uv.ok (Luv.Timer.stop timer);
               Uv.ok
                 (Luv.Timer.start timer 500 (fun () ->
                      Panes.kill (State.panes state);
                      Panes.reap (State.panes state);
                      List.iter (fun handle -> Luv.Handle.close handle ignore) [ term; chld ];
                      Luv.Handle.close ping ignore;
                      Luv.Handle.close timer ignore;
                      Luv.Loop.stop (Luv.Loop.default ())))
             end));
      Luv.Stream.listen ~backlog:256 server (function
        | Error _ -> ()
        | Ok () -> (
            let stream = Uv.ok (Luv.Pipe.init ()) in
            Uv.ok (Luv.Stream.accept ~server ~client:stream);
            let accepted =
              try
                match Uv.fd stream with
                | Ok fd -> Uv.peer_uid fd = Unix.getuid ()
                | Error _ -> false
              with Unix.Unix_error _ -> false
            in
            if not accepted then Luv.Handle.close stream ignore
            else
              match Luv.Handle.set_send_buffer_size stream (1 lsl 20) with
              | Error _ -> Luv.Handle.close stream ignore
              | Ok () ->
                  let connection =
                    Connection.accept stream
                      ~on_dispose:(fun closed ->
                        connections := List.filter (fun c -> not Stdlib.(c == closed)) !connections)
                      (Http.request state)
                  in
                  if not (Connection.is_closed connection) then
                    connections := connection :: !connections));
      ignore (Luv.Loop.run () : bool);
      (try Unix.unlink socket with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      Ok ()

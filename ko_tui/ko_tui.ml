module Api = Api

let run ~dir ~executable ~pager =
  try
    match Launch.attach ~dir ~executable with
    | Error message -> Error message
    | Ok (socket, fd) ->
        let wire = Wire.of_fd fd in
        Fun.protect
          ~finally:(fun () -> Wire.close wire)
          (fun () ->
            let version =
              Wire.request ~socket ~meth:"GET" ~path:"/version" ""
              |> Yojson.Safe.from_string |> Ko_server.Config.version_of_yojson
            in
            let modes, startup = Modes.save ()
            and client = ref None
            and stopped = Atomic.make false in
            let notify () = Option.iter Client.notify !client in
            let handlers =
              List.map
                (fun signal ->
                  ( signal,
                    Sys.signal signal
                      (Sys.Signal_handle
                         (fun _ ->
                           Atomic.set stopped true;
                           notify ())) ))
                [ Sys.sighup; Sys.sigterm; Sys.sigint; Sys.sigquit ]
            in
            Fun.protect
              ~finally:(fun () ->
                Fun.protect
                  ~finally:(fun () -> List.iter (fun (s, h) -> Sys.set_signal s h) handlers)
                  (fun () -> Modes.restore modes))
              (fun () ->
                let matrix =
                  Tty.create ~paint:(fun () -> Option.iter Client.paint !client) ~notify
                in
                Fun.protect
                  ~finally:(fun () ->
                    Fun.protect
                      ~finally:(fun () -> Matrix.close matrix)
                      (fun () ->
                        Fun.protect
                          ~finally:(fun () -> Modes.reset modes)
                          (fun () -> Option.iter Client.close !client)))
                  (fun () ->
                    let t =
                      Client.create ~wire ~socket ~matrix ~modes ~limits:version.terminal ~pager
                    in
                    client := Some t;
                    let open Mosaic in
                    run ~matrix
                      {
                        init =
                          (fun () ->
                            ((), Cmd.perform (fun dispatch -> Client.start t dispatch startup)));
                        update =
                          (fun message () ->
                            if Atomic.get stopped then ((), Cmd.quit) else Client.update t message);
                        view = (fun () -> empty);
                        subscriptions = (fun () -> Client.subscriptions t);
                      };
                    Ok ())))
  with
  | Wire.Error message | Failure message -> Error message
  | End_of_file -> Error "server closed the connection"
  | Yojson.Json_error message | Yojson.Safe.Util.Type_error (message, _) -> Error message
  | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _ -> Error "invalid server message"

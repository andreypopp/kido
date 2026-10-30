let stop ~dir =
  match Config.socket ~create:false dir with
  | Error message -> Error message
  | Ok socket ->
      let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () ->
          Unix.set_nonblock fd;
          (try Unix.connect fd (Unix.ADDR_UNIX socket)
           with Unix.Unix_error (Unix.EINPROGRESS, _, _) -> (
             let _, w, _ = Unix.select [] [ fd ] [] 5. in
             if List.is_empty w then raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", socket));
             match Unix.getsockopt_error fd with
             | None -> ()
             | Some error -> raise (Unix.Unix_error (error, "connect", socket))));
          Fs.write_all fd "GET /version HTTP/1.1\r\nHost: ko\r\nConnection: close\r\n\r\n";
          let deadline = Unix.gettimeofday () +. 5. in
          let buffer = Buffer.create 512 and bytes = Bytes.create 4096 in
          let rec read () =
            let remaining = deadline -. Unix.gettimeofday () in
            if Float.(remaining <= 0.) then Error "server did not answer within 5 s"
            else
              match Unix.select [ fd ] [] [] remaining with
              | [], _, _ -> Error "server did not answer within 5 s"
              | _ -> (
                  match Unix.read fd bytes 0 4096 with
                  | 0 -> (
                      let response = Buffer.contents buffer in
                      let at = String.find ~sub:"\r\n\r\n" response in
                      if at < 0 || not (String.starts_with ~prefix:"HTTP/1.1 200" response) then
                        Error "invalid server response"
                      else
                        try
                          let version =
                            Config.version_of_yojson
                              (Yojson.Safe.from_string
                                 (String.sub response (at + 4) (String.length response - at - 4)))
                          in
                          if version.server.pid <= 0 then Error "invalid server pid"
                          else (
                            Unix.kill version.server.pid Sys.sigterm;
                            Ok ())
                        with
                        | Yojson.Json_error _ | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _ ->
                          Error "invalid server response")
                  | n ->
                      if Buffer.length buffer + n > 1 lsl 20 then
                        Error "server response exceeds 1 MiB"
                      else (
                        Buffer.add_subbytes buffer bytes 0 n;
                        read ()))
          in
          read ())

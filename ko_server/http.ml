let query target =
  match String.split_on_char '?' target with
  | [ path ] -> (path, [])
  | [ path; query ] ->
      ( path,
        List.map
          (fun pair ->
            match String.split_on_char '=' pair with
            | [ k; v ] -> (k, v)
            | _ -> invalid_arg "invalid query")
          (String.split_on_char '&' query) )
  | _ -> invalid_arg "invalid target"

let natural ~max value =
  if String.is_empty value || not (String.for_all (fun c -> Char.(c >= '0' && c <= '9')) value) then
    invalid_arg "invalid number";
  match int_of_string_opt value with
  | Some n when n >= 0 && n <= max -> n
  | _ -> invalid_arg "invalid number"

let options args : Protocol.view_options =
  {
    history = Option.value ~default:"none" (List.assoc_opt ~eq:String.equal "history" args);
    images = Option.value ~default:"none" (List.assoc_opt ~eq:String.equal "images" args);
  }

let request state conn { Gluten.reqd; upgrade } =
  let request = Httpun.Reqd.request reqd in
  let respond value = Connection.respond reqd `OK (Yojson.Safe.to_string value) in
  let error status kind message = Connection.error reqd status kind message in
  let invalid message = error `Bad_request "invalid" message in
  let guarded callback =
    try callback () with
    | Invalid_argument message | Yojson.Json_error message -> invalid message
    | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (error, json) ->
        invalid (Printexc.to_string error ^ ": " ^ Yojson.Safe.to_string json)
    | Unix.Unix_error (e, fn, arg) -> error `Internal_server_error "io" (Fs.unix_message e fn arg)
    | Sys_error message -> error `Internal_server_error "io" message
  in
  guarded (fun () ->
      let path, args = query request.target in
      let header name = Httpun.Headers.get request.headers name in
      let client = header "ko-client" in
      let mismatch status message =
        Connection.respond reqd status
          (Yojson.Safe.to_string
             (Protocol.yojson_of_error
                { kind = "refused"; message; protocol = Some Config.protocol; vt = Some Config.vt }))
      in
      let discovery = String.equal path "/version" in
      if
        match header "ko-protocol" with
        | None -> not discovery
        | Some value -> (
            match String.split_on_char '.' value with
            | [ major; minor ] when String.equal major Config.major -> (
                match int_of_string_opt minor with Some n -> n < 0 | None -> true)
            | _ -> true)
      then mismatch `Upgrade_required "protocol major mismatch"
      else if
        match header "ko-vt" with
        | None -> not discovery
        | Some value -> not (String.equal value Config.vt)
      then mismatch `Conflict "terminal revision mismatch"
      else if Option.is_some (header "origin") then
        error `Conflict "refused" "Origin is not permitted on this unix server"
      else if
        Option.exists
          (fun id ->
            not
              (List.exists
                 (fun c -> String.equal (Client.id c) id && Client.registered c)
                 (State.clients state)))
          client
      then error `Gone "gone" "client is closed"
      else
        let panes = State.panes state in
        let websocket ~on_text ~on_close ~on_writable =
          match Connection.upgrade conn reqd upgrade ~on_text ~on_close ~on_writable with
          | Ok () -> ()
          | Error message -> invalid message
        in
        match (request.meth, String.split_on_char '/' path) with
        | `GET, [ ""; "version" ] -> respond (Config.yojson_of_version (State.version state))
        | `GET, [ ""; "panes" ] ->
            respond (yojson_of_list Protocol.yojson_of_row (Panes.rows panes))
        | `POST, [ ""; "panes" ] ->
            Connection.body reqd (fun json ->
                guarded (fun () ->
                    match
                      Panes.add panes (Protocol.create_of_yojson json) ~notify:(State.event state)
                    with
                    | Error message -> invalid message
                    | Ok pane ->
                        respond (Protocol.yojson_of_created { pane = Pane.id pane });
                        State.topology state))
        | `GET, [ ""; "client" ] ->
            let c = State.add_client state conn in
            websocket
              ~on_text:(fun text ->
                try
                  let input = Protocol.client_input_of_yojson (Yojson.Safe.from_string text) in
                  match Client.receive panes ~clients:(State.clients state) c input with
                  | Ok () -> ()
                  | Error _ -> Connection.reject conn "invalid"
                with
                | Yojson.Json_error _ | Invalid_argument _
                | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _
                ->
                  Connection.reject conn "invalid")
              ~on_close:(fun () -> State.remove_client state c)
              ~on_writable:ignore
        | meth, "" :: "panes" :: id :: rest -> (
            match Panes.find panes id with
            | None -> error `Not_found "not_found" "pane not found"
            | Some pane -> (
                match (meth, rest) with
                | `DELETE, [] ->
                    State.close_views state pane;
                    Panes.remove panes pane;
                    State.topology state;
                    respond (`Assoc [])
                | `POST, [ "input" ] ->
                    Connection.body reqd (fun json ->
                        guarded (fun () ->
                            let input = Protocol.input_of_yojson json in
                            match
                              Input.send pane input (function
                                | Error message -> error `Internal_server_error "io" message
                                | Ok None -> respond (`Assoc [])
                                | Ok (Some reply) -> respond (Protocol.yojson_of_pasted reply))
                            with
                            | Ok () -> ()
                            | Error message -> invalid message))
                | `GET, [ "screen" ] ->
                    let ansi =
                      match List.assoc_opt ~eq:String.equal "format" args with
                      | None | Some "plain" -> false
                      | Some "ansi" -> true
                      | _ -> invalid_arg "invalid format"
                    in
                    let history =
                      match List.assoc_opt ~eq:String.equal "history" args with
                      | None | Some "none" -> 0
                      | Some "all" -> 0xffffffff
                      | Some n -> natural ~max:0xffffffff n
                    in
                    let writer = ref None in
                    Pane_proc.screen (Pane.proc pane) ~ansi ~history
                      ~chunk:(fun text ~last ->
                        let output =
                          match !writer with
                          | Some w -> w
                          | None ->
                              let w =
                                Httpun.Reqd.respond_with_streaming reqd
                                  (Httpun.Response.create
                                     ~headers:
                                       (Httpun.Headers.of_list
                                          [
                                            ("content-type", "text/plain; charset=utf-8");
                                            ("transfer-encoding", "chunked");
                                          ])
                                     `OK)
                              in
                              writer := Some w;
                              w
                        in
                        if not (Httpun.Body.Writer.is_closed output) then begin
                          Httpun.Body.Writer.write_string output text;
                          if last then Httpun.Body.Writer.close output
                          else Httpun.Body.Writer.flush output ignore
                        end)
                      ~done_:(function
                        | Ok () -> ()
                        | Error message -> (
                            match !writer with
                            | None -> error `Internal_server_error "io" message
                            | Some _ -> Connection.close conn))
                | `GET, [ "view" ] ->
                    let full = Protocol.full (options args) in
                    let offset =
                      Option.map (natural ~max:max_int)
                        (List.assoc_opt ~eq:String.equal "offset" args)
                    in
                    if not (Pane_proc.alive (Pane.proc pane)) then
                      error `Internal_server_error "io" "pane process ended"
                    else begin
                      let view = ref None in
                      websocket
                        ~on_text:(fun text -> Option.iter (fun v -> View.receive v text) !view)
                        ~on_close:(fun () ->
                          Option.iter
                            (fun v ->
                              View.close v;
                              State.remove_view state v)
                            !view)
                        ~on_writable:(fun () -> Option.iter View.pump !view);
                      let v = View.create pane conn ~client ~offset ~full in
                      view := Some v;
                      if not (Connection.is_closed conn) then State.add_view state v
                    end
                | _ -> error `Not_found "not_found" "resource not found"))
        | _ -> error `Not_found "not_found" "resource not found")

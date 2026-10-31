let id of_string text = try Some (of_string text) with Invalid_argument _ -> None

let respond reqd status body =
  Httpun.Reqd.respond_with_string reqd
    (Httpun.Response.create
       ~headers:
         (Httpun.Headers.of_list
            [
              ("content-type", "application/json");
              ("content-length", string_of_int (String.length body));
            ])
       status)
    body

let error reqd kind message =
  respond reqd
    (match (kind : Protocol.error_kind) with
    | Invalid -> `Bad_request
    | Refused -> `Conflict
    | Gone -> `Gone
    | Io -> `Internal_server_error
    | Missing -> `Not_found
    | Protocol_mismatch _ -> `Upgrade_required
    | Vt_mismatch _ -> `Conflict)
    (Yojson.Basic.to_string (Protocol.error_to_json { kind; message }))

let body reqd callback =
  let b = Buffer.create 256 in
  let reader = Httpun.Reqd.request_body reqd in
  let rec read () =
    Httpun.Body.Reader.schedule_read reader
      ~on_read:(fun bs ~off ~len ->
        if Buffer.length b + len > Connection.max_message then (
          Httpun.Body.Reader.close reader;
          error reqd Invalid "body exceeds 1 MiB")
        else (
          Buffer.add_string b (Bigstringaf.substring bs ~off ~len);
          read ()))
      ~on_eof:(fun () ->
        if Option.is_none (Httpun.Reqd.error_code reqd) then
          match Yojson.Basic.from_string (Buffer.contents b) with
          | json -> callback json
          | exception Yojson.Json_error message -> error reqd Invalid message)
  in
  read ()

let request state conn { Gluten.reqd; upgrade } =
  let request = Httpun.Reqd.request reqd in
  let respond value = respond reqd `OK (Yojson.Basic.to_string value) in
  let error kind message = error reqd kind message in
  let invalid message = error Invalid message in
  let guarded callback =
    try callback () with
    | Invalid_argument message | Yojson.Json_error message -> invalid message
    | Jsonkit.Of_json_error error -> invalid (Jsonkit.of_json_error_to_string error)
    | Unix.Unix_error (e, fn, arg) -> error Io (Fs.unix_message e fn arg)
    | Sys_error message -> error Io message
  in
  guarded (fun () ->
      let route =
        Protocol.Route.of_request ~meth:(Httpun.Method.to_string request.meth) request.target
      in
      let header name = Httpun.Headers.get request.headers name in
      let client = Option.flat_map (id Ids.Client_id.of_string) (header "ko-client") in
      let discovery = match route with Some Version -> true | _ -> false in
      let sent name ours =
        match header name with None when discovery -> Some ours | value -> value
      in
      match
        Protocol.check_version
          ~protocol:(sent "ko-protocol" Protocol.version.protocol)
          ~vt:(sent "ko-vt" Protocol.version.vt)
      with
      | Error { kind; message } -> error kind message
      | Ok () -> (
          if Option.is_some (header "origin") then
            error Refused "Origin is not permitted on this unix server"
          else if
            Option.is_some (header "ko-client")
            && not (Option.exists (State.registered state) client)
          then error Gone "client is closed"
          else
            let panes = State.panes state in
            let websocket ~on_text ~on_close ~on_writable =
              match Connection.upgrade conn reqd upgrade ~on_text ~on_close ~on_writable with
              | Ok () -> ()
              | Error message -> invalid message
            in
            let with_pane id f =
              match Panes.find panes id with
              | None -> error Missing "pane not found"
              | Some pane -> f pane
            in
            match route with
            | None -> error Missing "resource not found"
            | Some Version -> respond (Protocol.version_to_json Protocol.version)
            | Some List_panes -> respond (list_to_json Protocol.row_to_json (Panes.rows panes))
            | Some Create_pane ->
                body reqd (fun json ->
                    guarded (fun () ->
                        match
                          Panes.add panes
                            (Protocol.Request.create_pane_of_json json)
                            ~notify:(State.event state)
                        with
                        | Error message -> invalid message
                        | Ok pane ->
                            respond (Protocol.created_to_json { pane = Pane.id pane });
                            State.topology state))
            | Some Client ->
                let c = State.add_client state conn in
                websocket
                  ~on_text:
                    (Client.receive panes ~limits:(State.limits state)
                       ~clients:(State.clients state) c)
                  ~on_close:(fun () -> State.remove_client state c)
                  ~on_writable:ignore
            | Some (Delete_pane id) ->
                with_pane id (fun pane ->
                    State.close_views state (Pane.id pane);
                    Panes.remove panes pane;
                    State.topology state;
                    respond (`Assoc []))
            | Some (Input id) ->
                with_pane id (fun pane ->
                    body reqd (fun json ->
                        guarded (fun () ->
                            match
                              Pane_proc.input (Pane.proc pane) (Protocol.Request.input_of_json json)
                                (function
                                | Error message -> error Io message
                                | Ok None -> respond (`Assoc [])
                                | Ok (Some reply) -> respond (Protocol.paste_result_to_json reply))
                            with
                            | Ok () -> ()
                            | Error message -> invalid message)))
            | Some (Screen (id, format, history)) ->
                with_pane id (fun pane ->
                    let writer = ref None in
                    Pane_proc.screen (Pane.proc pane) ~format ~history
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
                            | None -> error Io message
                            | Some _ -> Connection.close conn)))
            | Some (View (id, options, offset)) ->
                with_pane id (fun pane ->
                    match Pane_proc.life (Pane.proc pane) with
                    | Closed | Reaped -> error Io "pane process ended"
                    | Open ->
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
                        let v = View.create pane conn ~client ~offset ~history:options.history in
                        view := Some v;
                        if not (Connection.is_closed conn) then State.add_view state v)))

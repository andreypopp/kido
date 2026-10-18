let read_new path offset =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let size = in_channel_length ic in
        if size <= !offset then ""
        else begin
          seek_in ic !offset;
          let data = really_input_string ic (size - !offset) in
          offset := size;
          data
        end)
  with Sys_error _ -> ""

type tail = { stream : Async_stream.t; offset : int ref; path : string }

let wait ~dir ~knobs ~notify ~warn id =
  let open Result.Infix in
  let* meta =
    Option.to_result
      (Printf.sprintf "run %s has no meta" (Run.string_of_id id))
      (Run.read_meta ~dir id)
  in
  let tail =
    if notify && match meta.kind with Stream -> true | Pi | Agent | Bash -> false then
      Some
        {
          stream = Async_stream.start ~dir knobs meta;
          offset = ref 0;
          path = Run.output_path ~dir meta.id;
        }
    else None
  in
  let complete outcome =
    if notify then begin
      let detail =
        match tail with
        | Some { stream; offset; path } ->
            Async_stream.write stream (read_new path offset);
            Some (Run_ending.Streamed { unstreamed = Async_stream.close stream })
        | None -> None
      in
      Option.iter
        (fun e ->
          Result.iter_err (fun err -> warn (Msg.string_of_error err)) (Run_ending.send ~dir e))
        (Run_ending.record_ending ?detail ~dir meta outcome)
    end;
    Ok outcome
  in
  let rec poll () =
    Option.iter (fun t -> Async_stream.write t.stream (read_new t.path t.offset)) tail;
    match Run.read_outcome ~dir id with
    | Some outcome -> complete outcome
    | None -> (
        if Run.alive meta.pid then begin
          Unix.sleepf Sidebar.default_interval;
          poll ()
        end
        else
          let* state =
            State.read ~dir (Tmux.create ())
            |> Result.map_err (fun e -> Printf.sprintf "cannot read the tmux state: %s" e)
          in
          match State.run_ending ~dir state meta with
          | Some outcome -> complete outcome
          | None ->
              Unix.sleepf Sidebar.default_interval;
              poll ())
  in
  poll ()

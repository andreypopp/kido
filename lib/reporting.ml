let session ~agent ~pane ~pid : State.session =
  {
    agent;
    name = "";
    pane;
    pid;
    ts = Timestamp.now ();
    inbox = "";
    activity = "";
    parent = None;
    depth = 0;
    model = "";
  }

let one_line s ~max =
  let b = Buffer.create (String.length s) in
  let rec clean i =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
      if (not (Uchar.utf_decode_is_valid d)) || c < 0x20 || (c >= 0x7F && c <= 0x9F) || c = 0xFFFD
      then Buffer.add_char b ' '
      else Buffer.add_utf_8_uchar b (Uchar.utf_decode_uchar d);
      clean (i + Uchar.utf_decode_length d)
    end
  in
  clean 0;
  let s = Buffer.contents b in
  String.rdrop_while (Char.equal ' ') (Msg.utf_8_prefix s max)

let agent_status ~dir ~pane ~agent ~session:id ~inbox ~activity ~parent_pid ~parent_session ~depth
    ~model ~name =
  State.record ~dir id
    {
      (session ~agent:(State.agent_of_string agent) ~pane ~pid:(Unix.getppid ())) with
      inbox;
      name;
      activity = one_line activity ~max:256;
      parent =
        (if String.is_empty parent_session then None
         else Some { session = parent_session; pid = parent_pid });
      depth;
      model;
    }
  |> Result.map (fun () ->
      if String.equal agent "pi" && not (String.is_empty name) then
        Result.to_opt (Subrun.parse_id id)
        |> Option.flat_map (Subrun.read_meta ~dir)
        |> Option.iter (fun (meta : Subrun.meta) ->
            match meta with
            | { kind = Agent; _ } when not (String.equal name meta.name) ->
                Subrun.write_meta ~dir { meta with name }
            | _ -> ()))

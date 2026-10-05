open Kido

let%expect_test "rpc surface" =
  let emit json = print_endline (Yojson.Safe.to_string json) in
  print_endline Protocol.value;
  List.iter (fun stamp -> emit (Protocol.hello stamp)) [ Some Protocol.value; Some "other"; None ];
  List.iter
    (fun result -> emit (Protocol.reply 7 result))
    [ Ok (Some ("$3", "@12")); Ok None; Error "invalid or unknown request" ];
  List.iter
    (fun protocol ->
      emit
        (Launch.endpoint_to_yojson { tmux = "/bin/kido-tmux"; socket = "/server/socket"; protocol }))
    [ Some Protocol.value; None ];
  let opts : Sidebar.options =
    {
      interval = 0.1;
      client = "app";
      socket = None;
      dir = "/unused";
      threshold = 180.;
      grace = 30.;
    }
  in
  let roles : Sidebar.role list =
    [ `Plain; `Current; `Proc; `Dim; `Err; `Running; `Waiting; `Compacting; `Done; `Stalled ]
  in
  let title = List.map (fun role -> { Sidebar.text = "span"; role }) roles in
  let indicators : Sidebar.indicator option list =
    [
      None;
      Some (Status Running);
      Some (Status Waiting);
      Some (Status Compacting);
      Some (Status Idle);
      Some Unknown;
      Some Done;
      Some Failed;
      Some Stalled;
      Some (Gone None);
      Some (Gone (Some Completed));
      Some (Gone (Some Failed));
      Some (Gone (Some Died));
      Some (Gone (Some Stopped));
    ]
  in
  let items =
    List.mapi
      (fun i indicator ->
        {
          Sidebar.row =
            {
              pane = "%" ^ string_of_int i;
              window = "@1";
              kind = (match i mod 4 with 0 -> Agent | 1 -> Run | 2 -> Ssh | _ -> Shell);
              indicator;
              title = (if i = 0 then title else []);
              caption = (if i = 0 then Text title else Elapsed 100.);
            };
          children = [];
        })
      indicators
  in
  let first = List.hd items in
  let nodes =
    [
      Sidebar.Group { name = "window"; first; rest = List.tl items };
      Sidebar.Item { first with children = [ Sidebar.Item first ] };
    ]
  in
  let panes =
    List.mapi
      (fun i _ -> Fixture.pane ~run:(string_of_int i) ("%" ^ string_of_int i))
      (List.tl items)
  in
  let lingering =
    List.mapi
      (fun i _ ->
        ( string_of_int i,
          {
            Sidebar.name = "run";
            parent = "parent";
            outcome = (if i mod 2 = 0 then None else Some Subrun.Completed);
            kind = (match i mod 3 with 0 -> Subrun.Agent | 1 -> Bash | _ -> Stream);
            started = 100.;
          } ))
      items
    |> Sidebar.String_map.of_list
  in
  let m = Sidebar.make ~now:(fun () -> 100.) opts in
  let m =
    {
      m with
      client = Some { session = "$0"; window = "@1"; pane = "%0" };
      search = Some "filter";
      snap =
        {
          Sidebar.empty with
          panes;
          lingering;
          states = Sidebar.String_map.singleton "%0" ("agent", Fixture.session State.Waiting);
        };
      sessions = [ { id = "$0"; name = "session"; current = true; nodes } ];
    }
  in
  emit (Option.get_exn_or "snapshot" (Sidebar.to_json m));
  emit
    (Option.get_exn_or "error snapshot"
       (Sidebar.to_json
          { m with snap = { Sidebar.empty with err = Some "tmux: gone" }; sessions = [] }));
  [%expect
    {|
    1.0
    {"hello":{"protocol":"1.0"}}
    {"hello":{"protocol":"1.0","server":"other"}}
    {"hello":{"protocol":"1.0","server":null}}
    {"reply":{"id":7,"switched":{"session":"$3","window":"@12"}}}
    {"reply":{"id":7,"switched":null}}
    {"reply":{"id":7,"error":"invalid or unknown request"}}
    {"tmux":"/bin/kido-tmux","socket":"/server/socket","protocol":"1.0"}
    {"tmux":"/bin/kido-tmux","socket":"/server/socket","protocol":null}
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%0"},"filter":"filter","error":null,"sessions":[{"id":"$0","name":"session","current":true,"nodes":[{"kind":"window","id":"@1","window":"@1","name":"window","children":[{"kind":"agent","id":"%0","pane":"%0","window":"@1","indicator":null,"title":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"compacting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"tail":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"compacting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"run":"agent","started":100.0,"attention":true,"children":[]},{"kind":"run","id":"%1","pane":"%1","window":"@1","indicator":{"kind":"running"},"title":[],"tail":[],"run":"bash","started":null,"attention":false,"children":[]},{"kind":"ssh","id":"%2","pane":"%2","window":"@1","indicator":{"kind":"waiting"},"title":[],"tail":[],"run":"stream","started":100.0,"attention":false,"children":[]},{"kind":"shell","id":"%3","pane":"%3","window":"@1","indicator":{"kind":"compacting"},"title":[],"tail":[],"run":"agent","started":null,"attention":false,"children":[]},{"kind":"agent","id":"%4","pane":"%4","window":"@1","indicator":{"kind":"idle"},"title":[],"tail":[],"run":"bash","started":100.0,"attention":false,"children":[]},{"kind":"run","id":"%5","pane":"%5","window":"@1","indicator":{"kind":"unknown"},"title":[],"tail":[],"run":"stream","started":null,"attention":false,"children":[]},{"kind":"ssh","id":"%6","pane":"%6","window":"@1","indicator":{"kind":"done"},"title":[],"tail":[],"run":"agent","started":100.0,"attention":false,"children":[]},{"kind":"shell","id":"%7","pane":"%7","window":"@1","indicator":{"kind":"failed"},"title":[],"tail":[],"run":"bash","started":null,"attention":false,"children":[]},{"kind":"agent","id":"%8","pane":"%8","window":"@1","indicator":{"kind":"stalled"},"title":[],"tail":[],"run":"stream","started":100.0,"attention":false,"children":[]},{"kind":"run","id":"%9","pane":"%9","window":"@1","indicator":{"kind":"gone","outcome":null},"title":[],"tail":[],"run":"agent","started":null,"attention":false,"children":[]},{"kind":"ssh","id":"%10","pane":"%10","window":"@1","indicator":{"kind":"gone","outcome":"completed"},"title":[],"tail":[],"run":"bash","started":100.0,"attention":false,"children":[]},{"kind":"shell","id":"%11","pane":"%11","window":"@1","indicator":{"kind":"gone","outcome":"failed"},"title":[],"tail":[],"run":"stream","started":null,"attention":false,"children":[]},{"kind":"agent","id":"%12","pane":"%12","window":"@1","indicator":{"kind":"gone","outcome":"died"},"title":[],"tail":[],"run":"agent","started":100.0,"attention":false,"children":[]},{"kind":"run","id":"%13","pane":"%13","window":"@1","indicator":{"kind":"gone","outcome":"stopped"},"title":[],"tail":[],"run":null,"started":null,"attention":false,"children":[]}]},{"kind":"agent","id":"%0","pane":"%0","window":"@1","indicator":null,"title":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"compacting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"tail":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"compacting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"run":"agent","started":100.0,"attention":true,"children":[{"kind":"agent","id":"%0","pane":"%0","window":"@1","indicator":null,"title":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"compacting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"tail":[{"text":"span","role":"plain"},{"text":"span","role":"current"},{"text":"span","role":"proc"},{"text":"span","role":"dim"},{"text":"span","role":"err"},{"text":"span","role":"running"},{"text":"span","role":"waiting"},{"text":"span","role":"compacting"},{"text":"span","role":"done"},{"text":"span","role":"stalled"}],"run":"agent","started":100.0,"attention":true,"children":[]}]}]}]}
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%0"},"filter":"filter","error":"tmux: gone","sessions":[]}
    |}]

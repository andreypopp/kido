open Kido

let words = String.concat " "

let%expect_test "parse_processes: real macOS ps output, then malformed rows" =
  let show rows =
    List.iter
      (fun (p : Procs.process) ->
        Printf.printf "%d %d %s [%s]\n" p.pid p.ppid p.comm (words (List.take 3 p.args)))
      (Procs.parse_processes (Procs.split_fields rows))
  in
  show
    {|49417 71584 /bin/zsh         /bin/zsh -c source /Users/a/.claude/shell-snapshots/snapshot-zsh.sh 2>/dev/null || true
24619 64101 zsh              zsh
24089 24003 ssh              ssh ahrefs/devbox-uk -t zsh -i -c 's '
  10    1 My App    /Applications/My App.app/Contents/MacOS/My App --flag
|};
  show "PID PPID COMM ARGS\n  1 launchd\nabc def comm args\n  99   1 sh sh -c true\n";
  [%expect
    {|
    49417 71584 /bin/zsh [/bin/zsh -c source]
    24619 64101 zsh [zsh]
    24089 24003 ssh [ssh ahrefs/devbox-uk -t]
    10 1 My [App /Applications/My App.app/Contents/MacOS/My]
    99 1 sh [sh -c true]
    |}]

let%expect_test "parse_ssh splits at the destination" =
  List.iter
    (fun args ->
      Printf.printf "%-34s -> %s\n" (words args)
        (match Procs.parse_ssh args with
        | None -> "no destination"
        | Some a ->
            Printf.sprintf "opts=[%s] letters=%s dest=%s command=[%s]" (words a.opts) a.letters
              a.dest (words a.command)))
    [
      [ "host" ];
      [ "-A"; "host" ];
      [ "-tt"; "host" ];
      [ "-o"; "BatchMode=yes"; "host" ];
      [ "-oBatchMode=yes"; "host" ];
      [ "-P"; "2222"; "host" ];
      [ "-4p"; "2222"; "host" ];
      [ "host"; "uptime"; "-a" ];
      [ "--"; "h"; "uptime" ];
      [ "-V" ];
      [];
    ];
  [%expect
    {|
    host                               -> opts=[] letters= dest=host command=[]
    -A host                            -> opts=[-A] letters=A dest=host command=[]
    -tt host                           -> opts=[-tt] letters=tt dest=host command=[]
    -o BatchMode=yes host              -> opts=[-o BatchMode=yes] letters=o dest=host command=[]
    -oBatchMode=yes host               -> opts=[-oBatchMode=yes] letters=o dest=host command=[]
    -P 2222 host                       -> opts=[-P 2222] letters=P dest=host command=[]
    -4p 2222 host                      -> opts=[-4p 2222] letters=4p dest=host command=[]
    host uptime -a                     -> opts=[] letters= dest=host command=[uptime -a]
    -- h uptime                        -> opts=[] letters= dest=h command=[uptime]
    -V                                 -> no destination
                                       -> no destination
    |}]

let%expect_test "ssh_session: -N wins over -t wins over -T, else a remote command is a job" =
  List.iter
    (fun args ->
      Printf.printf "%-34s -> %s\n" (words args)
        (match Procs.ssh_session args with
        | None -> "none"
        | Some s -> Printf.sprintf "%s interactive=%b" s.host s.interactive))
    [
      [ "myhost" ];
      [ "myhost"; "make"; "build" ];
      [ "-t"; "myhost"; "make" ];
      [ "-T"; "myhost" ];
      [ "-N"; "-L"; "8080:x:80"; "myhost" ];
      [ "-p2222"; "box"; "uptime" ];
      [ "-J"; "jump"; "-i"; "key"; "-o"; "X=y"; "dest" ];
      [ "ssh://me@h:22" ];
      [ "-L"; "8080:x:80"; "--"; "h" ];
      [ "-oProxyCommand=nc -T -N %h %p"; "h" ];
      [ "-v"; "-p"; "2222" ];
    ];
  [%expect
    {|
    myhost                             -> myhost interactive=true
    myhost make build                  -> myhost interactive=false
    -t myhost make                     -> myhost interactive=true
    -T myhost                          -> myhost interactive=false
    -N -L 8080:x:80 myhost             -> myhost interactive=true
    -p2222 box uptime                  -> box interactive=false
    -J jump -i key -o X=y dest         -> dest interactive=true
    ssh://me@h:22                      -> me@h:22 interactive=true
    -L 8080:x:80 -- h                  -> h interactive=true
    -oProxyCommand=nc -T -N %h %p h    -> h interactive=true
    -v -p 2222                         -> none
    |}]

let%expect_test "parse_parent" =
  Printf.printf "%s\n"
    (match Procs.parse_parent [ [ "71584"; "zsh" ] ] with
    | Some (ppid, comm) -> Printf.sprintf "%d %s" ppid comm
    | None -> "none");
  List.iter
    (fun rows ->
      print_string (if Option.is_none (Procs.parse_parent rows) then "none " else "some "))
    [ []; [ [ "71584" ] ]; [ [ "abc"; "zsh" ] ] ];
  [%expect {|
    71584 zsh
    none none none
    |}]

open Kido

let words = String.concat " "

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

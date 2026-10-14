type ssh_option_class = Keep | Drop | Refuse
type ssh_option = { letter : char; kind : ssh_option_class; value : string option }

type ssh_args = {
  opts : string list;
  options : ssh_option list;
  dest : string;
  command : string list;
}

let ssh_letters a = String.of_list (List.map (fun o -> o.letter) a.options)

let split_fields out =
  String.lines out
  |> List.filter_map (fun line ->
      let spaced = String.map (fun c -> if Char.is_whitespace_ascii c then ' ' else c) line in
      match String.split_on_char ' ' spaced |> List.filter (fun f -> not (String.is_empty f)) with
      | [] -> None
      | fields -> Some fields)

let parse_ssh args =
  let finish opts options dest command =
    Option.map
      (fun dest -> { opts = List.rev opts; options = List.rev options; dest; command })
      dest
  in
  let rec go opts options dest = function
    | [] -> finish opts options dest []
    | "--" :: rest -> (
        match (dest, rest) with
        | None, d :: command -> finish opts options (Some d) command
        | _ -> finish opts options dest rest)
    | d :: command when String.equal d "-" || not (String.prefix ~pre:"-" d) -> (
        match dest with
        | None -> go opts options (Some d) command
        | Some _ -> finish opts options dest (d :: command))
    | arg :: rest ->
        let n = String.length arg in
        let rec scan j options =
          if j >= n then go (arg :: opts) options dest rest
          else
            let letter = arg.[j] in
            let arity, kind =
              match letter with
              | 'B' | 'b' | 'c' | 'F' | 'I' | 'i' | 'J' | 'l' | 'm' | 'o' | 'p' | 'P' | 'S' ->
                  (`Value, Keep)
              | 'D' | 'E' | 'e' | 'L' | 'R' -> (`Value, Drop)
              | 'O' | 'Q' | 'W' | 'w' -> (`Value, Refuse)
              | '4' | '6' | 'C' | 'K' | 'k' -> (`Flag, Keep)
              | 'A' | 'a' | 'f' | 'g' | 'N' | 'n' | 'q' | 'T' | 't' | 'v' | 'x' | 'X' | 'Y' | 'y' ->
                  (`Flag, Drop)
              | _ -> (`Flag, Refuse)
            in
            match arity with
            | `Flag -> scan (j + 1) ({ letter; kind; value = None } :: options)
            | `Value -> (
                let continue value opts rest =
                  go opts ({ letter; kind; value = Some value } :: options) dest rest
                in
                if j + 1 < n then continue (String.drop (j + 1) arg) (arg :: opts) rest
                else
                  match rest with
                  | value :: rest -> continue value (value :: arg :: opts) rest
                  | [] -> None)
        in
        scan 1 options
  in
  go [] [] None args

type ssh_connection_args = string list [@@deriving yojson_of]

let ssh_connection_args_json args = Yojson.Safe.to_string (yojson_of_ssh_connection_args args)

let ssh_connection_args a =
  let rec go = function
    | [] -> Some [ a.dest ]
    | { kind = Refuse; _ } :: _ -> None
    | { kind = Drop; _ } :: rest -> go rest
    | { letter; kind = Keep; value } :: rest ->
        Option.map
          (fun rest -> ("-" ^ String.make 1 letter) :: (Option.to_list value @ rest))
          (go rest)
  in
  if
    String.is_empty a.dest || String.prefix ~pre:"-" a.dest
    || not (List.for_all String.is_valid_utf_8 ((a.dest :: a.opts) @ a.command))
  then None
  else go a.options

let%test_module "Tests" =
  (module struct
    let words = String.concat " "

    let print_connection_args args =
      print_endline
        (match args with None -> "refused" | Some args -> ssh_connection_args_json args)

    let%expect_test "ssh connection arguments" =
      List.iter
        (fun args -> print_connection_args (Option.flat_map ssh_connection_args (parse_ssh args)))
        [
          [ "alias" ];
          [
            "-4Cp2222";
            "-J";
            "jump";
            "-Fcfg";
            "-i";
            "key";
            "-luser";
            "-o";
            "ProxyCommand=ssh jump nc %h %p";
            "-6";
            "-S";
            "socket";
            "alias";
            "uptime";
          ];
          [
            "-B";
            "if0";
            "-b";
            "127.0.0.1";
            "-c";
            "aes128-ctr";
            "-I";
            "provider";
            "-m";
            "hmac-sha2-256";
            "-P";
            "tag";
            "-Kk";
            "alias";
          ];
          [
            "-ttTAaNfnqvgxXYy";
            "-Llocal";
            "-R";
            "remote";
            "-D1080";
            "-Elog";
            "-e";
            "none";
            "alias";
            "sh";
            "-c";
            "command";
          ];
          [ "--"; "alias"; "-Z" ];
          [ "-Z"; "alias" ];
          [ "-O"; "check"; "alias" ];
          [ "-W"; "host:22"; "alias" ];
          [ "-M"; "alias" ];
          [ "-s"; "alias" ];
          [ "-G"; "alias" ];
          [ "-Q"; "help" ];
          [ "-V" ];
          [ "-p" ];
          [ "--"; "-host" ];
        ];
      [%expect
        {|
        ["alias"]
        ["-4","-C","-p","2222","-J","jump","-F","cfg","-i","key","-l","user","-o","ProxyCommand=ssh jump nc %h %p","-6","-S","socket","alias"]
        ["-B","if0","-b","127.0.0.1","-c","aes128-ctr","-I","provider","-m","hmac-sha2-256","-P","tag","-K","-k","alias"]
        ["alias"]
        ["alias"]
        refused
        refused
        refused
        refused
        refused
        refused
        refused
        refused
        refused
        refused
      |}]

    let%expect_test "ssh options after the destination" =
      List.iter
        (fun args ->
          match parse_ssh args with
          | None -> print_endline "no destination"
          | Some a ->
              Printf.printf "opts=[%s] letters=%s dest=%s command=[%s]\n" (words a.opts)
                (ssh_letters a) a.dest (words a.command);
              print_connection_args (ssh_connection_args a))
        [
          [ "example.test"; "-p"; "2222" ];
          [ "--"; "example.test"; "-p"; "2222" ];
          [ "example.test"; "--"; "-p"; "2222" ];
          [ "example.test"; "uptime"; "-p"; "2222" ];
          [ "-p"; "2222"; "example.test"; "-p"; "3333" ];
          [ "example.test"; "-N" ];
          [ "example.test"; "-s" ];
          [ "example.test"; "-O"; "check" ];
          [ "example.test"; "-Z" ];
          [ "-o"; "BatchMode=yes"; "example.test"; "-o"; "BatchMode=no" ];
        ];
      [%expect
        {|
        opts=[-p 2222] letters=p dest=example.test command=[]
        ["-p","2222","example.test"]
        opts=[] letters= dest=example.test command=[-p 2222]
        ["example.test"]
        opts=[] letters= dest=example.test command=[-p 2222]
        ["example.test"]
        opts=[] letters= dest=example.test command=[uptime -p 2222]
        ["example.test"]
        opts=[-p 2222 -p 3333] letters=pp dest=example.test command=[]
        ["-p","2222","-p","3333","example.test"]
        opts=[-N] letters=N dest=example.test command=[]
        ["example.test"]
        opts=[-s] letters=s dest=example.test command=[]
        refused
        opts=[-O check] letters=O dest=example.test command=[]
        refused
        opts=[-Z] letters=Z dest=example.test command=[]
        refused
        opts=[-o BatchMode=yes -o BatchMode=no] letters=oo dest=example.test command=[]
        ["-o","BatchMode=yes","-o","BatchMode=no","example.test"]
      |}]

    let%expect_test "ssh options require a value on both sides of the destination" =
      String.iter
        (fun letter ->
          let flag = "-" ^ String.make 1 letter in
          List.iter
            (fun args ->
              if Option.is_some (parse_ssh args) then Printf.printf "accepted %s\n" (words args))
            [ [ flag ]; [ "host"; flag ] ])
        "BbcDEeFIiJLlmOoPpQRSWw";
      [%expect {| |}]

    let%expect_test "ssh connection argument encoding" =
      List.iter
        (fun args -> print_connection_args (Option.flat_map ssh_connection_args (parse_ssh args)))
        [
          [ "-i"; "clé/🔑"; "hôte" ];
          [ "-o"; "ProxyCommand=printf '\"\\\\\t\n\r\000\001\031'"; "host" ];
          [ "-i"; "\255"; "host" ];
          [ "\195" ];
          [ "\128" ];
          [ "\192\175" ];
          [ "\237\160\128" ];
          [ "\244\144\128\128" ];
          [ "host"; "echo"; "\255" ];
        ];
      [%expect
        {|
        ["-i","clé/🔑","hôte"]
        ["-o","ProxyCommand=printf '\"\\\\\t\n\r\u0000\u0001\u001f'","host"]
        refused
        refused
        refused
        refused
        refused
        refused
        refused
      |}]

    let%expect_test "parse_ssh separates options and the remote command" =
      List.iter
        (fun args ->
          Printf.printf "%-34s -> %s\n" (words args)
            (match parse_ssh args with
            | None -> "no destination"
            | Some a ->
                Printf.sprintf "opts=[%s] letters=%s dest=%s command=[%s]" (words a.opts)
                  (ssh_letters a) a.dest (words a.command)))
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
  end)

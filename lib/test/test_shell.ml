open Kido

(* An unprimed shell gets tmux's own dashed argv[0] rather than -l: a shell kido knows nothing
   about is exactly the shell that might not take -l. *)
let%expect_test "argv per mode" =
  List.iter
    (fun (path, mode, command) -> print_endline (String.concat " " (Shell.argv path mode command)))
    [
      ("/bin/zsh", Prime.Zsh, None);
      ("/bin/bash", Bash, None);
      ("/usr/bin/fish", Plain, None);
      ("/bin/zsh", Zsh, Some "tmux-mem-cpu-load");
      ("/usr/bin/fish", Plain, Some "top");
    ];
  [%expect
    {|
    /bin/zsh -l
    /bin/bash --login --posix
    -fish
    /bin/zsh -l -c tmux-mem-cpu-load
    /usr/bin/fish -c top
    |}]

let%expect_test "bare_shell_word" =
  List.iter
    (fun c ->
      Printf.printf "%S -> %s\n" c (Option.get_or ~default:"none" (Shell.bare_shell_word c)))
    [ "zsh"; "/bin/zsh"; "zsh -l"; "reattach-to-user-namespace -l zsh"; ""; "   "; "  zsh  " ];
  [%expect
    {|
    "zsh" -> zsh
    "/bin/zsh" -> /bin/zsh
    "zsh -l" -> none
    "reattach-to-user-namespace -l zsh" -> none
    "" -> none
    "   " -> none
    "  zsh  " -> zsh
    |}]

let%expect_test "command primes a bare word naming zsh or bash as the shell, and nothing else" =
  let show (path, command) =
    Printf.printf "%s %s\n" (Filename.basename path) (Option.get_or ~default:"-" command)
  in
  let path = Sys.getenv "PATH" in
  List.iter
    (fun c -> show (Shell.command ~path ~login:"/bin/zsh" c))
    [
      Some "zsh";
      Some "/bin/zsh";
      Some "bash";
      Some "zsh -l";
      Some "fish";
      Some "reattach-to-user-namespace -l zsh";
      None;
    ];
  let real = Sh.write (Filename.concat (Sh.temp ()) "myshell") "#!/bin/sh\n" in
  show (Shell.command ~path ~login:real (Some real));
  [%expect
    {|
    zsh -
    zsh -
    bash -
    zsh zsh -l
    zsh fish
    zsh reattach-to-user-namespace -l zsh
    zsh -
    myshell -
    |}]

(* A count: "the new value is in there" holds for an appending version too, and getenv answers
   with the first match. *)
let%expect_test "with_env replaces rather than appends" =
  Shell.with_env
    [| "PATH=/bin"; "ZDOTDIR=/home/me/dots"; "TERM=xterm" |]
    [ ("ZDOTDIR", "/tmp/kido-shell.1"); ("KIDO_ORIG_ZDOTDIR", "/home/me/dots") ]
  |> Array.iter print_endline;
  [%expect
    {|
    PATH=/bin
    TERM=xterm
    ZDOTDIR=/tmp/kido-shell.1
    KIDO_ORIG_ZDOTDIR=/home/me/dots
    |}]

let%expect_test "resolve_login_shell: default-shell, then $SHELL, then /bin/sh" =
  let real = Sh.write (Filename.concat (Sh.temp ()) "myshell") "#!/bin/sh\n" in
  List.iter
    (fun c ->
      print_endline
        (if String.equal (Shell.resolve_login_shell c) real then "real"
         else Shell.resolve_login_shell c))
    [ [ real; "/bin/bash" ]; [ ""; real ]; [ "/no/such/shell"; real ]; [ ""; "" ] ];
  [%expect {|
    real
    real
    real
    /bin/sh
    |}]

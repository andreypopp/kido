open Kido

let ( // ) = Filename.concat

let%expect_test
    "Bin_dir.of_exe: share/kido/bin beside bin/kido, through a symlinked binary, or nothing" =
  let prefix = Sh.temp () in
  ignore (Sh.write (prefix // "share/kido/bin/tmux") "#!/bin/sh\n");
  let exe = Sh.write (prefix // "bin/kido") "" in
  let link = Sh.temp () // "kido" in
  Unix.symlink exe link;
  Printf.printf "direct %b, symlink %b, empty prefix %b\n"
    (Option.equal String.equal (Bin_dir.of_exe exe) (Some (prefix // "share/kido/bin")))
    (Option.equal String.equal (Bin_dir.of_exe link)
       (Some (Unix.realpath (prefix // "share/kido/bin"))))
    (Option.is_none (Bin_dir.of_exe (Sh.temp () // "bin/kido")));
  [%expect {| direct true, symlink true, empty prefix true |}]

(* bin/kido and share/kido are both symlinks Homebrew repoints on upgrade; only the unresolved
   spelling survives `brew cleanup` of the versioned directory. *)
let%expect_test "Bin_dir.of_exe prefers the unresolved, version-stable spelling" =
  let root = Sh.temp () in
  let versioned = root // "Cellar/kido/1.0.0" in
  let real = Sh.write (versioned // "bin/kido") "#!/bin/sh\n" in
  ignore (Sh.write (versioned // "share/kido/bin/tmux") "#!/bin/sh\n");
  Fs.mkdir_p (root // "bin");
  Fs.mkdir_p (root // "share");
  Unix.symlink real (root // "bin/kido");
  Unix.symlink (versioned // "share/kido") (root // "share/kido");
  let exe = Tmux.Exec.invoked_path ~path:"" (root // "bin/kido") in
  Printf.printf "invoked_path unresolved: %b\n" (String.equal exe (root // "bin/kido"));
  Printf.printf "bin dir unresolved: %b\n"
    (Option.equal String.equal (Bin_dir.of_exe exe) (Some (root // "share/kido/bin")));
  [%expect {|
    invoked_path unresolved: true
    bin dir unresolved: true
    |}]

let same a b =
  let a = Unix.stat a and b = Unix.stat b in
  a.st_dev = b.st_dev && a.st_ino = b.st_ino

let recorder dir name =
  Sh.write (dir // name) "#!/bin/sh\nprintf '%s\\0' \"$0\" \"$@\" > \"$ARGV_OUT\"\n"

(* A prefix with a space: nothing in a shim may depend on its location being one word. *)
let install root =
  let prefix = root // "my prefix" in
  let share = prefix // "share/kido" in
  ignore (Sh.output ~env:[] "/bin/sh" [ "/bin/sh"; "../scripts/install-share.sh"; share ]);
  List.iter (fun name -> ignore (recorder (prefix // "bin") name)) [ "kido"; "kido-tmux" ];
  (prefix // "bin", share, share // "bin")

let path_of dirs = String.concat ":" (dirs @ [ "/usr/bin:/bin" ])

(* The shell a kido pane runs looks the name up; the deadline in Sh.run is what a shim that ran
   itself would hit. *)
let run_shim ?(env = []) path name args =
  let out = Sh.temp () // "argv" in
  ignore
    (Sh.output
       ~env:([ "PATH=" ^ path; "ARGV_OUT=" ^ out; "HOME=" ^ Sh.temp () ] @ env)
       "/bin/sh"
       ([ "/bin/sh"; "-c"; {|exec "$0" "$@"|}; name ] @ args));
  let recorded = Option.get_exn_or ("nothing recorded its arguments in " ^ out) (Fs.read out) in
  match
    String.split_on_char '\000'
      (Option.get_or ~default:recorded (String.chop_suffix ~suf:"\000" recorded))
  with
  | prog :: args -> (prog, args)
  | [] -> assert false

let awkward = [ "a  b"; ""; "*"; "$HOME"; "-x" ]

let%expect_test "the shims run what they stand for, with the arguments as given" =
  let root = Sh.temp () in
  let bin, share, shims = install root in
  let real = root // "real" in
  ignore (recorder real "pi");
  ignore (recorder real "claude");
  let path = path_of [ shims; real ] in
  let show name (prog, args) = Printf.printf "%s ran %s %s\n" name prog (String.concat "|" args) in
  let prog, args = run_shim path "tmux" awkward in
  Printf.printf "tmux: kido-tmux %b, args %b\n"
    (same prog (bin // "kido-tmux"))
    (List.equal String.equal args awkward);
  let prog, args = run_shim path "ssh" awkward in
  Printf.printf "ssh: kido %b, args %b\n"
    (same prog (bin // "kido"))
    (List.equal String.equal args ("ssh" :: awkward));
  (match run_shim path "pi" awkward with
  | prog, "--extension" :: status :: "--extension" :: agents :: rest ->
      Printf.printf "pi: real %b, extensions %b %b, args %b\n"
        (String.equal prog (real // "pi"))
        (same status (share // "pi/kido-status.ts"))
        (same agents (share // "pi/kido-agents.ts"))
        (List.equal String.equal rest awkward)
  | r -> show "pi" r);
  (match run_shim path "claude" awkward with
  | prog, "--settings" :: settings :: rest ->
      Printf.printf "claude: real %b, settings %b, args %b\n"
        (String.equal prog (real // "claude"))
        (same settings (share // "claude/settings.json"))
        (List.equal String.equal rest awkward)
  | r -> show "claude" r);
  [%expect
    {|
    tmux: kido-tmux true, args true
    ssh: kido true, args true
    pi: real true, extensions true true, args true
    claude: real true, settings true, args true
    |}]

(* pi reads these from its first argument: --extension in front would turn `pi install x` into a
   session. *)
let%expect_test "the pi shim leaves pi's subcommands alone" =
  let root = Sh.temp () in
  let _, _, shims = install root in
  ignore (recorder (root // "real") "pi");
  List.iter
    (fun sub ->
      let _, args = run_shim (path_of [ shims; root // "real" ]) "pi" [ sub; "x" ] in
      Printf.printf "%s: %s\n" sub (String.concat " " args))
    [ "install"; "remove"; "uninstall"; "update"; "list"; "config"; "auth" ];
  [%expect
    {|
    install: install x
    remove: remove x
    uninstall: uninstall x
    update: update x
    list: list x
    config: config x
    auth: auth x
    |}]

let%expect_test "a shim runs the program past its own directory, never the one ahead or itself" =
  let root = Sh.temp () in
  let _, _, shims = install root in
  let _, _, other = install (root // "other") in
  let before = root // "before" and after = root // "after" in
  ignore (recorder before "pi");
  ignore (recorder after "pi");
  let ran path name = String.equal (fst (run_shim path name [])) (after // "pi") in
  Printf.printf "pi before the shim, one after: %b\n"
    (ran (path_of [ before; shims; after ]) (shims // "pi"));
  Printf.printf "through two installs' shims: %b\n" (ran (path_of [ shims; other; after ]) "pi");
  let out = Sh.temp () // "argv" in
  ignore
    (Sh.output
       ~env:[ "PATH=" ^ path_of [ before ]; "ARGV_OUT=" ^ out ]
       (shims // "pi")
       [ shims // "pi" ]);
  Printf.printf "by path, off PATH: %b\n"
    (String.prefix ~pre:((before // "pi") ^ "\000") (Option.get_or ~default:"" (Fs.read out)));
  (match
     Sh.run ~env:[ "PATH=" ^ shims ^ ":/usr/bin:/bin" ] "/bin/sh" [ "/bin/sh"; "-c"; "exec pi" ]
   with
  | WEXITED code, out ->
      Printf.printf "nothing past it: exit %d, %S\n" code
        (String.replace ~sub:shims ~by:"$SHIMS" out)
  | _ -> print_endline "nothing past it: killed");
  [%expect
    {|
    pi before the shim, one after: true
    through two installs' shims: true
    by path, off PATH: true
    nothing past it: exit 127, "kido: no pi on PATH after $SHIMS\n"
    |}]

let%expect_test "the tmux shim resolves like kido: $KIDO_TMUX, kido-tmux beside kido, tmux past it"
    =
  let root = Sh.temp () in
  let bin, _, shims = install root in
  let real = root // "real" in
  ignore (recorder real "tmux");
  let named = recorder (root // "named") "fork-tmux" in
  let path = path_of [ shims; real ] in
  let ran ?env path = fst (run_shim ?env path "tmux" []) in
  Printf.printf "KIDO_TMUX by path: %b\n"
    (String.equal (ran ~env:[ "KIDO_TMUX=" ^ named ] path) named);
  Printf.printf "KIDO_TMUX by name: %b\n"
    (String.equal (ran ~env:[ "KIDO_TMUX=fork-tmux" ] (path_of [ shims; root // "named" ])) named);
  Printf.printf "beside kido: %b\n" (same (ran path) (bin // "kido-tmux"));
  Unix.unlink (bin // "kido-tmux");
  Printf.printf "past the shim: %b\n" (String.equal (ran path) (real // "tmux"));
  [%expect
    {|
    KIDO_TMUX by path: true
    KIDO_TMUX by name: true
    beside kido: true
    past the shim: true
    |}]

let%expect_test "look_path_past" =
  let root = Sh.temp () in
  let _, _, shims = install root in
  let _, _, other = install (root // "other") in
  let before = recorder (root // "before") "ssh" and after = recorder (root // "after") "ssh" in
  let show path =
    print_endline
      (Option.map_or ~default:"none"
         (fun p -> String.replace ~sub:root ~by:"$ROOT" p)
         (Bin_dir.look_path_past ~path ~dir:shims "ssh"))
  in
  show (path_of [ Filename.dirname before; shims; Filename.dirname after ]);
  show (path_of [ shims; other; Filename.dirname after ]);
  show (path_of [ Filename.dirname before ]);
  show (path_of [ shims ^ "/"; Filename.dirname after ]);
  show shims;
  [%expect
    {|
    $ROOT/after/ssh
    $ROOT/other/my prefix/share/kido/bin/ssh
    $ROOT/before/ssh
    $ROOT/after/ssh
    none
    |}]

let%expect_test "path_with_first" =
  List.iter
    (fun path -> print_endline (Bin_dir.path_with_first "/k" path))
    [ "/usr/bin:/bin"; "/usr/bin:/k:/bin"; "/k:/usr/bin:/k"; "" ];
  [%expect {|
    /k:/usr/bin:/bin
    /k:/usr/bin:/bin
    /k:/usr/bin
    /k
    |}]

(* Twice over a PATH that already has the directory in the middle, as a login file's rewrite and a
   nested shell each produce; the directory is the worst a bin directory can be. *)
let%expect_test "path_prepend_script moves the directory first, once, in sh, bash and zsh" =
  let dir = "/opt/it's a [kido]*/bin" in
  let script =
    Bin_dir.path_prepend_script dir ^ Bin_dir.path_prepend_script dir ^ {|printf '%s' "$PATH"|}
  in
  List.iter
    (fun sh ->
      match Tmux.Exec.look_path ~path:(Sys.getenv "PATH") sh with
      | None -> Printf.printf "%s: skipped\n" sh
      | Some bin ->
          let out = Sh.output ~env:[ "PATH=/usr/bin:" ^ dir ^ ":/bin" ] bin [ bin; "-c"; script ] in
          Printf.printf "%s: %b\n" sh (String.equal out (dir ^ ":/usr/bin:/bin")))
    [ "sh"; "bash"; "zsh" ];
  [%expect {|
    sh: true
    bash: true
    zsh: true
    |}]

(* The far side of `kido ssh` has no kido and no shims. *)
let%expect_test "only a local prime moves PATH" =
  let marker = Bin_dir.path_prepend_script "/k/bin" in
  List.iter
    (fun mode ->
      let moves bin_dir =
        List.exists (fun (_, body) -> String.mem ~sub:"_kido_bin" body) (Prime.files ~bin_dir mode)
      in
      Printf.printf "given a bin dir %b, carries the script %b, without one %b\n"
        (moves (Some "/k/bin"))
        (List.exists
           (fun (_, b) -> String.mem ~sub:marker b)
           (Prime.files ~bin_dir:(Some "/k/bin") mode))
        (moves None))
    [ Prime.Zsh; Bash ];
  Printf.printf "ssh: %b\n"
    (List.exists (String.mem ~sub:"_kido_bin")
       [ Prime.ssh_bootstrap; Embedded.zsh_integration; Embedded.bash_integration ]);
  [%expect
    {|
    given a bin dir true, carries the script true, without one false
    given a bin dir true, carries the script true, without one false
    ssh: false
    |}]

let%expect_test "the shipped claude settings are kido's hooks" =
  let json = Yojson.Safe.from_file "../claude/settings.json" in
  let open Yojson.Safe.Util in
  List.iter
    (fun (event, entries) ->
      match entries with
      | `List [ entry ] -> (
          match member "hooks" entry with
          | `List [ h ] ->
              Printf.printf "%s: %s %S async=%b\n" event
                (to_string (member "type" h))
                (to_string (member "command" h))
                (Option.get_or ~default:false (to_bool_option (member "async" h)))
          | _ -> Printf.printf "%s: not one hook\n" event)
      | _ -> Printf.printf "%s: not one entry\n" event)
    (List.sort (fun (a, _) (b, _) -> String.compare a b) (to_assoc (member "hooks" json)));
  [%expect
    {|
    Notification: command "kido hook" async=true
    PermissionRequest: command "kido hook" async=true
    PostCompact: command "kido hook" async=true
    PostToolUse: command "kido hook" async=true
    PreCompact: command "kido hook" async=true
    PreToolUse: command "kido hook" async=true
    SessionEnd: command "kido hook" async=false
    SessionStart: command "kido hook" async=true
    Stop: command "kido hook" async=true
    SubagentStop: command "kido hook" async=true
    UserPromptSubmit: command "kido hook" async=true
    |}]

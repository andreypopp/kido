let stalled_since ~root ~threshold ~wake ~now ~reported_at =
  let working =
    Option.exists
      (fun (r : Tmux.Program_status.record) ->
        Option.exists (String.equal "pi") r.app
        && match r.state with Working _ -> true | _ -> false)
      root
  in
  working && Float.(now - max reported_at (Option.value wake ~default:neg_infinity) >= threshold)

let wake_file ~dir = Filename.concat dir "wake"
let wake ~dir = Option.flat_map Timestamp.of_string (Fs.read (wake_file ~dir))

let record_pause ~dir at =
  if not (Option.exists (fun prev -> Float.(at <= prev)) (wake ~dir)) then begin
    Fs.mkdir_p ~perm:0o700 dir;
    Fs.write_atomic (wake_file ~dir) (Timestamp.to_string at)
  end

let%test_module "Tests" =
  (module struct
    let temp () = Filename.temp_dir "kido-state" ""

    let%expect_test "the wake marker keeps the latest wake" =
      let dir = temp () in
      let show () =
        print_endline (match wake ~dir with Some x -> Timestamp.to_string x | None -> "none")
      in
      show ();
      record_pause ~dir 1_700_001_000.;
      record_pause ~dir 1_700_000_000.;
      show ();
      [%expect {|
    none
    2023-11-14T22:30:00Z
    |}]
  end)

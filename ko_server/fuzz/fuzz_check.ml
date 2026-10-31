let budget () =
  ( Option.map int_of_string (Sys.getenv_opt "KO_FUZZ_SEED"),
    Option.map float_of_string (Sys.getenv_opt "KO_FUZZ_SECONDS") )

let check ?(seed = 0) ?seconds ~count ~name ~print gen law =
  let run seed n =
    try
      QCheck2.Test.check_exn ~rand:(Random.State.make [| seed |])
        (QCheck2.Test.make ~count:n ~name ~print gen law)
    with e ->
      Printf.eprintf "%s: failed with seed %d\n%!" name seed;
      raise e
  in
  match seconds with
  | None -> run seed count
  | Some budget ->
      let deadline = Unix.gettimeofday () +. budget and seed = ref seed and runs = ref 0 in
      while Float.(Unix.gettimeofday () < deadline) do
        run !seed count;
        incr seed;
        incr runs
      done;
      Printf.printf "%s: %d batches of %d cases in %.0fs\n%!" name !runs count budget

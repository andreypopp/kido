let budget () =
  ( Option.map int_of_string (Sys.getenv_opt "KO_FUZZ_SEED"),
    Option.map float_of_string (Sys.getenv_opt "KO_FUZZ_SECONDS") )

let afl_source () = Sys.getenv_opt "KO_AFL_SOURCE"

(* Monolith.run ends the process with exit, so a test runs it in a child. *)
let monolith ?(prologue = ignore) ~fuel () =
  let run source timeout =
    ignore
      (Monolith.run
         {
           source;
           timeout;
           max_scenarios = 20;
           show_scenario = true;
           save_scenario = false;
           prologue;
           fuel;
         }
        : int)
  in
  let in_child source timeout =
    match Unix.fork () with
    | 0 ->
        run source timeout;
        Unix._exit 0
    | pid -> ( match Unix.waitpid [] pid with _, Unix.WEXITED 0 -> true | _ -> false)
  in
  let scenario seed =
    let file = Filename.temp_file "ko-monolith" "" in
    let rand = Random.State.make [| seed |] in
    Out_channel.with_open_bin file (fun oc ->
        Out_channel.output_string oc
          (String.init 2048 (fun _ -> Char.chr (Random.State.int rand 256))));
    let ok = in_child (Some file) None in
    Sys.remove file;
    if not ok then Printf.eprintf "monolith: failed with seed %d\n%!" seed;
    ok
  in
  match (afl_source (), budget ()) with
  | (Some _ as source), _ ->
      run source None;
      true
  | None, (_, Some seconds) -> in_child None (Some seconds)
  | None, (Some seed, None) -> scenario seed
  | None, (None, None) -> List.for_all scenario (List.init 200 Fun.id)

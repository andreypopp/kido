type t = { pane : Pane.t; client : Ids.Client_id.t option; core : View_core.view }

let client t = t.client
let pane t = t.pane
let waiting t = View_core.view_waiting t.core
let close t = View_core.close t.core

let reject t =
  Delivery_io.reject_io (View_core.conn t.core);
  View_core.close t.core

let guarded t f = try f t.core with Invalid_argument _ -> reject t
let pump t = guarded t View_core.pump

let create pane connection ~client ~offset ~history =
  let proc = Pane.proc pane in
  let view = ref None in
  let request history gen =
    Pane_proc.snapshot proc ~history
      ~consume:(fun pos ->
        match !view with
        | Some t -> ( try View_core.on_slice t.core gen pos with Invalid_argument _ -> reject t)
        | None -> ())
      ~done_:(fun result ->
        match !view with
        | Some t ->
            guarded t (fun core ->
                View_core.on_done core gen (Result.is_ok result);
                View_core.pump core)
        | None -> ())
  in
  let t =
    {
      pane;
      client;
      core = View_core.make_view (Pane_proc.ring proc) connection { Delivery_io.request } history;
    }
  in
  view := Some t;
  guarded t (fun core -> View_core.open_view core offset);
  t

let receive t text =
  let connection = View_core.conn t.core in
  try
    match Protocol.Request.view_of_json (Yojson.Basic.from_string text) with
    | Resync options -> guarded t (fun core -> View_core.request_snapshot core options.history)
    | Input input -> (
        match
          Pane_proc.input (Pane.proc t.pane) input (function
            | Error _ -> Connection.reject connection Io
            | Ok None -> ()
            | Ok (Some reply) ->
                Connection.json connection (Protocol.Event.view_to_json (Pasted reply)))
        with
        | Ok () -> ()
        | Error _ -> Connection.reject connection Invalid)
  with Yojson.Json_error _ | Invalid_argument _ | Jsonkit.Of_json_error _ ->
    Connection.reject connection Invalid

let%test_module "Tests" =
  (module struct
    let%expect_test "resume, resize, threshold only after block" =
      List.iter
        (fun (offset, behind, full, resize, blocked) ->
          print_endline
            (match
               View_core.decide behind offset 100000
                 (if full then History_all else History_none)
                 resize blocked
             with
            | Resume -> "resume"
            | Snapshot History_all -> "full"
            | Snapshot History_none -> "screen"
            | Skip -> "skip"))
        [
          (10, false, true, false, false);
          (9, true, true, false, false);
          (10, false, false, true, false);
          (10, false, true, true, false);
          (10, false, true, false, true);
          (99999, false, false, false, true);
        ];
      [%expect {|
 resume
 full
 screen
 resume
 skip
 resume
 |}]
  end)

let numbers =
  [
    (1000, Ansi.Mouse_tracking);
    (1002, Mouse_button_tracking);
    (1003, Mouse_motion);
    (1006, Mouse_sgr);
    (1004, Focus_tracking);
    (2004, Bracketed_paste);
    (25, Cursor_visible);
  ]

type t = {
  saved : (int * bool) list;
  mutable mouse : Ko_vt.mouse_tracking option;
  mutable keyboard : int option;
}

let set mode b = Ansi.to_string (if b then Ansi.enable mode else Ansi.disable mode)

let save () =
  let attrs = Unix.tcgetattr Unix.stdin and saved = ref [] and done_ = ref false in
  let p = Matrix_input.Parser.create () and events = ref [] in
  let on_event e = events := e :: !events in
  Fun.protect
    ~finally:(fun () -> Unix.tcsetattr Unix.stdin Unix.TCSANOW attrs)
    (fun () ->
      Unix.tcsetattr Unix.stdin Unix.TCSANOW
        {
          attrs with
          c_icanon = false;
          c_echo = false;
          c_isig = false;
          c_ixon = false;
          c_icrnl = false;
          c_opost = false;
          c_vmin = 1;
          c_vtime = 0;
        };
      Fs.write_all Unix.stdout
        (String.concat "" (List.map (fun (n, _) -> Printf.sprintf "\027[?%d$p" n) numbers)
        ^ Ansi.to_string (Ansi.query Device_attributes));
      let deadline = Unix.gettimeofday () +. 0.15 and buf = Bytes.create 4096 in
      let rec receive () =
        let remaining = deadline -. Unix.gettimeofday () in
        if (not !done_) && Float.(remaining > 0.) then
          let ready, _, _ = Unix.select [ Unix.stdin ] [] [] remaining in
          if not (List.is_empty ready) then
            let n = Unix.read Unix.stdin buf 0 (Bytes.length buf) in
            if n > 0 then (
              Matrix_input.Parser.feed p buf 0 n ~now:(Unix.gettimeofday ()) ~on_event
                ~on_response:(function
                | Capability (Mode_report { is_private = true; modes }) ->
                    List.iter
                      (fun (n, value) ->
                        if value >= 1 && value <= 4 && List.mem_assoc ~eq:Int.equal n numbers then
                          saved :=
                            (n, value = 1 || value = 3) :: List.remove_assoc ~eq:Int.equal n !saved)
                      modes
                | Capability (Device_attributes _) -> done_ := true
                | _ -> ());
              receive ())
      in
      receive ();
      Matrix_input.Parser.drain p ~now:(deadline +. 1.) ~on_event ~on_response:ignore);
  ({ saved = !saved; mouse = None; keyboard = None }, List.rev !events)

let reset t =
  Fs.write_all Unix.stdout
    (String.concat ""
       (List.filter_map (fun (n, m) -> if n = 25 then None else Some (set m false)) numbers)
    ^ (match t.keyboard with None -> "" | Some _ -> Ansi.to_string Ansi.csi_u_pop)
    ^ Ansi.to_string (Ansi.cursor_style ~shape:`Default));
  t.mouse <- None;
  t.keyboard <- None

let apply t (f : Ko_vt.frame) =
  let b = Buffer.create 100 in
  if not (Option.equal Ko_vt.equal_mouse_tracking t.mouse (Some f.mouse)) then (
    let tracking = function Ko_vt.Button -> 1002 | Any -> 1003 | Off | Press -> 1000 in
    let wanted = tracking f.mouse in
    let previous =
      match t.mouse with
      | Some m -> [ tracking m ]
      | None ->
          List.filter
            (fun n -> List.exists (fun (k, on) -> k = n && on) t.saved)
            [ 1000; 1002; 1003 ]
    in
    let emit n on = Buffer.add_string b (set (List.assoc ~eq:Int.equal n numbers) on) in
    List.iter (fun n -> if n <> wanted then emit n false) previous;
    emit wanted true;
    List.iter
      (fun m -> Buffer.add_string b (set m true))
      [ Ansi.Mouse_sgr; Focus_tracking; Bracketed_paste ];
    t.mouse <- Some f.mouse);
  let keyboard = f.keyboard lor 1 in
  if not (Option.equal Int.equal t.keyboard (Some keyboard)) then (
    Option.iter (fun _ -> Buffer.add_string b (Ansi.to_string Ansi.csi_u_pop)) t.keyboard;
    Buffer.add_string b (Ansi.to_string (Ansi.csi_u_push ~flags:keyboard));
    t.keyboard <- Some keyboard);
  Buffer.contents b

let restore t =
  let off, on =
    List.partition
      (fun (_, on) -> not on)
      (List.map
         (fun (n, m) ->
           (m, Option.value ~default:(n = 25) (List.assoc_opt ~eq:Int.equal n t.saved)))
         numbers)
  in
  Fs.write_all Unix.stdout
    (String.concat "" (List.map (fun (m, on) -> set m on) (off @ on))
    ^ Ansi.to_string (Ansi.cursor_style ~shape:`Default))

type stats = { mutable frames : int; mutable stamps : float list; mutable keys : int }

let stats = { frames = 0; stamps = []; keys = 0 }
let colors = Array.init 256 Ansi.Color.indexed
let letters = Array.init 26 (fun i -> Matrix.Grid.Cell.of_uchar (Uchar.of_int (97 + i)))
let ch x y f = (x + y + f) mod 26
let fg x f = 16 + (((x * 7) + f) mod 216)
let bg y f = 16 + (((y * 5) + (f * 3)) mod 216)
let marker () = String.make 8 (Char.chr (65 + (stats.keys mod 26)))

let frame () =
  stats.frames <- stats.frames + 1;
  stats.stamps <- Unix.gettimeofday () :: stats.stamps

let draw_grid grid ~width ~height =
  let f = stats.frames in
  for y = 0 to height - 1 do
    for x = 0 to width - 1 do
      Matrix.Grid.set_cell grid ~x ~y
        ~cell:letters.(ch x y f)
        ~fg:colors.(fg x f)
        ~bg:colors.(bg y f)
        ~attrs:Ansi.Attr.empty ()
    done
  done;
  Matrix.Grid.draw_text grid ~x:(width - 8) ~y:(height - 1)
    ~style:(Ansi.Style.make ~fg:colors.(15) ~bg:colors.(0) ())
    ~text:(marker ())

let write_stats path =
  let stamps = Array.of_list (List.rev stats.stamps) in
  let n = Array.length stamps in
  let gaps = Array.init (max 0 (n - 1)) (fun i -> stamps.(i + 1) -. stamps.(i)) in
  Array.sort Float.compare gaps;
  let pct p = if Array.length gaps = 0 then 0. else gaps.(Array.length gaps * p / 100) in
  let wall = if n < 2 then 0. else stamps.(n - 1) -. stamps.(0) in
  let oc = open_out path in
  Printf.fprintf oc "frames %d\nwall %f\nfps %f\ngap_p50_ms %f\ngap_p99_ms %f\nkeys %d\n" n wall
    (if Float.(wall > 0.) then Float.of_int (n - 1) /. wall else 0.)
    (pct 50 *. 1000.)
    (pct 99 *. 1000.)
    stats.keys;
  close_out oc

let is_x (k : Matrix.Input.Key.event) =
  match k.key with Char u -> Uchar.to_int u = Char.code 'x' | _ -> false

let fps () = Option.value ~default:60. (Option.map Float.of_string (Sys.getenv_opt "FPS"))

let run_mosaic seconds =
  let open Mosaic in
  let elapsed = ref 0. in
  let app =
    {
      init = (fun () -> ((), Cmd.none));
      update = (fun quit () -> ((), if quit then Cmd.quit else Cmd.none));
      view =
        (fun () ->
          canvas ~live:true
            ~size:{ width = pct 100; height = pct 100 }
            (fun c ~delta:_ ->
              frame ();
              draw_grid (Canvas.grid c) ~width:(Canvas.width c) ~height:(Canvas.height c)));
      subscriptions =
        (fun () ->
          Sub.batch
            [
              Sub.on_tick (fun ~dt ->
                  elapsed := !elapsed +. dt;
                  Float.(!elapsed > seconds));
              Sub.On_key_all
                (fun k ->
                  let k = Event.Key.data k in
                  if is_x k then stats.keys <- stats.keys + 1;
                  None);
            ]);
    }
  in
  run ~matrix:(Matrix.create ~target_fps:(Some (fps ())) ~cursor_visible:false ()) app

let run_matrix seconds =
  let app = Matrix.create ~target_fps:(Some (fps ())) () in
  let start = Unix.gettimeofday () in
  Matrix.run app
    ~on_input:(fun _ -> function
      | Matrix.Input.Key k when is_x k ->
          stats.keys <- stats.keys + 1;
          if Option.is_some (Sys.getenv_opt "IMMEDIATE") then Matrix.request_immediate_redraw app
          else Matrix.request_redraw app
      | _ -> ())
    ~on_frame:(fun app ~dt:_ ->
      if Float.(Unix.gettimeofday () -. start > seconds) then Matrix.stop app)
    ~on_render:(fun app ->
      frame ();
      let width, height = Matrix.size app in
      draw_grid (Matrix.grid app) ~width ~height);
  Matrix.close app

type out = { buf : Bytes.t; mutable len : int }

let add_char o c =
  Bytes.unsafe_set o.buf o.len c;
  o.len <- o.len + 1

let add_string o str =
  Bytes.blit_string str 0 o.buf o.len (String.length str);
  o.len <- o.len + String.length str

let rec add_int o n =
  if n >= 10 then add_int o (n / 10);
  add_char o (Char.unsafe_chr (48 + (n mod 10)))

let flush o =
  let rec go off = if off < o.len then go (off + Unix.write Unix.stdout o.buf off (o.len - off)) in
  go 0;
  o.len <- 0

let run_direct seconds ~width ~height =
  let attrs = Unix.tcgetattr Unix.stdin in
  Unix.tcsetattr Unix.stdin TCSANOW
    {
      attrs with
      c_icanon = false;
      c_echo = false;
      c_isig = false;
      c_vmin = 1;
      c_vtime = 0;
      c_ixon = false;
      c_icrnl = false;
      c_opost = false;
    };
  let b = { buf = Bytes.create ((width * height * 32) + 64); len = 0 } in
  add_string b "\027[?1049h\027[?25l";
  flush b;
  let n = width * height in
  let cur_ch = Array.make n (-1) and cur_fg = Array.make n (-1) and cur_bg = Array.make n (-1) in
  let nxt_ch = Array.make n 0 and nxt_fg = Array.make n 0 and nxt_bg = Array.make n 0 in
  let rd = Bytes.create 256 in
  let start = Unix.gettimeofday () in
  let next = ref start in
  let render () =
    frame ();
    let f = stats.frames in
    for y = 0 to height - 1 do
      for x = 0 to width - 1 do
        let i = (y * width) + x in
        nxt_ch.(i) <- 97 + ch x y f;
        nxt_fg.(i) <- fg x f;
        nxt_bg.(i) <- bg y f
      done
    done;
    String.iteri
      (fun x c ->
        nxt_ch.(n - 8 + x) <- Char.code c;
        nxt_fg.(n - 8 + x) <- 15;
        nxt_bg.(n - 8 + x) <- 0)
      (marker ());
    let pen_fg = ref (-1) and pen_bg = ref (-1) and pos = ref (-1) in
    for i = 0 to n - 1 do
      if cur_ch.(i) <> nxt_ch.(i) || cur_fg.(i) <> nxt_fg.(i) || cur_bg.(i) <> nxt_bg.(i) then begin
        if !pos <> i then (
          add_string b "\027[";
          add_int b ((i / width) + 1);
          add_char b ';';
          add_int b ((i mod width) + 1);
          add_char b 'H');
        (match (!pen_fg <> nxt_fg.(i), !pen_bg <> nxt_bg.(i)) with
        | true, true ->
            add_string b "\027[38;5;";
            add_int b nxt_fg.(i);
            add_string b ";48;5;";
            add_int b nxt_bg.(i);
            add_char b 'm'
        | true, false ->
            add_string b "\027[38;5;";
            add_int b nxt_fg.(i);
            add_char b 'm'
        | false, true ->
            add_string b "\027[48;5;";
            add_int b nxt_bg.(i);
            add_char b 'm'
        | false, false -> ());
        pen_fg := nxt_fg.(i);
        pen_bg := nxt_bg.(i);
        add_char b (Char.chr nxt_ch.(i));
        pos := i + 1;
        cur_ch.(i) <- nxt_ch.(i);
        cur_fg.(i) <- nxt_fg.(i);
        cur_bg.(i) <- nxt_bg.(i)
      end
    done;
    add_string b "\027[0m";
    flush b
  in
  let dirty = ref true in
  while Float.(Unix.gettimeofday () -. start < seconds) do
    let now = Unix.gettimeofday () in
    if Float.(now >= !next) then begin
      render ();
      dirty := false;
      next := Float.max (!next +. (1. /. 60.)) (now -. (1. /. 60.))
    end
    else if !dirty then (
      render ();
      dirty := false)
    else
      match Unix.select [ Unix.stdin ] [] [] (!next -. now) with
      | [], _, _ -> ()
      | _ ->
          let k = Unix.read Unix.stdin rd 0 256 in
          for i = 0 to k - 1 do
            if Char.equal (Bytes.get rd i) 'x' then (
              stats.keys <- stats.keys + 1;
              dirty := true)
          done
  done;
  add_string b "\027[0m\027[?25h\027[?1049l";
  flush b;
  Unix.tcsetattr Unix.stdin TCSANOW attrs

let () =
  match Array.to_list Sys.argv with
  | [ _; mode; seconds; out; width; height ] ->
      let seconds = Float.of_string seconds in
      (match mode with
      | "mosaic" -> run_mosaic seconds
      | "matrix" -> run_matrix seconds
      | "direct" -> run_direct seconds ~width:(int_of_string width) ~height:(int_of_string height)
      | m -> failwith ("unknown mode " ^ m));
      write_stats out
  | _ ->
      prerr_endline "usage: main mosaic|matrix|direct SECONDS STATS COLS ROWS";
      exit 2

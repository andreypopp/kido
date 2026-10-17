module Tmux_vars = Kido.Tmux_vars
module Style = Mosaic.Ansi.Style
module Color = Mosaic.Ansi.Color

type role =
  [ `Plain | `Proc | `Dim | `Session | `Current | `Err | `Running | `Waiting | `Done | `Stalled ]

type t = {
  row : Style.t;
  command : Style.t;
  dim : Style.t;
  error : Style.t;
  running : Style.t;
  waiting : Style.t;
  done_ : Style.t;
  stalled : Style.t;
  session : Style.t;
  current : Style.t;
  current_rows : Color.t option;
}

(* Every style names its foreground: Mosaic's grid paints an explicit white on any cell left
   without one, which would override the user's theme. *)
let default =
  {
    row = Style.make ~fg:Color.default ();
    command = Style.make ~fg:Color.white ();
    dim = Style.make ~fg:Color.bright_black ();
    error = Style.make ~fg:Color.red ();
    running = Style.make ~fg:Color.green ();
    waiting = Style.make ~fg:Color.yellow ~bold:true ();
    done_ = Style.make ~fg:Color.green ~bold:true ();
    stalled = Style.make ~fg:Color.red ~bold:true ();
    session = Style.make ~fg:Color.default ();
    current = Style.make ~fg:Color.default ~bold:true ();
    current_rows = None;
  }

let style t : role -> Style.t = function
  | `Plain -> t.row
  | `Proc -> t.command
  | `Dim -> t.dim
  | `Err -> t.error
  | `Running -> t.running
  | `Waiting -> t.waiting
  | `Done -> t.done_
  | `Stalled -> t.stalled
  | `Session -> t.session
  | `Current -> t.current

let current_rows t = t.current_rows

let options =
  [
    (Tmux_vars.sidebar_row_style, fun t s -> { t with row = s });
    (Tmux_vars.sidebar_command_style, fun t s -> { t with command = s });
    (Tmux_vars.sidebar_dim_style, fun t s -> { t with dim = s });
    (Tmux_vars.sidebar_error_style, fun t s -> { t with error = s });
    (Tmux_vars.sidebar_running_style, fun t s -> { t with running = s });
    (Tmux_vars.sidebar_waiting_style, fun t s -> { t with waiting = s });
    (Tmux_vars.sidebar_done_style, fun t s -> { t with done_ = s });
    (Tmux_vars.sidebar_stalled_style, fun t s -> { t with stalled = s });
    (Tmux_vars.sidebar_session_style, fun t s -> { t with session = s });
    (Tmux_vars.sidebar_current_style, fun t s -> { t with current = s });
    (Tmux_vars.sidebar_current_rows_style, fun t (s : Style.t) -> { t with current_rows = s.bg });
  ]

let format = String.concat "\x1f" (List.map (fun (name, _) -> "#{" ^ name ^ "}") options)

let colour s =
  let named =
    [
      ("black", Color.black, Color.bright_black);
      ("red", Color.red, Color.bright_red);
      ("green", Color.green, Color.bright_green);
      ("yellow", Color.yellow, Color.bright_yellow);
      ("blue", Color.blue, Color.bright_blue);
      ("magenta", Color.magenta, Color.bright_magenta);
      ("cyan", Color.cyan, Color.bright_cyan);
      ("white", Color.white, Color.bright_white);
    ]
  in
  if String.equal s "default" || String.equal s "terminal" then Some Color.default
  else if String.prefix ~pre:"#" s then Color.of_hex s
  else
    match (String.chop_prefix ~pre:"colour" s, String.chop_prefix ~pre:"color" s) with
    | Some n, _ | None, Some n -> (
        match int_of_string_opt n with
        | Some i when i >= 0 && i <= 255 -> Some (Color.indexed i)
        | _ -> None)
    | None, None ->
        List.find_map
          (fun (name, c, bright) ->
            if String.equal s name then Some c
            else if String.equal s ("bright" ^ name) then Some bright
            else None)
          named

let style_token style tok =
  let attrs =
    [
      ("bold", Style.with_bold);
      ("bright", Style.with_bold);
      ("dim", Style.with_dim);
      ("italics", Style.with_italic);
      ("underscore", Style.with_underline);
      ("double-underscore", Style.with_double_underline);
      ("blink", Style.with_blink);
      ("reverse", Style.with_inverse);
      ("hidden", Style.with_hidden);
      ("strikethrough", Style.with_strikethrough);
      ("overline", Style.with_overline);
    ]
  in
  let attr name on =
    Option.map (fun f -> f on style) (List.assoc_opt ~eq:String.equal name attrs)
  in
  match String.Split.left ~by:"=" tok with
  | Some ((("fg" | "bg") as layer), c) -> (
      match colour c with
      | Some c -> Ok ((if String.equal layer "fg" then Style.fg else Style.bg) c style)
      | None -> Error (Printf.sprintf "unknown colour %S" c))
  | Some _ -> Error (Printf.sprintf "unsupported %S" tok)
  | None -> (
      match tok with
      | "none" -> Ok (Style.with_attrs Mosaic.Ansi.Attr.empty style)
      | "default" -> Ok (Style.with_no_bg (Style.with_no_fg style))
      | _ -> (
          match
            ( attr tok true,
              Option.flat_map (fun a -> attr a false) (String.chop_prefix ~pre:"no" tok) )
          with
          | Some s, _ | None, Some s -> Ok s
          | None, None -> Error (Printf.sprintf "unknown attribute %S" tok)))

let parse_style s =
  String.split_on_char ',' (String.map (function ' ' -> ',' | c -> c) s)
  |> List.filter (fun t -> not (String.is_empty t))
  |> List.fold_left
       (fun acc tok -> Result.flat_map (fun st -> style_token st tok) acc)
       (Ok Style.default)
  |> Result.map (fun (st : Style.t) ->
      if Option.is_none st.fg then Style.fg Color.default st else st)

let load reply =
  let fields = String.split ~by:"\x1f" reply in
  if List.length fields <> List.length options then (default, None)
  else
    let first = ref None in
    let pick name v =
      if String.is_empty v then None
      else
        match parse_style v with
        | Ok s -> Some s
        | Error e ->
            if Option.is_none !first then first := Some (Printf.sprintf "%s: %s" name e);
            None
    in
    let theme =
      List.fold_left2
        (fun t (name, update) v -> match pick name v with Some s -> update t s | None -> t)
        default options fields
    in
    (theme, !first)

let%test_module "Tests" =
  (module struct
    let show_style = function
      | Ok st -> Format.printf "%a@." Style.pp st
      | Error e -> print_endline ("error: " ^ e)

    let%expect_test "every role names its foreground" =
      List.iter
        (fun r -> show_style (Ok (style default r)))
        [ `Plain; `Current; `Session; `Proc; `Dim; `Err; `Running; `Waiting; `Done; `Stalled ];
      [%expect
        {|
    Style{fg=#000000}
    Style{fg=#000000, attrs=[Bold]}
    Style{fg=#000000}
    Style{fg=#c0c0c0}
    Style{fg=#808080}
    Style{fg=#800000}
    Style{fg=#008000}
    Style{fg=#808000, attrs=[Bold]}
    Style{fg=#008000, attrs=[Bold]}
    Style{fg=#800000, attrs=[Bold]}
    |}]

    let%expect_test "parse_style: tmux's style syntax" =
      List.iter
        (fun s ->
          Printf.printf "%-30S " s;
          show_style (parse_style s))
        [
          "fg=#eee8d5";
          "fg=colour240 italics";
          "bg=#123c48,bold,fg=brightred";
          "fg=color33,bright";
          "bold,nobold,dim";
          "fg=red,default";
          "bg=blue,none";
          "";
          "fg=nope";
          "fg=colour256";
          "align=left";
          "blinky";
        ];
      [%expect
        {|
    "fg=#eee8d5"                   Style{fg=#eee8d5}
    "fg=colour240 italics"         Style{fg=#585858, attrs=[Italic]}
    "bg=#123c48,bold,fg=brightred" Style{fg=#ff0000, bg=#123c48, attrs=[Bold]}
    "fg=color33,bright"            Style{fg=#0087ff, attrs=[Bold]}
    "bold,nobold,dim"              Style{fg=#000000, attrs=[Dim]}
    "fg=red,default"               Style{fg=#000000}
    "bg=blue,none"                 Style{fg=#000000, bg=#000080}
    ""                             Style{fg=#000000}
    "fg=nope"                      error: unknown colour "nope"
    "fg=colour256"                 error: unknown colour "colour256"
    "align=left"                   error: unsupported "align=left"
    "blinky"                       error: unknown attribute "blinky"
    |}]

    let%expect_test "load: unset keeps a default, the first bad value is reported and keeps it too"
        =
      let report reply =
        let theme, err = load reply in
        List.iter
          (fun r -> Format.printf "%a " Style.pp (style theme r))
          [ `Plain; `Dim; `Session; `Current ];
        Format.printf "@.rows=%s error=%s@."
          (match theme.current_rows with Some x -> Color.to_hex x | None -> "-")
          (Option.get_or ~default:"-" err)
      in
      let reply values = String.concat "\x1f" values in
      report (reply (List.init 11 (fun _ -> "")));
      report
        (reply
           [
             "fg=#eee8d5";
             "";
             "";
             "";
             "";
             "";
             "";
             "";
             "fg=#c9d1cf,bold,bg=#123c48";
             "fg=#fdf6e3,bold,bg=#1f5566";
             "bg=#0f3a47";
           ]);
      report (reply [ ""; ""; "fg=bogus"; ""; ""; ""; ""; ""; "fg=worse"; ""; "" ]);
      report "fg=red";
      report (reply (List.init 12 (fun _ -> "fg=red")));
      [%expect
        {|
    Style{fg=#000000} Style{fg=#808080} Style{fg=#000000} Style{fg=#000000, attrs=[Bold]}
    rows=- error=-
    Style{fg=#eee8d5} Style{fg=#808080} Style{fg=#c9d1cf, bg=#123c48, attrs=[Bold]} Style{fg=#fdf6e3, bg=#1f5566, attrs=[Bold]}
    rows=#0f3a47 error=-
    Style{fg=#000000} Style{fg=#808080} Style{fg=#000000} Style{fg=#000000, attrs=[Bold]}
    rows=- error=@kido-sidebar-dim-style: unknown colour "bogus"
    Style{fg=#000000} Style{fg=#808080} Style{fg=#000000} Style{fg=#000000, attrs=[Bold]}
    rows=- error=-
    Style{fg=#000000} Style{fg=#808080} Style{fg=#000000} Style{fg=#000000, attrs=[Bold]}
    rows=- error=-
    |}]
  end)

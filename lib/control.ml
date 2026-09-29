open Tmux

let is_window_id s =
  String.length s > 1
  && Char.equal s.[0] '@'
  && String.for_all Char.Ascii.is_digit (String.drop 1 s)

let window_focused ~panes window =
  if String.is_empty window then failwith "usage: kido window-focused WINDOW_ID";
  if not (is_window_id window) then
    failwith (Printf.sprintf "window-focused: %S is not a window id (@N)" window);
  print_endline (Bool.to_string (Pane.window_focused (Lazy.force panes) window));
  0

let switch f ~client ~side_client ~next =
  f
    ~client:
      (List.find_opt (fun c -> not (String.is_empty c)) [ client; side_client ]
      |> Option.get_lazy Exec.current_client)
    ~next;
  0

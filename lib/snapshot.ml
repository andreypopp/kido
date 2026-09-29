open Tmux

type window = { session : string; index : int; layout : string; n : int }

let pane_command (p : Pane.t) states ~pi =
  match State.String_map.find_opt p.pane_id states with
  | Some (id, ({ agent = Pi; _ } : State.session)) ->
      if String.is_empty id then "pi" else "pi --session " ^ id
  | Some (id, { agent = Claude; _ }) ->
      if String.is_empty id then "claude --continue" else "claude --resume " ^ id
  | _ when String.equal p.current_command "claude" -> "claude --continue"
  | _ when Procs.Int_set.mem p.pane_pid pi -> "pi"
  | _ -> ""

let snapshot ~dir =
  let panes = Exec.list_panes () in
  let states = State.by_pane (State.load_live ~dir) in
  let pi = (Procs.sweep ()).pi in
  let q = Conn.quote in
  let tm = Unix.localtime (Unix.time ()) in
  Printf.printf
    "#!/bin/sh\n# tmux sessions captured by kido snapshot on %04d-%02d-%02d %02d:%02d.\n"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min;
  print_endline "# Run outside tmux, then attach. Claude Code and pi panes resume their session.";
  print_endline "set -e\nT=${TMUX_BIN:-tmux}";
  let close = function
    | Some w when not (String.is_empty w.layout) ->
        Printf.printf "$T select-layout -t \"$p0\" %s\n" (q w.layout)
    | _ -> ()
  in
  let step prev (p : Pane.t) =
    let w =
      match prev with
      | Some w when String.equal w.session p.session_name && w.index = p.window_index ->
          let n = w.n + 1 in
          Printf.printf "p%d=$($T split-window -d -P -F '#{pane_id}' -t \"$p%d\" -c %s)\n" n w.n
            (q p.current_path);
          { w with n }
      | _ ->
          close prev;
          let name = if String.is_empty p.window_name then "" else " -n " ^ q p.window_name in
          (match prev with
          | Some w when String.equal w.session p.session_name ->
              Printf.printf "p0=$($T new-window -d -P -F '#{pane_id}' -t %s%s -c %s)\n"
                (q p.session_name) name (q p.current_path)
          | _ ->
              Printf.printf "\n# --- %s\n" p.session_name;
              Printf.printf "p0=$($T new-session -d -P -F '#{pane_id}' -s %s%s -c %s)\n"
                (q p.session_name) name (q p.current_path));
          { session = p.session_name; index = p.window_index; layout = p.window_layout; n = 0 }
    in
    let cmd = pane_command p states ~pi in
    if not (String.is_empty cmd) then
      Printf.printf "$T send-keys -t \"$p%d\" %s Enter\n" w.n (q cmd);
    if p.active then
      Printf.printf "$T select-window -t \"$p%d\"; $T select-pane -t \"$p%d\"\n" w.n w.n;
    Some w
  in
  close (List.fold_left step None panes);
  print_endline {|echo "recreated: $($T list-sessions -F '#{session_name}' | tr '\n' ' ')"|};
  0

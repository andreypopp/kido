let pane ?(session = "a") ?(created = 100.) ?(session_id = "$0") ?(index = 0) ?(window = "@1")
    ?(active = false) ?(attached = false) ?(running = false) ?start ?prompt ?run ?(pid = 0)
    ?(cmd = "") ?(cwd = "") ?(title = "") id : Tmux.Pane.t =
  {
    session_name = session;
    session_id;
    session_created = created;
    window_index = index;
    window_id = window;
    window_name = "";
    window_layout = "";
    pane_id = id;
    active;
    pane_pid = pid;
    current_command = cmd;
    current_path = cwd;
    alternate_on = false;
    command_running = running;
    command_start = start;
    last_prompt = prompt;
    last_exit = None;
    command_line = "";
    dead_at = None;
    run;
    session_attached = attached;
    title;
  }

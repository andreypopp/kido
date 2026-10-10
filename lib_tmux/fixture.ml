let pane ?(session = "a") ?(created = 100.) ?(session_id = "$0") ?(index = 0) ?(window = "@1")
    ?(active = false) ?(attached = false) ?(running = false) ?start ?prompt ?run ?(pid = 0)
    ?(cmd = "") ?(cwd = "") ?(title = "") id : Pane.t =
  {
    session_name = session;
    session_id = Option.get_exn_or "id" (Session.of_string session_id);
    session_created = created;
    window_index = index;
    window_id = Option.get_exn_or "id" (Window.of_string window);
    window_name = "";
    window_layout = "";
    pane_id = Option.get_exn_or "id" (Pane.of_string id);
    active;
    pane_active = active;
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
    ssh = None;
    session_attached = attached;
    program_status = { serial = 0; records = [] };
    title;
  }

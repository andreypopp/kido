type t = {
  id : Ids.Pane_id.t;
  proc : Pane_proc.t;
  command : string list;
  mutable size : Protocol.size;
  mutable sizer : Ids.Client_id.t option;
}

let id t = t.id
let proc t = t.proc
let sizer t = t.sizer

let row t : Protocol.row =
  {
    id = t.id;
    pid = Option.value ~default:0 (Pane_proc.child_pid t.proc);
    command = t.command;
    cwd = Pane_proc.cwd t.proc;
    title = Pane_proc.title t.proc;
    dead = Pane_proc.dead t.proc;
  }

let create config ~id ~cwd ~command ~env ~notify =
  {
    id;
    proc = Pane_proc.create config ~id ~cwd ~argv:command ~env ~notify:(notify id);
    command;
    size = Protocol.default_size;
    sizer = None;
  }

let resize t size =
  if not (Protocol.equal_size t.size size) then begin
    t.size <- size;
    Pane_proc.resize t.proc size
  end

let claim t ~client ~size =
  t.sizer <- Some client;
  resize t size

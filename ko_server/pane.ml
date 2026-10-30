type event =
  | Title of string
  | Pwd of string
  | Dead of Protocol.dead
  | Failed of Protocol.dead
  | Output

type t = {
  id : string;
  proc : Pane_proc.t;
  command : string list;
  mutable cwd : string;
  mutable title : string;
  mutable pid : int;
  mutable dead : Protocol.dead option;
  mutable size : Config.size;
  mutable sizer : string option;
  mutable offset : int;
}

let id t = t.id
let proc t = t.proc
let offset t = t.offset
let sizer t = t.sizer

let row t : Protocol.row =
  { id = t.id; pid = t.pid; command = t.command; cwd = t.cwd; title = t.title; dead = t.dead }

let create config ~id ~cwd ~command ~env ~notify =
  let proc = Pane_proc.create config ~id ~cwd ~argv:command ~env in
  let t =
    {
      id;
      proc;
      command;
      cwd;
      title = "";
      pid = 0;
      dead = None;
      size = Config.default_size;
      sizer = None;
      offset = 0;
    }
  in
  Pane_proc.listen proc (function
    | Ready_pid pid -> t.pid <- pid
    | Title_changed title ->
        t.title <- title;
        notify t (Title title)
    | Pwd_changed pwd ->
        t.cwd <- pwd;
        notify t (Pwd pwd)
    | Record record -> (
        match record.data with
        | Bytes -> t.offset <- record.offset + record.len
        | Dead_marker dead ->
            t.dead <- Some dead;
            notify t (Dead dead)
        | _ -> ())
    | Published -> notify t Output
    | Failed dead ->
        t.dead <- Some dead;
        notify t (Failed dead));
  t

let resize t size =
  if not (Config.equal_size t.size size) then begin
    t.size <- size;
    let b = Buffer.create 8 in
    Pane_proc.size b size;
    Pane_proc.send t.proc Resize (Buffer.contents b)
  end

let claim t ~client ~size =
  t.sizer <- Some client;
  resize t size

let shutdown t = Pane_proc.shutdown t.proc

let kill t =
  Pane_proc.kill t.proc;
  if t.pid > 0 then
    (* macOS can return EPERM for a process group with only zombies or exiting processes. *)
    try Unix.kill (-t.pid) Sys.sigkill
    with Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> ()

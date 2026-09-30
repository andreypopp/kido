val pane :
  ?session:string ->
  ?created:float ->
  ?session_id:string ->
  ?index:int ->
  ?window:string ->
  ?active:bool ->
  ?attached:bool ->
  ?running:bool ->
  ?start:float ->
  ?prompt:float ->
  ?run:string ->
  ?pid:int ->
  ?cmd:string ->
  ?cwd:string ->
  ?title:string ->
  string ->
  Tmux.Pane.t

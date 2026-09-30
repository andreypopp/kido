type mode = Plain | Zsh | Bash

val shell_args : mode -> string list
val local : zdotdir:string option -> bin_dir:string option -> mode -> (string * string) list
val local_mode : dotdir:string -> string -> mode
val ssh_bootstrap : string

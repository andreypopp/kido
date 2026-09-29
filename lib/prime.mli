type mode = Plain | Zsh | Bash

val files : bin_dir:string option -> mode -> (string * string) list
val shell_args : mode -> string list
val bash_has_ps0 : string -> bool
val zshenv : string
val local : zdotdir:string option -> bin_dir:string option -> mode -> (string * string) list
val local_mode : dotdir:string -> string -> mode
val ssh_bootstrap : string

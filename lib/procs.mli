type ssh_option

type ssh_args = private {
  opts : string list;
  options : ssh_option list;
  dest : string;
  command : string list;
}

val split_fields : string -> string list list
val parse_ssh : string list -> ssh_args option
val ssh_letters : ssh_args -> string

type ssh_connection_args [@@deriving yojson_of]

val ssh_connection_args : ssh_args -> ssh_connection_args option
val ssh_connection_args_json : ssh_connection_args -> string

val connect : socket:string -> deadline:float -> Unix.file_descr
val attach : dir:string -> executable:string -> (string * Unix.file_descr, string) result
val stop : dir:string -> (unit, string) result

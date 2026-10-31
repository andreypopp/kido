external get16 : Bigstringaf.t -> int -> int = "%caml_bigstring_get16"
external get32 : Bigstringaf.t -> int -> int32 = "%caml_bigstring_get32"
external get64 : Bigstringaf.t -> int -> int64 = "%caml_bigstring_get64"

let uint16 buffer at = get16 buffer at land 0xffff
let int32 buffer at = Int32.to_int (get32 buffer at)
let int64 buffer at = Int64.to_int (get64 buffer at)

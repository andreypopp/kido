type t = { queue : string Queue.t; strings : string array; mutable sent : int; mutable bytes : int }
type flushed = Done | Blocked | Failed

let create () = { queue = Queue.create (); strings = Array.make 64 ""; sent = 0; bytes = 0 }

let add t s =
  Queue.add s t.queue;
  t.bytes <- t.bytes + String.length s

let is_empty t = Queue.is_empty t.queue
let bytes t = t.bytes

let rec flush t fd =
  if Queue.is_empty t.queue then Done
  else begin
    let rec fill i seq =
      if i = Array.length t.strings then i
      else
        match seq () with
        | Seq.Nil -> i
        | Seq.Cons (s, rest) ->
            t.strings.(i) <- s;
            fill (i + 1) rest
    in
    let count = fill 0 (Queue.to_seq t.queue) in
    let n = Native.write_strings fd t.strings count t.sent in
    Array.fill t.strings 0 count "";
    if n < 0 then Failed
    else if n = 0 then Blocked
    else begin
      t.bytes <- t.bytes - n;
      let left = ref (n + t.sent) in
      while
        match Queue.peek_opt t.queue with Some s -> !left >= String.length s | None -> false
      do
        left := !left - String.length (Queue.take t.queue)
      done;
      t.sent <- !left;
      flush t fd
    end
  end

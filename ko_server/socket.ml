let connect ~socket ~deadline =
  let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  try
    Unix.set_nonblock fd;
    let rec dial () =
      try Unix.connect fd (Unix.ADDR_UNIX socket) with
      | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          let remaining = deadline -. Unix.gettimeofday () in
          if Float.(remaining <= 0.) then
            raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", socket));
          ignore (Unix.select [] [] [] (Float.min remaining 0.01));
          dial ()
      | Unix.Unix_error (Unix.EINPROGRESS, _, _) -> (
          let remaining = deadline -. Unix.gettimeofday () in
          if Float.(remaining <= 0.) then
            raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", socket));
          let _, writable, _ = Unix.select [] [ fd ] [] remaining in
          if List.is_empty writable then raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", socket));
          match Unix.getsockopt_error fd with
          | None -> ()
          | Some e -> raise (Unix.Unix_error (e, "connect", socket)))
    in
    dial ();
    Unix.clear_nonblock fd;
    fd
  with e ->
    Unix.close fd;
    raise e

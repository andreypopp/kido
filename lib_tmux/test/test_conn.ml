open Tmux

let feed stream =
  let _, events =
    List.fold_left
      (fun (parser, acc) line ->
        let parser, e = Conn.step parser line in
        (parser, Option.to_list e @ acc))
      (Conn.Outside, [])
      (String.split_on_char '\n' stream)
  in
  List.iter
    (function
      | Conn.Block (Ok lines) -> Printf.printf "block [%s]\n" (String.concat " | " lines)
      | Block (Error e) -> Printf.printf "error %s\n" e
      | Notification n ->
          Printf.printf "notification %s refresh=%b\n" n
            (List.mem ~eq:String.equal n Conn.notifications))
    (List.rev events)

let%expect_test "a control-mode session: blocks, data lines starting with %, notifications, errors"
    =
  feed
    "%begin 100 1 0\n\
     %end 100 1 0\n\
     %session-changed $1 work\n\
     %begin 100 2 1\n\
     %0\tzsh\n\
     %1\tclaude\n\
     %end 100 2 0\n\
     %window-add @7\n\
     %output %3 junk\n\
     %begin 100 3 1\n\
     parse error: unknown command: bogus\n\
     %error 100 3 1\n\
     %exit";
  [%expect
    {|
    block []
    notification %session-changed refresh=true
    block [%0	zsh | %1	claude]
    notification %window-add refresh=true
    notification %output refresh=false
    error parse error: unknown command: bogus
    notification %exit refresh=false
    |}]

let%expect_test "a truncated block is never handed out; a guard lookalike is data" =
  feed "%begin 1 1 0\nrow";
  print_endline "--";
  feed "%begin 5 9 0\n%end 5 8 0\nrow\n%end 5 9 1";
  [%expect {|
    --
    block [%end 5 8 0 | row]
    |}]

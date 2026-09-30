open Kido

let%expect_test "one_line blanks control bytes and cuts on a rune boundary" =
  List.iter
    (fun (s, max) -> Printf.printf "[%s]\n" (Reporting.one_line s ~max))
    [
      ("line one\nline two\tend", 256);
      ("trailing   ", 256);
      ("héllo", 2);
      ("héllo", 3);
      ("bad \xff byte", 256);
      ("\x1b[31mred", 256);
    ];
  [%expect
    {|
    [line one line two end]
    [trailing]
    [h]
    [hé]
    [bad   byte]
    [ [31mred]
    |}]

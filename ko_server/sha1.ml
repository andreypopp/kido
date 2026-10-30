let digest s =
  let mask = 0xffffffff in
  let rotl x n = (x lsl n) lor (x lsr (32 - n)) land mask in
  let len = String.length s in
  let padded = (((len + 8) / 64) + 1) * 64 in
  let m = Bytes.make padded '\000' in
  Bytes.blit_string s 0 m 0 len;
  Bytes.set m len '\x80';
  Bytes.set_int64_be m (padded - 8) (Int64.of_int (len * 8));
  let h = [| 0x67452301; 0xEFCDAB89; 0x98BADCFE; 0x10325476; 0xC3D2E1F0 |] in
  let w = Array.make 80 0 in
  for chunk = 0 to (padded / 64) - 1 do
    for i = 0 to 15 do
      w.(i) <- Int32.to_int (Bytes.get_int32_be m ((chunk * 64) + (i * 4))) land mask
    done;
    for i = 16 to 79 do
      w.(i) <- rotl (w.(i - 3) lxor w.(i - 8) lxor w.(i - 14) lxor w.(i - 16)) 1
    done;
    let a = ref h.(0) and b = ref h.(1) and c = ref h.(2) and d = ref h.(3) and e = ref h.(4) in
    for i = 0 to 79 do
      let f, k =
        if i < 20 then (!b land !c lor (lnot !b land mask land !d), 0x5A827999)
        else if i < 40 then (!b lxor !c lxor !d, 0x6ED9EBA1)
        else if i < 60 then (!b land !c lor (!b land !d) lor (!c land !d), 0x8F1BBCDC)
        else (!b lxor !c lxor !d, 0xCA62C1D6)
      in
      let t = (rotl !a 5 + f + !e + k + w.(i)) land mask in
      e := !d;
      d := !c;
      c := rotl !b 30;
      b := !a;
      a := t
    done;
    h.(0) <- (h.(0) + !a) land mask;
    h.(1) <- (h.(1) + !b) land mask;
    h.(2) <- (h.(2) + !c) land mask;
    h.(3) <- (h.(3) + !d) land mask;
    h.(4) <- (h.(4) + !e) land mask
  done;
  let out = Bytes.create 20 in
  Array.iteri (fun i v -> Bytes.set_int32_be out (i * 4) (Int32.of_int v)) h;
  Bytes.to_string out

let%test_module "Tests" =
  (module struct
    let hex s =
      String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (String.to_list s))

    let%expect_test "FIPS 180 vectors" =
      List.iter
        (fun s -> print_endline (hex (digest s)))
        [
          "";
          "abc";
          "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
          String.make 1000 'a';
        ];
      [%expect
        {|
        da39a3ee5e6b4b0d3255bfef95601890afd80709
        a9993e364706816aba3e25717850c26c9cd0d89d
        84983e441c3bd26ebaae4aa1f95129e5e54670f1
        291e9a6c66994949b57ba5e650361e98fc36b1ba
        |}]
  end)

open Ko_server

let fail fmt = Printf.ksprintf failwith fmt

let exchange (server : Fuzz_server.server) data =
  let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.set_nonblock b;
  ignore (Connection.accept a ~on_dispose:ignore (Http.request server.state) : Connection.t);
  let wake = Event_loop.timer ignore in
  Event_loop.start_timer wake ~after:20 ~repeat:(Some 20);
  let deadline = Unix.gettimeofday () +. 5. in
  let sent = ref 0 and shut = ref false and eof = ref false in
  let out = Buffer.create 256 and chunk = Bytes.create 65536 in
  while not !eof do
    if Float.(Unix.gettimeofday () > deadline) then
      fail "no close within 5s after %S" (String.escaped data);
    let progress = ref false in
    (if not !shut then
       match Unix.single_write_substring b data !sent (String.length data - !sent) with
       | n ->
           progress := n > 0;
           sent := !sent + n;
           if !sent = String.length data then (
             Unix.shutdown b Unix.SHUTDOWN_SEND;
             shut := true)
       | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
       | exception Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) -> shut := true);
    (match Unix.read b chunk 0 (Bytes.length chunk) with
    | 0 -> eof := true
    | n ->
        progress := true;
        Buffer.add_subbytes out chunk 0 n
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception Unix.Unix_error (Unix.ECONNRESET, _, _) -> eof := true);
    Event_loop.step (if !progress || !eof then Peek else Wait)
  done;
  Event_loop.stop_timer wake;
  Unix.close b;
  Event_loop.step Peek;
  Buffer.contents out

let ko_headers =
  Printf.sprintf "Ko-Protocol: %s\r\nKo-Vt: %s\r\n" Protocol.version.protocol Protocol.version.vt

let status server request body =
  let reply =
    exchange server (Printf.sprintf "%s HTTP/1.1\r\nHost: ko\r\n%s%s" request ko_headers body)
  in
  String.sub reply 0 (min 12 (String.length reply))

let healthy server =
  let reply = status server "GET /version" "\r\n" in
  if not (String.equal reply "HTTP/1.1 200") then fail "version probe got %S" reply

let check_reply request reply =
  if String.starts_with ~prefix:"HTTP/1.1 5" reply then
    fail "server error for %S: %S" (String.escaped request) (String.escaped reply)

open QCheck2.Gen

let word =
  oneof_list
    [
      "";
      "a";
      "all";
      "none";
      "0";
      "-1";
      "99999999999999999999";
      "4294967296";
      "%00";
      "%";
      "=";
      "&";
      "?";
      "/";
      " ";
    ]

let junk = string_size ~gen:(oneof [ printable; char ]) (0 -- 12)

let key =
  oneof_list
    [
      "kind";
      "name";
      "pane";
      "focused";
      "size";
      "cols";
      "rows";
      "cell_px";
      "width";
      "height";
      "ignore_size";
      "cwd";
      "command";
      "env";
      "value";
      "action";
      "key";
      "mods";
      "unshifted_codepoint";
      "text";
      "composing";
      "button";
      "col";
      "row";
      "history";
      "images";
      "check_safe";
      "id";
    ]

let scalar =
  oneof_weighted
    [
      ( 3,
        map
          (fun n -> `Int n)
          (oneof [ 0 -- 3; 0 -- 70000; return (-1); return max_int; return min_int ]) );
      (2, map (fun b -> `Bool b) bool);
      ( 3,
        map
          (fun s -> `String s)
          (oneof_list
             [
               "terminal";
               "app";
               "press";
               "left";
               "all";
               "none";
               "%1";
               "%99";
               "/tmp";
               "/nonexistent";
               "/bin/sh";
               "/bin/true";
               "aGk=";
               "!!";
               "argv";
               "shell";
               "";
             ]) );
      (1, return `Null);
      (1, map (fun f -> `Float f) (oneof_list [ 0.5; 1e300; -0. ]));
    ]

let json =
  sized_size (0 -- 3)
  @@ fix (fun self n ->
      if n = 0 then scalar
      else
        oneof_weighted
          [
            (2, scalar);
            (3, map (fun l -> `List l) (list_size (0 -- 3) (self (n - 1))));
            (4, map (fun l -> `Assoc l) (list_size (0 -- 5) (pair key (self (n - 1)))));
          ])

let size_json cols rows =
  `Assoc
    [
      ("cols", `Int cols);
      ("rows", `Int rows);
      ("cell_px", `Assoc [ ("width", `Int 8); ("height", `Int 16) ]);
    ]

let message =
  let tagged tag payload = `List [ `String tag; payload ] in
  oneof_weighted
    [
      ( 4,
        oneof_list
          [
            tagged "hello"
              (`Assoc
                 [
                   ("kind", `String "terminal");
                   ("name", `String "t");
                   ("focused", `Bool true);
                   ("size", size_json 80 24);
                 ]);
            tagged "select" (`String "%1");
            tagged "size" (size_json 100 30);
            tagged "focused" (`Bool false);
            tagged "resync" (`Assoc [ ("history", `String "all"); ("images", `String "none") ]);
            tagged "input" (`List [ `String "text"; `String "aGk=" ]);
            tagged "input" (`List [ `String "focus"; `Bool true ]);
            tagged "input"
              (`List
                 [
                   `String "key";
                   `Assoc
                     [
                       ("action", `String "press");
                       ("key", `Int 20);
                       ("mods", `Int 2);
                       ("unshifted_codepoint", `Int 97);
                       ("text", `String "a");
                       ("composing", `Bool false);
                     ];
                 ]);
            tagged "input"
              (`List
                 [
                   `String "mouse";
                   `Assoc
                     [
                       ("action", `String "press");
                       ("button", `String "left");
                       ("col", `Int 1);
                       ("row", `Int 1);
                       ("mods", `Int 0);
                     ];
                 ]);
            tagged "input"
              (`List
                 [
                   `String "paste";
                   `Assoc [ ("text", `String "x"); ("check_safe", `Bool true); ("id", `Int 1) ];
                 ]);
          ] );
      (3, map2 tagged (oneof_list [ "hello"; "select"; "size"; "focused"; "resync"; "input" ]) json);
      (1, json);
    ]

let text_of value =
  let text = Yojson.Basic.to_string (value :> Yojson.Basic.t) in
  oneof_weighted
    [
      (6, return text);
      (1, map (fun n -> String.sub text 0 (n mod (String.length text + 1))) nat);
      ( 1,
        map2
          (fun n c -> String.mapi (fun i x -> if i = n mod String.length text then c else x) text)
          nat char );
    ]

let json_text = json >>= text_of
let message_text = message >>= text_of

let id =
  oneof_list [ "%1"; "%1"; "%2"; "%99"; "%0"; "%"; "1"; "%-1"; "%abc"; "%99999999999999999999" ]

let query =
  oneof_weighted
    [
      (3, return "");
      ( 5,
        map
          (fun pairs -> "?" ^ String.concat "&" (List.map (fun (k, v) -> k ^ "=" ^ v) pairs))
          (list_size (0 -- 3)
             (pair
                (oneof_list [ "history"; "images"; "offset"; "format"; "x"; "" ])
                (oneof [ word; junk ]))) );
    ]

let target =
  oneof_weighted
    [
      (2, oneof_list [ "/version"; "/panes"; "/client" ]);
      (3, map2 (fun i q -> "/panes/" ^ i ^ "/view" ^ q) id query);
      (3, map2 (fun i q -> "/panes/" ^ i ^ "/screen" ^ q) id query);
      (3, map (fun i -> "/panes/" ^ i ^ "/input") id);
      (2, map (fun i -> "/panes/" ^ i) (oneof_list [ "%2"; "%99"; "%0"; "%"; "1"; "%abc" ]));
      (1, map (fun s -> "/" ^ s) junk);
    ]

let meth =
  oneof_weighted
    [ (5, oneof_list [ "GET"; "POST" ]); (2, oneof_list [ "DELETE"; "PUT"; "HEAD" ]); (1, junk) ]

let headers =
  let vt = Protocol.version.vt in
  let optional h = oneof_weighted [ (1, map (fun v -> [ h v ]) junk); (9, return []) ] in
  map2 ( @ )
    (oneof_weighted
       [
         (30, return [ "Ko-Protocol: " ^ Protocol.version.protocol; "Ko-Vt: " ^ vt ]);
         (1, return [ "Ko-Protocol: 2.0"; "Ko-Vt: " ^ vt ]);
         (1, return [ "Ko-Protocol: " ^ Protocol.version.protocol ]);
         (1, map (fun v -> [ "Ko-Protocol: " ^ Protocol.version.protocol; "Ko-Vt: " ^ v ]) junk);
         (1, return []);
       ])
    (map2 ( @ )
       (oneof_weighted
          [
            (12, return []);
            (1, return [ "Ko-Client: c1" ]);
            (1, return [ "Ko-Client: c99" ]);
            (1, map (fun v -> [ "Ko-Client: " ^ v ]) junk);
          ])
       (map2 ( @ ) (optional (fun v -> "Origin: " ^ v)) (optional (fun v -> "X-" ^ v ^ ": " ^ v))))

let ws_frame =
  let* opcode =
    oneof_weighted
      [
        (8, return 1);
        (2, return 0);
        (1, return 2);
        (1, return 8);
        (2, return 9);
        (1, return 10);
        (1, oneof_list [ 3; 4; 11; 15 ]);
      ]
  in
  let* fin = oneof_weighted [ (5, return true); (1, return false) ] in
  let* payload =
    oneof_weighted [ (6, message_text); (1, junk); (1, string_size ~gen:char (130 -- 70000)) ]
  in
  let* key = string_size ~gen:char (return 4) in
  let* lie = oneof_weighted [ (12, return 0); (1, 1 -- 200); (1, return (-1)) ] in
  let declared = if lie = 0 then None else Some (max 0 (String.length payload + lie)) in
  return (Ws.encode ~fin ?declared ~mask:key ~opcode payload)

let upgrade_headers =
  "Upgrade: websocket\r\n\
   Connection: Upgrade\r\n\
   Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
   Sec-WebSocket-Version: 13\r\n"

let request m t hs ~framing body =
  Printf.sprintf "%s %s HTTP/1.1\r\nHost: ko\r\n%s\r\n%s\r\n%s" m t (String.concat "\r\n" hs)
    framing body

let http_request =
  let plain =
    let* m = meth
    and* t = target
    and* hs = headers
    and* body = oneof_weighted [ (2, return ""); (6, json_text) ] in
    let* chunked = oneof_weighted [ (9, return false); (1, return true) ] in
    let+ frames = list_size (0 -- 6) ws_frame and+ upgrade = bool in
    if chunked then request m t hs ~framing:"Transfer-Encoding: chunked\r\n" body
    else if upgrade && String.equal m "GET" then
      request m t hs ~framing:upgrade_headers (String.concat "" frames)
    else request m t hs ~framing:(Printf.sprintf "Content-Length: %d\r\n" (String.length body)) body
  in
  let websocket =
    let* t =
      oneof_weighted
        [
          (1, return "/client");
          (2, map (fun q -> "/panes/%1/view" ^ q) query);
          ( 2,
            oneof_list
              [
                "/panes/%1/view?history=all";
                "/panes/%1/view?history=none&offset=0";
                "/panes/%1/view?history=all&offset=99999999999";
              ] );
        ]
    in
    let+ frames = list_size (1 -- 8) ws_frame in
    request "GET" t
      [ "Ko-Protocol: " ^ Protocol.version.protocol; "Ko-Vt: " ^ Protocol.version.vt ]
      ~framing:upgrade_headers (String.concat "" frames)
  in
  oneof_weighted [ (3, plain); (2, websocket) ]

let%test_module "Tests" =
  (module struct
    let seed, seconds = Fuzz_check.budget ()

    let tolerated f =
      match f () with
      | _ -> true
      | exception (Invalid_argument _ | Yojson.Json_error _ | Jsonkit.Of_json_error _) -> true

    let%test "request decoders raise only the errors their callers catch" =
      Fuzz_check.check ?seed ?seconds ~count:300 ~name:"decoders" ~print:Fun.id json_text
        (fun text ->
          match Yojson.Basic.from_string text with
          | exception Yojson.Json_error _ -> true
          | value ->
              List.for_all
                (fun decode -> tolerated (fun () -> decode value))
                [
                  (fun v -> ignore (Protocol.Request.input_of_json v));
                  (fun v -> ignore (Protocol.Request.client_of_json v));
                  (fun v -> ignore (Protocol.Request.view_of_json v));
                  (fun v -> ignore (Protocol.Request.create_pane_of_json v));
                ]);
      true

    let%test "routes raise only Invalid_argument" =
      let path =
        oneof_weighted
          [
            (3, map3 (fun m t q -> (m, t ^ q)) meth target query);
            (1, map2 (fun m t -> (m, t)) meth junk);
          ]
      in
      Fuzz_check.check ?seed ?seconds ~count:300 ~name:"routes"
        ~print:(fun (m, t) -> m ^ " " ^ t)
        path
        (fun (meth, target) ->
          match Protocol.Route.of_request ~meth target with
          | _ -> true
          | exception Invalid_argument _ -> true);
      true

    let%test "bad bodies are answered with 400 or 411, not a crash or a 500" =
      Fuzz_server.with_server
        ~command:(fun _ -> "exec cat")
        ~activity:(fun () -> false)
        (fun server ->
          let chunked = status server "POST /panes" "Transfer-Encoding: chunked\r\n\r\n{}" in
          let cwd =
            status server "POST /panes" "Content-Length: 23\r\n\r\n{\"cwd\":\"/nonexistent\"}   "
          in
          String.equal chunked "HTTP/1.1 411" && String.equal cwd "HTTP/1.1 400")

    let%test "the server answers any request with a status or a close, and stays healthy" =
      Fuzz_check.check ?seed ?seconds ~count:40 ~name:"http"
        ~print:(fun requests -> String.concat "\n" (List.map String.escaped requests))
        QCheck2.Gen.(list_size (1 -- 6) http_request)
        (fun requests ->
          Fuzz_server.with_server
            ~command:(fun _ -> "stty raw -echo; exec cat")
            ~activity:(fun () -> false)
            (fun server ->
              List.iter (fun request -> check_reply request (exchange server request)) requests;
              healthy server;
              true));
      true
  end)

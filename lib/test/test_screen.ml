open Kido

let screens =
  [
    ( "idle",
      {|
✻ Sautéed for 3s · done 11:52 AM

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
|}
    );
    ( "idle with text typed",
      {|
────────────────────────────────────────
❯ touch /tmp/probe-file
────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts · ← for agents
|}
    );
    ( "idle with a wrapped footer",
      {|
──────────────────────────────────
❯
──────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to
  cycle) · ← for agents
|}
    );
    ( "busy",
      {|
✳ Ideating… (5s · ↓ 156 tokens)
  ⎿  Tip: Did you know you can drag and drop image files into your terminal?

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents
|}
    );
    ( "question dialog",
      {|
 ☐ Beverage

Do you prefer tea or coffee?

❯ 1. Tea
     You prefer tea
  2. Coffee
     You prefer coffee
  3. Type something.
────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
|}
    );
    ( "permission dialog",
      {|
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
|}
    );
    ( "trust prompt",
      {|
 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
|} );
    ("empty", "");
  ]

let%expect_test "at_input_prompt on real Claude Code screens, padded to the pane's height" =
  List.iter
    (fun (name, screen) ->
      let lines = String.split_on_char '\n' (String.trim screen) @ [ ""; ""; "" ] in
      Printf.printf "%s: %b\n" name (Screen.at_input_prompt lines))
    screens;
  [%expect
    {|
    idle: true
    idle with text typed: true
    idle with a wrapped footer: true
    busy: false
    question dialog: false
    permission dialog: false
    trust prompt: false
    empty: false
    |}]

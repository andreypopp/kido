let value = "1.1"
let matches server = Option.equal String.equal server (Some value)

let hello server =
  `Assoc
    [
      ( "hello",
        `Assoc
          ([ ("protocol", `String value) ]
          @
          if matches server then []
          else [ ("server", Option.map_or ~default:`Null (fun s -> `String s) server) ]) );
    ]

let reply id result =
  `Assoc
    [
      ( "reply",
        `Assoc
          (("id", `Int id)
          :: [
               (match result with
               | Error e -> ("error", `String e)
               | Ok target ->
                   ( "switched",
                     Option.map_or ~default:`Null
                       (fun (session, window) ->
                         `Assoc [ ("session", `String session); ("window", `String window) ])
                       target ));
             ]) );
    ]

val check :
  ?seed:int ->
  ?seconds:float ->
  count:int ->
  name:string ->
  print:'a QCheck2.Print.t ->
  'a QCheck2.Gen.t ->
  ('a -> bool) ->
  unit

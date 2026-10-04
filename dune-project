(lang dune 3.17)

(name kido)

(source
 (github andreypopp/kido))

(pin
 (url
  "git+https://github.com/invariant-hq/mosaic#0ef02a5690365f8f7518c54755287f905814529f")
 (package
  (name mosaic)))

(pin
 (url
  "git+https://github.com/invariant-hq/mosaic#0ef02a5690365f8f7518c54755287f905814529f")
 (package
  (name matrix)))

(pin
 (url
  "git+https://github.com/invariant-hq/mosaic#0ef02a5690365f8f7518c54755287f905814529f")
 (package
  (name toffee)))

(pin
 (url
  "git+https://github.com/invariant-hq/mosaic#0ef02a5690365f8f7518c54755287f905814529f")
 (package
  (name tree-sitter)))

(package
 (name kido)
 (synopsis "A workflow on top of tmux to manage coding agents")
 (depends
  (ocaml
   (>= 5.5))
  (containers
   (>= 3.18))
  (cmdliner
   (>= 2.1))
  (yojson
   (>= 3.0))
  (ppx_deriving_yojson
   (>= 3.10))
  (mtime
   (>= 2.2))
  mosaic
  dune-build-info
  (ppx_expect :with-test)
  (ocamlformat :with-dev-setup)))

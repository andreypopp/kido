(lang dune 3.17)

(name kido)

(generate_opam_files true)

(source
 (github andreypopp/kido))

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
  (ppx_expect :with-test)
  (ocamlformat :with-dev-setup)))

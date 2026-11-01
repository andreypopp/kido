case ${COORDINATOR:-ocaml} in
  ocaml) coordinator=./bench/coordinator.exe ;;
  rust)
    coordinator=$root/target/release/ko-bench
    [ -x "$coordinator" ] || { echo "$coordinator is missing; run make build-ko" >&2; exit 1; }
    export KO_BENCH_PRODUCE=$root/_build/default/bench/produce.exe
    export KO_PANE_EXE=$root/target/release/ko-pane ;;
  *) echo "COORDINATOR is ocaml or rust" >&2; exit 1 ;;
esac

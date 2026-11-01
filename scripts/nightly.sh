# nightly-2026-10-14 has miri for aarch64-apple-darwin.
NIGHTLY=nightly-2026-10-14

skip_without_nightly() {
  local name=$1
  shift
  if ! make --no-print-directory -s nightly-has >/dev/null 2>&1; then
    echo "SKIP $name: toolchain $NIGHTLY is not installed (rustup toolchain install $NIGHTLY --profile minimal -c miri -c rust-src)" >&2
    exit 0
  fi
  if ! make --no-print-directory -s nightly-cargo ARGS="$*" >/dev/null 2>&1; then
    echo "SKIP $name: \`cargo $*\` does not run on $NIGHTLY (cargo install --locked cargo-fuzz, or rustup component add miri rust-src --toolchain $NIGHTLY)" >&2
    exit 0
  fi
}

boxed() {
  local name=$1
  shift
  perl -e '
    my $name = shift;
    my $limit = shift;
    my $pid = fork();
    die "fork failed" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 }
    my $stop = sub {
      my ($why, $code) = @_;
      kill "TERM", -$pid; select(undef, undef, undef, 2); kill "KILL", -$pid;
      waitpid($pid, 0);
      print STDERR "$name: $why\n";
      exit $code;
    };
    $SIG{ALRM} = sub { $stop->("killed after ${limit}s", 124) };
    $SIG{$_} = sub { $stop->("interrupted", 143) } for qw(TERM INT HUP);
    alarm $limit;
    waitpid($pid, 0);
    my $status = $?;
    kill "KILL", -$pid;
    exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
  ' "$name" "$@"
}

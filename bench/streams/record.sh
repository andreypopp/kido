#!/bin/sh
# Regenerates the recorded streams. script(1) adds "^D\b\b" at the start on macOS.
set -eu
cd "$(dirname "$0")"
root=../..
record() {
  name=$1
  shift
  script -q "$name.raw" "$@" >/dev/null
  tail -c +5 "$name.raw" | head -c 65536 >"$name.vt"
  rm -f "$name.raw"
}
record text cat "$root/AGENTS.md"
record ls ls -lG /usr/bin
record gitlog git -C "$root" --no-pager log --color=always --stat -n 200
record yes sh -c 'yes | head -c 65536'
awk 'BEGIN {
  printf "\033[?1049h\033[?25l"
  for (frame = 0; frame < 24; frame++) {
    printf "\033]2;top - frame %d\007\033[H", frame
    for (row = 1; row <= 24; row++) {
      printf "\033[%d;1H", row
      for (col = 0; col < 8; col++)
        printf "\033[38;5;%dm\033[48;2;%d;%d;%dm %8d ", (frame + row + col) % 256, row * 10 % 256, col * 30 % 256, frame * 10 % 256, frame * row * col
      printf "\033[0m"
    }
  }
  printf "\033[?25h\033[?1049l"
}' >tui.vt
awk 'BEGIN {
  for (i = 0; i < 600; i++)
    printf "\033]8;id=%d;https://example.org/src/file%d.c\033\\src/file%d.c\033]8;;\033\\:%d: \033]8;;https://example.org/doc/%d\033\\see docs\033]8;;\033\\ \033]8;;file:///tmp/%d\033\\/tmp/%d\033]8;;\033\\\r\n", i, i, i, i, i, i, i
}' >osc8.vt
awk 'BEGIN {
  for (i = 0; i < 800; i++)
    printf "\033]133;A\007\033]7;file://localhost/tmp/%d\007$ \033]133;B\007make step%d\r\n\033]133;C\007\033]7501;state=working:app=make\033\\building step %d\r\n\033]133;D;%d\007", i, i, i, i % 3
}' >shell.vt

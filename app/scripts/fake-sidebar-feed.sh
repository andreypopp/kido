#!/bin/sh
# A stand-in for `kido sidebar-feed`, pointed to by KIDO_APP_FEED: prints a
# v1-shaped snapshot every 0.5s, appends each stdin line to /tmp/fake-feed.log,
# and exits on stdin EOF, like the real subcommand.
# bash redirects a backgrounded job's own stdin to /dev/null unless it reads
# from a fd saved before backgrounding it, hence `exec 3<&0` and `<&3` below.
exec 3<&0
(while IFS= read -r line <&3; do echo "$line" >>/tmp/fake-feed.log; done; kill "$$") &
n=0
trap 'exit 0' TERM
while :; do
  n=$((n + 1))
  printf '{"v":1,"client":{"session":"$1","window":"@1","pane":"%%1"},"filter":"","error":null,"sessions":[{"id":"$1","name":"main","current":true,"rows":[{"pane":"%%1","window":"@1","tree":"","indicator":{"kind":"running"},"title":[{"text":"fake %s","role":"current"}],"tail":[],"attention":false}]}]}\n' "$n"
  sleep 0.5
done

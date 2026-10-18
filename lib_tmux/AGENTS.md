lib_tmux is only a typed API for tmux: commands, formats, ids, the
control client and OSC 7501 parsing. It contains no kido concepts:
no runs, agents, server directory, sidebar or pane classification.
Kido's view of the server (`State`) stays in `lib/`.

Do not add a module to this library unless it is absolutely necessary.
If it is necessary, discuss it with the user first.

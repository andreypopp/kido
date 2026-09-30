val at_input_prompt : string list -> bool
(** Whether a captured Claude Code screen shows its input box with nothing running: no dialog is
    open and no work is in flight. Claude Code reports a dismissed question or a denied permission
    through no hook of its own (checked on v2.1.267), so the screen is the only timely evidence. It
    only ever downgrades a waiting pane to idle, so a screen kido cannot read answers [false]. *)

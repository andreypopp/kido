use std::time::Duration;

use ko_sys::clock::process_cpu;
use ko_sys::pid::Pid;

use crate::harness::{start_with, which};
use crate::status::{Flavour, dotfiles, shell_of};

// Idle panes must not make the coordinator or their ko-pane wake: the CPU time of each grows less
// than 5 ms over 2 s. Three panes are a program blocked in read, one view each; three are primed
// zsh shells at their prompt (the model arms no timer, and ko-pane checks the foreground only on
// events); one is an unintegrated program that exec'd after its last output, whose foreground
// stays what the last event saw. ps has a 10 ms resolution, so the figure comes from
// proc_pid_rusage (macOS) or /proc/<pid>/schedstat (Linux).
#[test]
fn no_idle_wakeups() {
    let zsh = shell_of(&Flavour::Zsh).or_else(|| which("zsh"));
    let s = start_with(zsh.as_deref().unwrap_or("/bin/sh".as_ref()), &[], &[]);
    dotfiles(&Flavour::Zsh, &s.dir, "");
    let mut views = Vec::new();
    let mut panes = Vec::new();
    for _ in 0..3 {
        let p = s.pane("printf READY; while read x; do :; done");
        let mut view = s.ws(&format!("/panes/{p}/view"));
        view.ready("READY");
        views.push(view);
        panes.push(p);
    }
    let exec = s.pane("printf FIRST; sleep 0.3; exec sleep 30");
    s.screen_has(&exec, "FIRST");
    panes.push(exec.clone());
    if zsh.is_some() {
        for _ in 0..3 {
            let p = s.shell_pane();
            s.wait_row(&p, "the first prompt", |row| {
                row["status"]["kind"]["pane"]["phase"]["type"] == "idle"
            });
            panes.push(p);
        }
    }
    let watched: Vec<Pid> = std::iter::once(s.child.pid())
        .chain(
            panes
                .iter()
                .map(|pane| s.row(pane)["pid"].as_i64().unwrap())
                .filter_map(Pid::new)
                .filter_map(Pid::parent),
        )
        .collect();
    let before: Vec<Duration> = watched
        .iter()
        .map(|pid| process_cpu(*pid).unwrap())
        .collect();
    std::thread::sleep(Duration::from_secs(2));
    for (pid, before) in watched.iter().zip(before) {
        let grown = process_cpu(*pid).unwrap() - before;
        println!("{pid} CPU grew {grown:?} over 2 s");
        assert!(
            grown < Duration::from_millis(5),
            "{pid} CPU grew {grown:?} over 2 s with idle panes"
        );
    }
    assert_ne!(
        s.row(&exec)["foreground"]["name"],
        "sleep",
        "the exec after the last output is not seen without an event"
    );
}

use std::time::Duration;

use ko_sys::clock::process_cpu;

use crate::harness::start;

// Three idle panes (a program blocked in read, one view each) must not make
// the coordinator wake: its CPU time grows less than 5 ms over 5 s. ps has a
// 10 ms resolution, so the figure comes from proc_pid_rusage.
#[test]
fn no_idle_wakeups() {
    let s = start(&[]);
    let pid = s.child.pid();
    let mut views = Vec::new();
    for _ in 0..3 {
        let p = s.pane("printf READY; while read x; do :; done");
        let mut view = s.ws(&format!("/panes/{p}/view"));
        view.ready("READY");
        views.push(view);
    }
    let before = process_cpu(pid).unwrap();
    std::thread::sleep(Duration::from_secs(5));
    let after = process_cpu(pid).unwrap();
    let grown = after.time - before.time;
    println!(
        "coordinator CPU grew {grown:?} and wakeups grew by {} over 5 s",
        after.wakeups - before.wakeups
    );
    assert!(
        grown < Duration::from_millis(5),
        "coordinator CPU grew {grown:?} over 5 s with idle panes"
    );
}

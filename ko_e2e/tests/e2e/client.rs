use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use ko_sys::pid::{Pid, signal_descendant};
use ko_sys::signal::Signal;

use crate::harness::{Dir, Server, quote, run_ko, start, text_of};
use crate::outer::{Keys, Outer};

const PANE_X: usize = 25;

fn pane_text(line: &str) -> String {
    line.chars().skip(PANE_X).collect()
}

fn count_sequences(data: &[u8], opener: &[u8], digits: &[u8]) -> usize {
    let mut count = 0;
    let mut at = 0;
    while at < data.len() {
        if data[at..].starts_with(opener) {
            let mut end = at + opener.len();
            while end < data.len() && digits.contains(&data[end]) {
                end += 1;
            }
            if data.get(end) == Some(&b'u') {
                count += 1;
            }
            at += opener.len();
        } else {
            at += 1;
        }
    }
    count
}

fn pager_fixture(dir: &Path) -> (PathBuf, PathBuf) {
    let path = dir.join("pager");
    let record = dir.join("pager-path");
    let script = format!(
        "#!/bin/sh\nprintf '%s' \"$1\" > {}\nprintf '\\nPAGER-OPEN\\n'\nread answer\n",
        quote(text_of(&record))
    );
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    (path, record)
}

fn hex(text: &str) -> String {
    text.bytes().map(|byte| format!("{byte:02x}")).collect()
}

fn click(col: usize) -> String {
    hex(&format!("\x1b[<0;{col};5M"))
}

fn read_file(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

fn interactive_fixture(s: &Server) -> String {
    let program = "import os,tty\ntty.setraw(0)\nos.write(1,b'\\x1b]0;fixture\\x07BASE')\nwhile True:\n c=os.read(0,1)\n if c==b'o': os.write(1,b'\\r\\nOUTPUT-WITHOUT-INPUT\\r\\n')\n if c==b'f':\n  w,h=os.get_terminal_size()\n  for y in range(h): os.write(1,('\\x1b[%d;1H'%(y+1)+'P'*w).encode())\n if c==b'h': os.write(1,b'\\x1b[?2026h\\x1b[1;1HHOLD-CHANGED')\n if c==b'r': os.write(1,b'\\x1b[?2026l')";
    s.pane(&format!("exec python3 -u -c {}", quote(program)))
}

#[test]
fn client_lifecycle() {
    let s = start(&[]);
    let p1 = s.pane("printf '\x1b]0;one\x07pane-one\\n'; exec /bin/sh");
    s.pane("printf '\x1b]0;two\x07pane-two\\n'; exec /bin/sh");
    s.pane("printf '\x1b]0;three\x07pane-three\\n'; exec /bin/sh");
    let o = Outer::new(&s.dir, Keys::Extended);
    let (pager, record) = pager_fixture(&o.dir);
    o.attach(text_of(&pager));
    o.contains("pane-one");
    o.wait("outer mouse reporting on", || o.mouse_reporting());
    o.contains("1 one");
    o.chord(115);
    o.wait("sidebar hidden", || !o.screen().contains("1 one"));
    o.chord(115);
    o.contains("1 one");
    o.raw("\x1b[1;1:1B\x1b[1;1:3B\r");
    o.contains("pane-two");
    o.raw("\x1b[1;6A");
    o.contains("pane-one");
    o.raw("\x1b[1;6B");
    o.contains("pane-two");
    o.raw("\x1b[1;6A");
    o.contains("pane-one");
    o.raw("\x1b[<0;3;2M\x1b[<0;3;2m");
    o.contains("pane-two");
    o.chord(101);
    o.contains("PAGER-OPEN");
    let file = PathBuf::from(std::fs::read_to_string(&record).unwrap());
    let mode =
        std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&file).unwrap().permissions());
    assert_eq!(mode & 0o777, 0o600, "pager file mode");
    o.raw("done");
    o.enter();
    o.contains("pane-two");
    o.wait_ticking("pager temporary file removed after exit", || !file.exists());
    o.chord(110);
    o.wait_ticking("new pane", || s.pane_pids().len() == 4);
    o.raw("\x1b[100;5u");
    o.contains("†");
    o.raw("\x1b[100;5u");
    o.wait_ticking("remove dead pane", || s.pane_pids().len() == 3);
    o.detach();
    s.text(&p1, "printf 'AFTER-DETACH\\n'\n");
    o.attach("");
    o.contains("AFTER-DETACH");
    o.chord(101);
    o.contains("(END)");
    o.raw("q");
    o.wait("outer mouse reporting on", || o.mouse_reporting());
    o.detach();
}

#[derive(Debug)]
struct Resume<'a> {
    outer: &'a Outer,
    client: Pid,
    client_stopped: bool,
    shell_stopped: bool,
}

impl Drop for Resume<'_> {
    fn drop(&mut self) {
        if self.client_stopped {
            let _ = signal_descendant(self.outer.shell_pid(), self.client, Signal::Cont);
        }
        if self.shell_stopped {
            self.outer.resume_shell();
        }
    }
}

#[test]
fn client_history_and_alternate_screen() {
    let s = start(&[]);
    let history_pane = s.pane("seq 300; printf '\x1b]0;history\x07HISTORY-READY\\n'; exec cat");
    let o = Outer::new(&s.dir, Keys::Extended);
    let (pager, record) = pager_fixture(&o.dir);
    let pager = text_of(&pager);
    o.attach(pager);
    o.contains("HISTORY-READY");
    o.raw("\x1b[<64;40;5M");
    o.wait("wheel moved viewport", || {
        !o.screen().contains("HISTORY-READY")
    });
    o.raw("x");
    o.contains("HISTORY-READY");
    o.detach();
    o.attach(pager);
    o.contains("HISTORY-READY");
    o.chord(101);
    o.contains("PAGER-OPEN");
    let path = std::fs::read_to_string(&record).unwrap();
    let data = std::fs::read_to_string(path).unwrap();
    let count = data
        .split('\n')
        .filter(|line| {
            line.trim()
                .parse::<u32>()
                .is_ok_and(|n| (1..=300).contains(&n))
        })
        .count();
    assert_eq!(count, 300, "history has {count} numeric lines, want 300");
    o.raw("done");
    o.enter();
    o.contains("HISTORY-READY");
    o.detach();
    s.request("DELETE", &format!("/panes/{history_pane}"), None, 200);
    let command = "seq 300; stty -icanon -echo; printf '\\033[?1049hPID\\n'; dd bs=1 count=1 >/dev/null 2>&1; stty icanon echo; printf '\\033[?1049lAFTER-ALT\\n'; exec /bin/sh";
    let alt_pane = s.pane(command);
    o.attach(pager);
    o.contains("PID");
    o.detach();
    // With job control the shell takes the tty back from the stopped client.
    o.raw("set +m");
    o.enter();
    o.attach(pager);
    o.contains("PID");
    o.raw("q");
    o.contains("AFTER-ALT");
    let _ = std::fs::remove_file(&record);
    o.chord(101);
    o.wait_ticking("pager started", || {
        read_file(&record).is_some_and(|text| !text.is_empty())
    });
    let path = read_file(&record).unwrap_or_default();
    let data = read_file(Path::new(&path)).unwrap_or_default();
    assert!(
        data.contains("299"),
        "alternate screen round trip lost primary history"
    );
    o.raw("done");
    o.enter();
    o.contains("AFTER-ALT");
    let (client, shell) = (o.client_pid(), o.shell_pid());
    let mut resume = Resume {
        outer: &o,
        client,
        client_stopped: false,
        shell_stopped: false,
    };
    o.stop_shell();
    resume.shell_stopped = true;
    signal_descendant(shell, client, Signal::Stop).unwrap();
    resume.client_stopped = true;
    let producer = "for i in range(20000): print('H%05d'%i+'x'*70)";
    s.text(
        &alt_pane,
        &format!(
            "python3 -c {}; printf 'FLOOD-%s\\n' DONE\n",
            quote(producer)
        ),
    );
    o.wait_ticking("output while client is stopped", || {
        s.request_text(
            "GET",
            &format!("/panes/{alt_pane}/screen?format=plain"),
            None,
            200,
        )
        .contains("FLOOD-DONE")
    });
    signal_descendant(shell, client, Signal::Cont).unwrap();
    resume.client_stopped = false;
    o.contains("FLOOD-DONE");
    o.raw("\x1b[<64;40;5M");
    o.contains("H19970");
    o.chord(113);
    o.wait_ticking("client exits before its shell resumes", || {
        client.has_ended()
    });
    o.resume_shell();
    resume.shell_stopped = false;
    o.detached();
}

#[test]
fn client_winch_and_outer_modes() {
    let s = start(&[]);
    let counter = s.dir.join("winch");
    let quoted = format!("{:?}", text_of(&counter));
    let py = format!(
        "import os,signal\nn=0\ndef changed(*args):\n global n\n n+=1\n open({quoted},'w').write(str(n))\nsignal.signal(signal.SIGWINCH,changed)\nopen({quoted},'w').write('0')\nprint('WINCH-READY',flush=True)\nwhile True: signal.pause()"
    );
    s.pane(&format!("exec python3 -c {}", quote(&py)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.wait_ticking("WINCH handler", || counter.exists());
    o.raw("printf '\\033[?1003h\\033[?1006h\\033[?1004h\\033[?2004h\\033[?25l'");
    o.enter();
    o.wait("pre-existing outer modes", || {
        let modes = format!(",{},", o.modes());
        [",1003,", ",1004,", ",1006,", ",2004,"]
            .iter()
            .all(|mode| modes.contains(mode))
            && !modes.contains(",25,")
    });
    let before = o.modes();
    let count = |expected: &str| read_file(&counter).as_deref() == Some(expected);
    o.attach("cat");
    o.contains("WINCH-READY");
    o.wait_ticking("one attach resize", || count("1"));
    o.detach();
    let after = o.modes();
    assert_eq!(before, after, "outer modes changed");
    o.attach("cat");
    o.contains("WINCH-READY");
    o.chord(115);
    o.wait_ticking(
        "one real width change and no same-size attach resize",
        || count("2"),
    );
    o.resize(130, 31);
    o.wait_ticking("one outer terminal resize", || count("3"));
    o.resize(130, 31);
    o.resize(131, 31);
    o.wait_ticking("same-size resize sends no WINCH", || count("4"));
    o.detach();
}

struct KillOnDrop<'a> {
    dir: &'a Path,
    env: &'a [Vec<u8>],
    scratch: &'a Path,
}

impl Drop for KillOnDrop<'_> {
    fn drop(&mut self) {
        run_ko(
            self.scratch,
            self.env,
            &["kill-server", "--server", text_of(self.dir)],
            "",
        );
    }
}

#[test]
fn client_attach_or_start_and_warning() {
    let dir = Dir::new("ko-auto-");
    let stale = UnixListener::bind(dir.join("socket")).unwrap();
    drop(stale);
    let o = Outer::new(&dir, Keys::Unconfirmed);
    let scratch = Dir::new("ko-run-");
    let _kill = KillOnDrop {
        dir: &dir,
        env: &o.env,
        scratch: &scratch,
    };
    let peer = Outer::new(&dir, Keys::Extended);
    o.attach("cat");
    peer.attach("cat");
    o.contains("ko: extended keys were not confirmed");
    peer.wait("the peer attached", || peer.mouse_reporting());
    peer.chord(115);
    peer.wait(
        "extended peer removes the warning after a distinct chord",
        || !peer.screen().contains("extended keys were not confirmed"),
    );
    UnixStream::connect(dir.join("socket")).unwrap();
    o.chord(113);
    o.detached();
    peer.chord(113);
    peer.detached();
    let run = run_ko(
        &scratch,
        &o.env,
        &["kill-server", "--server", text_of(&dir)],
        "",
    );
    assert_eq!(
        run.code, 0,
        "kill autostarted server: {} {}",
        run.stdout, run.stderr
    );
}

#[test]
fn client_modes_before_attach_and_unattached_da1() {
    let s = start(&[]);
    let py = "import os,select,tty\ntty.setraw(0)\nos.write(1,b'\\x1b[c')\nif not select.select([0],[],[],3)[0]: raise RuntimeError('no DA1')\nr=os.read(0,1024)\nprint('DA1-ANSWERED' if r.startswith(b'\\x1b[?') else repr(r),flush=True)\nos.write(1,b'\\x1b[?1h\\x1b[?1000h\\x1b[?1002h\\x1b[?1004h\\x1b[?1006h\\x1b[?2004h\\x1b[=3;1uMODE-READY')\nwhile True:\n r=os.read(0,1024)\n print('INPUT:'+r.hex(),end='\\r\\n',flush=True)";
    let pane = s.pane(&format!("exec python3 -c {}", quote(py)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.wait_ticking("server answers DA1 without a view", || {
        s.request_text(
            "GET",
            &format!("/panes/{pane}/screen?format=plain&history=all"),
            None,
            200,
        )
        .contains("MODE-READY")
    });
    o.attach("cat");
    o.contains("DA1-ANSWERED");
    o.contains("MODE-READY");
    // The pane reads whatever the client forwarded since its last read as one input; waiting for
    // each line's own count keeps the inputs apart. The client forwards a focus-in on attach.
    let lines_with = |needle: &str| o.screen().matches(needle).count();
    o.raw("\x1b[O");
    o.contains("INPUT:1b5b4f");
    let focus_ins = lines_with("INPUT:1b5b49");
    o.raw("\x1b[I");
    o.wait("INPUT:1b5b49", || lines_with("INPUT:1b5b49") > focus_ins);
    o.raw("\x1b[A");
    o.contains("INPUT:1b5b313b313a3141");
    o.raw("\x1b[<0;40;5M");
    o.contains(&click(40 - PANE_X));
    o.raw(&format!("\x1b[<0;{};5M\x1b[<0;{};5M", PANE_X, PANE_X + 1));
    o.contains(&click(1));
    assert!(
        !o.screen().contains(&click(0)),
        "a click on the bar reached the pane"
    );
    o.raw("\x1b[200~abc\x1b[201~");
    o.contains("INPUT:1b5b3230307e6162631b5b3230317e");
    o.detach();
    o.attach("cat");
    o.contains("MODE-READY");
    o.raw("\x1b[A");
    o.wait("kitty mode input survives reattach", || {
        o.screen().matches("INPUT:1b5b313b313a3141").count() == 2
    });
    o.detach();
}

#[test]
fn client_initial_cursor_and_synchronized_output() {
    let s = start(&[]);
    let pane = interactive_fixture(&s);
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("BASE");
    let after_base = |data: &[u8]| {
        let text = String::from_utf8_lossy(data).into_owned();
        text.find("BASE").map(|first| text[first + 4..].to_owned())
    };
    o.wait("first pane frame completes", || {
        after_base(&o.output()).is_some_and(|frame| frame.contains("\x1b[?2026l"))
    });
    let mut first_frame = after_base(&o.output()).expect("first pane frame missing");
    if let Some(next) = first_frame.find("\x1b[?2026l") {
        first_frame.truncate(next);
    }
    assert!(
        !first_frame.contains("\x1b[?25l"),
        "first pane frame leaves its cursor hidden"
    );
    o.wait("visible initial pane cursor at pane column 4", || {
        o.cursor() == (true, PANE_X + 4, 0)
    });
    s.text(&pane, "h");
    assert!(
        o.within(Duration::from_millis(400), || o
            .screen()
            .contains("HOLD-CHANGED")),
        "synchronized output did not expire within 400 ms"
    );
    s.text(&pane, "r");
    let shell = s.pane("printf '\\033]0;shell\\007'; exec /bin/sh");
    o.contains("2 shell");
    o.raw("\x1b[<0;3;2M\x1b[<0;3;2m");
    s.text(&shell, "printf 'SWITCHED\\n'\n");
    o.contains("SWITCHED");
    o.quiet();
    o.raw("echo abc");
    o.enter();
    o.wait("complete echo output without another input", || {
        o.lines().iter().any(|line| pane_text(line).trim() == "abc")
    });
    s.text(&shell, "printf 'POST-%s\\n' OUTPUT\n");
    o.contains("POST-OUTPUT");
    s.text(&shell, "printf 'COLORS:%s\\n' \"$(tput colors)\"\n");
    o.contains("COLORS:256");
    o.detach();
}

#[test]
fn client_sidebar_ownership() {
    let s = start(&[]);
    let pane = interactive_fixture(&s);
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("BASE");
    for (y, line) in o.lines().iter().take(29).enumerate() {
        let cells: Vec<char> = line.chars().collect();
        assert!(
            cells.len() >= PANE_X && cells[PANE_X - 1] == '│',
            "no bar left of the pane in row {y}: {line:?}"
        );
    }
    o.chord(115);
    s.text(&pane, "f");
    o.wait_ticking("pane draws across the hidden sidebar", || {
        o.raw("z");
        let lines = o.lines();
        lines.len() > 3 && lines[3].starts_with(&"P".repeat(24))
    });
    assert!(
        !o.screen().contains('│'),
        "bar drawn while the sidebar is hidden"
    );
    o.chord(115);
    o.contains("1 fixture");
    for (y, line) in o.lines().iter().enumerate() {
        let bytes = line.as_bytes();
        let line = String::from_utf8_lossy(&bytes[..bytes.len().min(24)]).into_owned();
        let text = line.trim();
        if (y == 0 && text == "1 fixture") || text.starts_with("ko:") {
            continue;
        }
        assert!(text.is_empty(), "stale sidebar cells in row {y}: {line:?}");
    }
    o.detach();
}

const TERMINAL_PROXY: &str = r##"#!/usr/bin/env python3
import fcntl,os,pty,re,select,struct,sys,termios,tty,time
saved=termios.tcgetattr(0)
pid,fd=pty.fork()
if pid==0:
 w,h=os.get_terminal_size(1)
 fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',h,w,0,0))
 os.execv(sys.argv[1],[sys.argv[1]]+sys.argv[2:])
tty.setraw(0)
pending=b''
try:
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  ready,_,_=select.select([0,fd],[],[],min(1,deadline-time.monotonic()))
  if 0 in ready: os.write(fd,os.read(0,65536))
  if fd in ready:
   try: data=os.read(fd,65536)
   except OSError: break
   if not data: break
   pending+=data
   if b'\x1b[?25$p' in pending:
    os.write(fd,b'\x1b[?25;0$y')
    pending=pending.replace(b'\x1b[?25$p',b'')
   if b'\x1b[?u' in pending:
    os.write(fd,b'\x1b[?0u')
    pending=pending.replace(b'\x1b[?u',b'')
   last=pending.rfind(b'\x1b')
   if last>=0 and not re.fullmatch(rb'\x1b\[[0-?]*[ -/]*[@-~]',pending[last:]) and len(pending)-last<16:
    os.write(1,pending[:last]);pending=pending[last:]
   else: os.write(1,pending);pending=b''
finally:
 if pending: os.write(1,pending)
 termios.tcsetattr(0,termios.TCSANOW,saved)
 os.close(fd)
 deadline=time.monotonic()+2
 killed=False
 while True:
  done,_=os.waitpid(pid,os.WNOHANG)
  if done: break
  if time.monotonic()>=deadline:
   if killed: raise RuntimeError('client did not exit')
   os.kill(pid,9);killed=True;deadline=time.monotonic()+1
  select.select([],[],[],0.01)
"##;

#[test]
fn client_unknown_cursor_mode_and_keyboard_stack() {
    let s = start(&[]);
    interactive_fixture(&s);
    let mut o = Outer::new(&s.dir, Keys::Extended);
    let proxy = o.dir.join("terminal-proxy");
    std::fs::write(&proxy, TERMINAL_PROXY).unwrap();
    std::fs::set_permissions(&proxy, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    o.executable = proxy;
    o.arguments = vec![text_of(&crate::harness::ko()).to_owned()];
    o.attach("cat");
    o.contains("BASE");
    o.detach();
    assert!(o.cursor().0, "unknown saved cursor mode restored hidden");
    let data = o.output();
    let pushes = count_sequences(&data, b"\x1b[>", b"0123456789;");
    let pops = count_sequences(&data, b"\x1b[<", b"0123456789");
    assert!(
        pushes == 1 && pops == pushes,
        "kitty stack: pushes={pushes} pops={pops}, want one owned entry"
    );
}

#[test]
fn client_different_sizes_and_signal_cleanup() {
    let s = start(&[]);
    interactive_fixture(&s);
    let large = Outer::new(&s.dir, Keys::Extended);
    large.attach("cat");
    large.contains("BASE");
    let small = Outer::new(&s.dir, Keys::Extended);
    small.resize(85, 20);
    small.attach("cat");
    small.contains("BASE");
    large.contains("BASE");
    small.detach();
    large.detach();
    let o = Outer::new(&s.dir, Keys::Extended);
    let mut errors = Vec::new();
    for signal in [Signal::Hup, Signal::Term] {
        let before = o.modes();
        o.attach("cat");
        o.contains("BASE");
        signal_descendant(o.shell_pid(), o.client_pid(), signal).unwrap();
        o.detached();
        let after = o.modes();
        if before != after {
            errors.push(format!(
                "signal {signal:?}: modes before {before:?} after {after:?}"
            ));
        }
    }
    let data = o.output();
    let push = count_sequences(&data, b"\x1b[>", b"0123456789;");
    let pop = count_sequences(&data, b"\x1b[<", b"0123456789");
    if push != pop {
        errors.push(format!("signal cleanup kitty pushes={push} pops={pop}"));
    }
    assert!(errors.is_empty(), "{errors:?}");
}

#[test]
fn client_warning_mouse_bounds() {
    let s = start(&[]);
    for i in 1..=5 {
        let program = format!(
            "import os,tty\ntty.setraw(0)\nos.write(1,b'\\x1b[?1000h\\x1b[?1006hSELECTED-{i}')\nb=b''\nwhile not b.endswith(b'x'): b+=os.read(0,4096)\nos.write(1,('INPUT:'+b.hex()).encode())\nwhile True: os.read(0,4096)"
        );
        s.pane(&format!("exec python3 -u -c {}", quote(&program)));
    }
    let o = Outer::new(&s.dir, Keys::Unconfirmed);
    o.resize(120, 1);
    o.attach("cat");
    o.contains("extended keys were not confirmed");
    o.raw("\x1b[<0;30;1M");
    o.resize(120, 5);
    o.contains("SELECTED-1");
    o.raw("\x1b[<0;1;5M\x1b[<0;30;5M");
    o.raw("x");
    o.contains("INPUT:78");
    o.contains("SELECTED-1");
    o.detach();
}

#[test]
fn client_dead_pane_line() {
    let s = start(&[]);
    let fill = "yes '' | head -40; printf last; ";
    s.pane(&format!("{fill}exit 3"));
    s.pane(&format!("{fill}kill -TERM $$"));
    s.pane("printf 'live\\n'; exec cat");
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    let line = |text: &str| {
        o.wait(text, || {
            let lines = o.lines();
            for (y, l) in lines.iter().enumerate() {
                if pane_text(l).starts_with(text) {
                    assert!(
                        y != 0 && pane_text(&lines[y - 1]).starts_with("last"),
                        "no program output directly above the line:\n{}",
                        lines.join("\n")
                    );
                    return true;
                }
            }
            false
        });
    };
    line("[exited 3 \u{2014} Ctrl+D to remove]");
    o.raw("\x1b[<0;3;2M\x1b[<0;3;2m");
    line("[killed by SIGTERM \u{2014} Ctrl+D to remove]");
    o.raw("\x1b[<0;3;3M\x1b[<0;3;3m");
    o.contains("live");
    o.wait("dead line gone after switching away", || {
        !o.screen().contains("Ctrl+D")
    });
    o.detach();
}

#[test]
fn client_legacy_shifted_key() {
    let cases: [(&str, i32, &str, String); 21] = [
        ("flags 3, plain colon", 3, ":", hex(":")),
        ("flags 3, plain A", 3, "A", hex("A")),
        ("flags 3, plain É", 3, "É", hex("É")),
        (
            "flags 3, CSI u colon without text",
            3,
            "\x1b[59;2u",
            hex(":"),
        ),
        ("flags 3, CSI u A without text", 3, "\x1b[97;2u", hex("A")),
        ("flags 3, CSI u ! without text", 3, "\x1b[49;2u", hex("!")),
        ("flags 3, CSI u é without text", 3, "\x1b[233;2u", hex("É")),
        (
            "flags 3, CSI u with explicit text",
            3,
            "\x1b[97;2;937u",
            hex("Ω"),
        ),
        ("flags 3, Shift+Space", 3, "\x1b[32;2u", hex("\x1b[32;2u")),
        ("flags 3, Shift+Enter", 3, "\x1b[13;2u", hex("\x1b[13;2u")),
        ("flags 3, Alt+Shift+A", 3, "\x1b[97;4u", hex("\x1b[97;4u")),
        ("flags 31, plain colon", 31, ":", hex("\x1b[59:58;2;58u")),
        ("flags 31, plain A", 31, "A", hex("\x1b[97:65;2;65u")),
        (
            "flags 31, CSI u A without text",
            31,
            "\x1b[97;2u",
            hex("\x1b[97:65;2;65u"),
        ),
        ("legacy pane, plain A", 0, "A", hex("A")),
        (
            "legacy pane, CSI u A without text",
            0,
            "\x1b[97;2u",
            hex("A"),
        ),
        ("legacy pane, Alt+Shift+A", 0, "\x1b[97;4u", hex("\x1bA")),
        ("legacy pane, Alt+b", 0, "\x1b[98;3u", hex("\x1bb")),
        ("flags 1, plain A", 1, "A", hex("A")),
        ("flags 1, CSI u A without text", 1, "\x1b[97;2u", hex("A")),
        (
            "flags 1, CSI u colon without text",
            1,
            "\x1b[59;2u",
            hex(":"),
        ),
    ];
    let plan: Vec<String> = cases.iter().map(|case| case.1.to_string()).collect();
    let s = start(&[]);
    let program = format!("import os,tty\ntty.setraw(0)\nf=[{}]\n", plan.join(","))
        + r#"os.write(1,b'\x1b[>%du'%f[0]+b'KEY-READY')
n=0
while True:
 b=os.read(0,4096)
 n+=1
 nxt=b'\x1b[=%d;1u'%f[n] if n<len(f) else b''
 os.write(1,nxt+('\r\nKEY%d:'%n+b.hex()+'\r\n').encode())"#;
    s.pane(&format!("exec python3 -u -c {}", quote(&program)));
    let o = Outer::new(&s.dir, Keys::Extended);
    o.attach("cat");
    o.contains("KEY-READY");
    for (i, (name, _, typed, want)) in cases.iter().enumerate() {
        o.raw(typed);
        let expected = format!("KEY{}:{want}\n", i + 1);
        o.wait(&format!("{name}: {expected}"), || {
            o.screen().contains(&expected)
        });
    }
    o.detach();
}

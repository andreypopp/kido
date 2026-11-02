use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use ko_client::api;
use ko_server::ids::{PaneId, VarName};
use ko_server::protocol::Route;
use serde_json::json;

use crate::prime::ssh_bootstrap;

const MARK_DEADLINE: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Keep,
    Drop,
    Refuse,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SshOption {
    letter: char,
    class: Class,
    value: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SshArgs {
    opts: Vec<String>,
    options: Vec<SshOption>,
    dest: String,
    command: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pane {
    pub dir: PathBuf,
    pub id: PaneId,
}

fn letters(args: &SshArgs) -> String {
    args.options.iter().map(|option| option.letter).collect()
}

fn takes_value(letter: char) -> Option<Class> {
    match letter {
        'B' | 'b' | 'c' | 'F' | 'I' | 'i' | 'J' | 'l' | 'm' | 'o' | 'p' | 'P' | 'S' => {
            Some(Class::Keep)
        }
        'D' | 'E' | 'e' | 'L' | 'R' => Some(Class::Drop),
        'O' | 'Q' | 'W' | 'w' => Some(Class::Refuse),
        _ => None,
    }
}

fn flag_class(letter: char) -> Class {
    match letter {
        '4' | '6' | 'C' | 'K' | 'k' => Class::Keep,
        'A' | 'a' | 'f' | 'g' | 'N' | 'n' | 'q' | 'T' | 't' | 'v' | 'x' | 'X' | 'Y' | 'y' => {
            Class::Drop
        }
        _ => Class::Refuse,
    }
}

fn cluster(arg: &str, next: Option<&String>) -> Option<(Vec<SshOption>, Vec<String>, usize)> {
    let letters: Vec<char> = arg.chars().skip(1).collect();
    let mut options = Vec::new();
    for (index, &letter) in letters.iter().enumerate() {
        let Some(class) = takes_value(letter) else {
            options.push(SshOption {
                letter,
                class: flag_class(letter),
                value: None,
            });
            continue;
        };
        let attached: String = letters
            .get(index + 1..)
            .unwrap_or_default()
            .iter()
            .collect();
        let (value, used, consumed) = if attached.is_empty() {
            let value = next?.clone();
            (value.clone(), vec![arg.to_owned(), value], 2)
        } else {
            (attached, vec![arg.to_owned()], 1)
        };
        options.push(SshOption {
            letter,
            class,
            value: Some(value),
        });
        return Some((options, used, consumed));
    }
    Some((options, vec![arg.to_owned()], 1))
}

fn parse(args: &[String]) -> Option<SshArgs> {
    let mut opts = Vec::new();
    let mut options = Vec::new();
    let mut dest: Option<String> = None;
    let mut at = 0;
    let finish = |opts, options, dest: Option<String>, command: &[String]| {
        dest.map(|dest| SshArgs {
            opts,
            options,
            dest,
            command: command.to_vec(),
        })
    };
    while let Some(arg) = args.get(at) {
        let rest = args.get(at + 1..).unwrap_or_default();
        if arg == "--" {
            return match (dest, rest.split_first()) {
                (None, Some((first, command))) => {
                    finish(opts, options, Some(first.clone()), command)
                }
                (dest, _) => finish(opts, options, dest, rest),
            };
        }
        if arg == "-" || !arg.starts_with('-') {
            if dest.is_some() {
                return finish(opts, options, dest, args.get(at..).unwrap_or_default());
            }
            dest = Some(arg.clone());
            at += 1;
            continue;
        }
        let (found, used, consumed) = cluster(arg, rest.first())?;
        options.extend(found);
        opts.extend(used);
        at += consumed;
    }
    finish(opts, options, dest, &[])
}

fn connection_args(args: &SshArgs) -> Option<Vec<String>> {
    if args.dest.is_empty() || args.dest.starts_with('-') {
        return None;
    }
    let mut kept = Vec::new();
    for option in &args.options {
        match option.class {
            Class::Refuse => return None,
            Class::Drop => {}
            Class::Keep => {
                kept.push(format!("-{}", option.letter));
                kept.extend(option.value.clone());
            }
        }
    }
    kept.push(args.dest.clone());
    Some(kept)
}

fn destination(ssh: &Path, args: &[String]) -> Option<String> {
    let output = Command::new(ssh)
        .arg("-G")
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    let text = String::from_utf8_lossy(&output.stdout);
    let field = |key: &str| {
        text.lines()
            .find_map(|line| line.strip_prefix(key)?.strip_prefix(' '))
    };
    Some(format!("{}@{}", field("user")?, field("hostname")?))
}

fn mark(ssh: &Path, pane: &Pane, args: &[String], parsed: Option<&SshArgs>) {
    let Some(destination) = destination(ssh, args) else {
        return;
    };
    let (Ok(dest), Ok(extra)) = (VarName::new("ssh.dest"), VarName::new("ssh.args")) else {
        return;
    };
    let requests = [
        (
            Route::SetVar(pane.id, dest),
            json!(destination).to_string().into_bytes(),
        ),
        match parsed.and_then(connection_args) {
            Some(connection) => (
                Route::SetVar(pane.id, extra),
                json!(connection).to_string().into_bytes(),
            ),
            None => (Route::DeleteVar(pane.id, extra), Vec::new()),
        },
    ];
    let deadline = Instant::now() + MARK_DEADLINE;
    for (route, body) in requests {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        let (method, path) = route.to_request();
        let _ = api::request_within(&pane.dir, method, &path, &body, left);
    }
}

pub fn prepare(ssh: &Path, tty: bool, pane: Option<&Pane>, args: &[OsString]) -> Vec<OsString> {
    let unchanged = || {
        std::iter::once(OsString::from("ssh"))
            .chain(args.iter().cloned())
            .collect()
    };
    let Some(text) = args
        .iter()
        .map(|arg| arg.to_str().map(str::to_owned))
        .collect::<Option<Vec<String>>>()
    else {
        return unchanged();
    };
    let parsed = parse(&text);
    if let Some(pane) = pane {
        mark(ssh, pane, &text, parsed.as_ref());
    }
    match parsed {
        Some(parsed)
            if tty
                && parsed.command.is_empty()
                && !letters(&parsed).contains(|letter| "NTWfsnOQVG".contains(letter)) =>
        {
            std::iter::once(OsString::from("ssh"))
                .chain(parsed.opts.iter().map(OsString::from))
                .chain(["-t", "--"].map(OsString::from))
                .chain([
                    OsString::from(&parsed.dest),
                    OsString::from(ssh_bootstrap()),
                ])
                .collect()
        }
        _ => unchanged(),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::ffi::OsStringExt;

    use super::*;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_owned()).collect()
    }

    fn connection(args: &[&str]) -> String {
        parse(&words(args))
            .and_then(|parsed| connection_args(&parsed))
            .map_or("refused".to_owned(), |args| json!(args).to_string())
    }

    fn shown(args: &[&str]) -> String {
        parse(&words(args)).map_or("no destination".to_owned(), |parsed| {
            format!(
                "opts=[{}] letters={} dest={} command=[{}]",
                parsed.opts.join(" "),
                letters(&parsed),
                parsed.dest,
                parsed.command.join(" ")
            )
        })
    }

    #[test]
    fn ssh_connection_arguments() {
        let cases: [(&[&str], &str); 16] = [
            (&["alias"], r#"["alias"]"#),
            (
                &[
                    "-4Cp2222",
                    "-J",
                    "jump",
                    "-Fcfg",
                    "-i",
                    "key",
                    "-luser",
                    "-o",
                    "ProxyCommand=ssh jump nc %h %p",
                    "-6",
                    "-S",
                    "socket",
                    "alias",
                    "uptime",
                ],
                r#"["-4","-C","-p","2222","-J","jump","-F","cfg","-i","key","-l","user","-o","ProxyCommand=ssh jump nc %h %p","-6","-S","socket","alias"]"#,
            ),
            (
                &[
                    "-B",
                    "if0",
                    "-b",
                    "127.0.0.1",
                    "-c",
                    "aes128-ctr",
                    "-I",
                    "provider",
                    "-m",
                    "hmac-sha2-256",
                    "-P",
                    "tag",
                    "-Kk",
                    "alias",
                ],
                r#"["-B","if0","-b","127.0.0.1","-c","aes128-ctr","-I","provider","-m","hmac-sha2-256","-P","tag","-K","-k","alias"]"#,
            ),
            (
                &[
                    "-ttTAaNfnqvgxXYy",
                    "-Llocal",
                    "-R",
                    "remote",
                    "-D1080",
                    "-Elog",
                    "-e",
                    "none",
                    "alias",
                    "sh",
                    "-c",
                    "command",
                ],
                r#"["alias"]"#,
            ),
            (&["--", "alias", "-Z"], r#"["alias"]"#),
            (&["-Z", "alias"], "refused"),
            (&["-O", "check", "alias"], "refused"),
            (&["-W", "host:22", "alias"], "refused"),
            (&["-M", "alias"], "refused"),
            (&["-s", "alias"], "refused"),
            (&["-G", "alias"], "refused"),
            (&["-Q", "help"], "refused"),
            (&["-V"], "refused"),
            (&["-p"], "refused"),
            (&["--", "-host"], "refused"),
            (&["-i", "clé/🔑", "hôte"], r#"["-i","clé/🔑","hôte"]"#),
        ];
        for (args, expected) in cases {
            assert_eq!(connection(args), expected, "{args:?}");
        }
    }

    #[test]
    fn ssh_options_after_the_destination() {
        let cases: [(&[&str], &str, &str); 10] = [
            (
                &["example.test", "-p", "2222"],
                "opts=[-p 2222] letters=p dest=example.test command=[]",
                r#"["-p","2222","example.test"]"#,
            ),
            (
                &["--", "example.test", "-p", "2222"],
                "opts=[] letters= dest=example.test command=[-p 2222]",
                r#"["example.test"]"#,
            ),
            (
                &["example.test", "--", "-p", "2222"],
                "opts=[] letters= dest=example.test command=[-p 2222]",
                r#"["example.test"]"#,
            ),
            (
                &["example.test", "uptime", "-p", "2222"],
                "opts=[] letters= dest=example.test command=[uptime -p 2222]",
                r#"["example.test"]"#,
            ),
            (
                &["-p", "2222", "example.test", "-p", "3333"],
                "opts=[-p 2222 -p 3333] letters=pp dest=example.test command=[]",
                r#"["-p","2222","-p","3333","example.test"]"#,
            ),
            (
                &["example.test", "-N"],
                "opts=[-N] letters=N dest=example.test command=[]",
                r#"["example.test"]"#,
            ),
            (
                &["example.test", "-s"],
                "opts=[-s] letters=s dest=example.test command=[]",
                "refused",
            ),
            (
                &["example.test", "-O", "check"],
                "opts=[-O check] letters=O dest=example.test command=[]",
                "refused",
            ),
            (
                &["example.test", "-Z"],
                "opts=[-Z] letters=Z dest=example.test command=[]",
                "refused",
            ),
            (
                &["-o", "BatchMode=yes", "example.test", "-o", "BatchMode=no"],
                "opts=[-o BatchMode=yes -o BatchMode=no] letters=oo dest=example.test command=[]",
                r#"["-o","BatchMode=yes","-o","BatchMode=no","example.test"]"#,
            ),
        ];
        for (args, parsed, kept) in cases {
            assert_eq!(
                (shown(args), connection(args)),
                (parsed.to_owned(), kept.to_owned())
            );
        }
    }

    #[test]
    fn ssh_options_require_a_value_on_both_sides_of_the_destination() {
        for letter in "BbcDEeFIiJLlmOoPpQRSWw".chars() {
            let flag = format!("-{letter}");
            assert!(parse(&words(&[&flag])).is_none(), "{flag}");
            assert!(parse(&words(&["host", &flag])).is_none(), "host {flag}");
            assert!(parse(&words(&[&flag, "host"])).is_none(), "{flag} host");
        }
    }

    #[test]
    fn parse_separates_options_and_the_remote_command() {
        let cases: [(&[&str], &str); 11] = [
            (&["host"], "opts=[] letters= dest=host command=[]"),
            (&["-A", "host"], "opts=[-A] letters=A dest=host command=[]"),
            (
                &["-tt", "host"],
                "opts=[-tt] letters=tt dest=host command=[]",
            ),
            (
                &["-o", "BatchMode=yes", "host"],
                "opts=[-o BatchMode=yes] letters=o dest=host command=[]",
            ),
            (
                &["-oBatchMode=yes", "host"],
                "opts=[-oBatchMode=yes] letters=o dest=host command=[]",
            ),
            (
                &["-P", "2222", "host"],
                "opts=[-P 2222] letters=P dest=host command=[]",
            ),
            (
                &["-4p", "2222", "host"],
                "opts=[-4p 2222] letters=4p dest=host command=[]",
            ),
            (
                &["host", "uptime", "-a"],
                "opts=[] letters= dest=host command=[uptime -a]",
            ),
            (
                &["--", "h", "uptime"],
                "opts=[] letters= dest=h command=[uptime]",
            ),
            (&["-V"], "no destination"),
            (&[], "no destination"),
        ];
        for (args, expected) in cases {
            assert_eq!(shown(args), expected, "{args:?}");
        }
    }

    #[test]
    fn an_argument_that_is_not_utf8_passes_through_unprimed_and_unmarked() {
        let args = [OsString::from("host"), OsString::from_vec(vec![0xff])];
        let pane = Pane {
            dir: PathBuf::from("/nonexistent"),
            id: "pane_1".parse().unwrap(),
        };
        let argv = prepare(Path::new("/nonexistent/ssh"), true, Some(&pane), &args);
        assert_eq!(
            argv,
            [OsString::from("ssh"), args[0].clone(), args[1].clone()]
        );
    }

    #[test]
    fn a_terminal_session_without_a_command_runs_the_bootstrap_after_the_options() {
        let args = [OsString::from("-oBatchMode=yes"), OsString::from("alias")];
        let primed = prepare(Path::new("/nonexistent/ssh"), true, None, &args);
        let bootstrap = ssh_bootstrap();
        assert_eq!(
            primed,
            [
                "ssh",
                "-oBatchMode=yes",
                "-t",
                "--",
                "alias",
                bootstrap.as_str()
            ]
            .map(OsString::from)
        );
        for passthrough in [
            prepare(Path::new("/nonexistent/ssh"), false, None, &args),
            prepare(
                Path::new("/nonexistent/ssh"),
                true,
                None,
                &[OsString::from("alias"), OsString::from("uptime")],
            ),
            prepare(
                Path::new("/nonexistent/ssh"),
                true,
                None,
                &[OsString::from("-N"), OsString::from("alias")],
            ),
        ] {
            assert!(
                !passthrough.contains(&OsString::from("-t")),
                "{passthrough:?}"
            );
        }
    }
}

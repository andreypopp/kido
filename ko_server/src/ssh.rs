use std::path::Path;

use ko_sys::pid::Exit;

use crate::config::SUN_PATH_MAX;
use crate::ids::PaneId;

pub const SOCKET: &str = "socket";
pub const TOKEN_SUFFIX: &str = ".token";

pub fn token_name(pane: PaneId) -> String {
    format!("{pane}{TOKEN_SUFFIX}")
}

/// The name of the master's control socket in the directory of a link.
pub const CONTROL: &str = "ctl";

// ssh creates the master's socket as "<ControlPath>." and 16 random characters before it renames
// the file into place, and that name must fit in sun_path too.
pub(crate) const MASTER_SUFFIX: usize = "/".len() + CONTROL.len() + ".".len() + 16;
pub const MAX_DIR: usize = SUN_PATH_MAX - MASTER_SUFFIX;

pub const MASTER_OPTIONS: [&str; 3] = [
    "ExitOnForwardFailure=yes",
    "ServerAliveInterval=5",
    "ServerAliveCountMax=3",
];

// ssh reads a colon and a percent sign in a path as syntax.
pub fn has_syntax(text: &str) -> bool {
    text.contains([':', '%'])
}

pub fn quote(word: &str) -> String {
    String::from_utf8_lossy(&quote_bytes(word.as_bytes())).into_owned()
}

pub(crate) fn quote_bytes(word: &[u8]) -> Vec<u8> {
    let mut quoted = vec![b'\''];
    for &byte in word {
        if byte == b'\'' {
            quoted.extend_from_slice(b"'\\''");
        } else {
            quoted.push(byte);
        }
    }
    quoted.push(b'\'');
    quoted
}

pub fn control_args(ctl: &Path, operation: &[&str], host: &str) -> Vec<String> {
    ["-S", &ctl.to_string_lossy()]
        .into_iter()
        .chain(operation.iter().copied())
        .chain([host])
        .map(str::to_owned)
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueryFailure {
    NoKo,
    Ssh(String),
    Exit { code: i32, message: String },
    Signal(i32),
}

// The outcome of a command that runs ko on the remote and reports on stdout.
pub fn query_failure(exit: Exit, stderr: &[u8]) -> Option<QueryFailure> {
    let message = String::from_utf8_lossy(stderr).trim().to_owned();
    match exit {
        Exit::Exited(0) => None,
        Exit::Exited(127) => Some(QueryFailure::NoKo),
        Exit::Exited(255) => Some(QueryFailure::Ssh(message)),
        Exit::Exited(code) => Some(QueryFailure::Exit { code, message }),
        Exit::Signaled(signal) => Some(QueryFailure::Signal(signal)),
    }
}

pub fn reported_path(text: &str) -> Option<&str> {
    let path = text.trim();
    (path.starts_with('/') && !has_syntax(path) && !path.contains(['\n', '\0'])).then_some(path)
}

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
pub struct SshArgs {
    pub opts: Vec<String>,
    options: Vec<SshOption>,
    pub dest: String,
    pub command: Vec<String>,
}

fn letters(args: &SshArgs) -> String {
    args.options.iter().map(|option| option.letter).collect()
}

// Whether ssh runs a terminal session that ko can prime.
pub fn interactive(args: &SshArgs) -> bool {
    !letters(args).contains(|letter| "NTWfsnOQVG".contains(letter))
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

pub fn parse(args: &[String]) -> Option<SshArgs> {
    let mut opts = Vec::new();
    let mut options = Vec::new();
    let mut dest: Option<String> = None;
    let mut at = 0;
    let finish = |opts, options, dest: Option<String>, command: &[String]| {
        dest.filter(|dest| !dest.is_empty() && !dest.starts_with('-'))
            .map(|dest| SshArgs {
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

pub fn connection_args(args: &SshArgs) -> Option<Vec<String>> {
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

pub fn no_remote_ko(host: &str) -> String {
    format!("ko was not found on {host}; install it there, on the PATH of ssh commands")
}

pub fn forwarding_refused(host: &str) -> String {
    format!(
        "{host} refuses unix-socket forwarding, and ko needs it (sshd AllowStreamLocalForwarding)"
    )
}

pub(crate) fn connection_only(args: &[String], destination: &str) -> Result<(), String> {
    let words: Vec<String> = args
        .iter()
        .cloned()
        .chain([destination.to_owned()])
        .collect();
    let parsed = parse(&words).ok_or_else(|| "is not a list of ssh options".to_owned())?;
    if parsed.dest != destination || !parsed.command.is_empty() {
        return Err(format!("{:?} is not an ssh option", parsed.dest));
    }
    for option in &parsed.options {
        if option.class != Class::Keep {
            return Err(format!(
                "-{} is not a connection option; ko owns the rest of the ssh command",
                option.letter
            ));
        }
        let owned = match (option.letter, option.value.as_deref()) {
            ('S', _) => true,
            ('o', Some(value)) => {
                let key = value.trim_start().split(['=', ' ', '\t']).next();
                key.is_some_and(|key| {
                    ["controlpath", "controlmaster", "controlpersist"]
                        .contains(&key.to_ascii_lowercase().as_str())
                })
            }
            _ => false,
        };
        if owned {
            return Err(format!(
                "-{} {} would replace the control socket of ko",
                option.letter,
                option.value.as_deref().unwrap_or_default()
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

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
        let cases: [(&[&str], &str); 17] = [
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
            (&[""], "refused"),
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
    fn configured_ssh_arguments_cannot_replace_the_control_socket() {
        let check = |args: &[&str]| connection_only(&words(args), "host");
        for owned in [
            &["-S", "x"][..],
            &["-Sx"],
            &["-o", "ControlPath=x"],
            &["-ocontrolmaster=no"],
            &["-o", "ControlPersist no"],
            &["-o", "  CONTROLPATH=x"],
        ] {
            assert!(
                check(owned).unwrap_err().contains("control socket"),
                "{owned:?}"
            );
        }
        assert_eq!(check(&["-o", "ControlPathX=1"]), Ok(()));
        assert_eq!(check(&["-o", "ServerAliveInterval=9"]), Ok(()));
    }

    #[test]
    fn query_failures_and_reported_paths() {
        let fail = |exit, stderr: &[u8]| query_failure(exit, stderr);
        assert_eq!(fail(Exit::Exited(0), b""), None);
        assert_eq!(fail(Exit::Exited(127), b"x"), Some(QueryFailure::NoKo));
        assert_eq!(
            fail(Exit::Exited(255), b" denied \n"),
            Some(QueryFailure::Ssh("denied".to_owned()))
        );
        assert_eq!(
            fail(Exit::Exited(3), b"boom"),
            Some(QueryFailure::Exit {
                code: 3,
                message: "boom".to_owned()
            })
        );
        assert_eq!(reported_path("/a/b\n"), Some("/a/b"));
        for bad in ["a", "/a:b", "/a%b", "/a\nb", "/a\0b"] {
            assert_eq!(reported_path(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn configured_ssh_arguments_are_connection_options_only() {
        let check = |args: &[&str], destination: &str| connection_only(&words(args), destination);
        assert_eq!(check(&["-p", "2222", "-i", "key"], "me@host"), Ok(()));
        assert_eq!(check(&[], "host"), Ok(()));
        assert!(check(&["-N"], "host").unwrap_err().starts_with("-N is not"));
        assert!(check(&["-L", "1:2:3"], "host").is_err());
        assert!(check(&["-O", "check"], "host").is_err());
        assert!(check(&["-p"], "host").is_err());
        assert!(check(&["stray"], "host").unwrap_err().contains("stray"));
        assert!(check(&[], "-host").is_err());
        assert!(check(&[], "").is_err());
    }
}

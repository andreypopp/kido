use crate::ids::VarName;
use crate::program_status::{app, root};
use crate::protocol::ProgramRecord;
use crate::telemetry::Telemetry;
use crate::vars::Vars;

const SSH_DEST: VarName = VarName::known("ssh.dest");
const PI_SESSION: VarName = VarName::known("pi.session");
const PI_NAME: VarName = VarName::known("pi.name");
const PI_ACTIVITY: VarName = VarName::known("pi.activity");

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteKind {
    Terminal,
    Agent { name: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Kind {
    Terminal,
    SomeAgent {
        name: String,
    },
    PiAgent {
        session: String,
        name: String,
        activity: String,
    },
    Ssh {
        user: String,
        host: String,
        pane: RemoteKind,
    },
}

fn destination(vars: &Vars) -> Option<(String, String)> {
    let (user, host) = vars.text(&SSH_DEST)?.rsplit_once('@')?;
    (!user.is_empty() && !host.is_empty()).then(|| (user.to_owned(), host.to_owned()))
}

pub(crate) fn classify(telemetry: &Telemetry, vars: &Vars, records: &[ProgramRecord]) -> Kind {
    let root_app = root(records).and_then(|record| app(records, record));
    let ssh = telemetry
        .foreground
        .as_ref()
        .is_some_and(|foreground| foreground.name == "ssh")
        .then(|| destination(vars))
        .flatten();
    if let Some((user, host)) = ssh {
        let pane = match root_app {
            Some(name @ ("pi" | "claude-code")) => RemoteKind::Agent {
                name: name.to_owned(),
            },
            _ => RemoteKind::Terminal,
        };
        return Kind::Ssh { user, host, pane };
    }
    let var = |name: &VarName| vars.text(name).unwrap_or_default().to_owned();
    match root_app {
        Some("pi") => match vars.text(&PI_SESSION).filter(|session| !session.is_empty()) {
            Some(session) => Kind::PiAgent {
                session: session.to_owned(),
                name: var(&PI_NAME),
                activity: var(&PI_ACTIVITY),
            },
            None => Kind::SomeAgent {
                name: "pi".to_owned(),
            },
        },
        Some("claude-code") => Kind::SomeAgent {
            name: "claude-code".to_owned(),
        },
        _ => Kind::Terminal,
    }
}

pub(crate) fn title(kind: &Kind, pane_title: &str) -> Option<String> {
    let named = |name: &str| {
        if pane_title.is_empty() {
            name.to_owned()
        } else {
            pane_title.to_owned()
        }
    };
    match kind {
        Kind::Ssh {
            pane: RemoteKind::Terminal,
            ..
        }
        | Kind::Terminal => None,
        Kind::SomeAgent { name }
        | Kind::Ssh {
            pane: RemoteKind::Agent { name },
            ..
        } => Some(named(name)),
        Kind::PiAgent { name, .. } => Some(if name.is_empty() {
            pane_title.to_owned()
        } else {
            name.clone()
        }),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;
    use crate::protocol::{Foreground, ProgramState};

    struct Fixture {
        telemetry: Telemetry,
        vars: Vars,
    }

    impl Fixture {
        fn kind(&self, records: &[ProgramRecord]) -> Kind {
            classify(&self.telemetry, &self.vars, records)
        }
    }

    fn telemetry(foreground: &str, vars: &[(&str, Value)]) -> Fixture {
        let mut found = Vars::default();
        for (name, value) in vars {
            found
                .set(&VarName::new(name).unwrap(), value.clone())
                .unwrap();
        }
        Fixture {
            telemetry: Telemetry {
                foreground: Some(Foreground {
                    pid: 1,
                    name: foreground.to_owned(),
                }),
                ..Telemetry::default()
            },
            vars: found,
        }
    }

    #[test]
    fn the_constant_names_are_valid_names() {
        for name in ["ssh.dest", "pi.session", "pi.name", "pi.activity"] {
            assert_eq!(VarName::new(name).unwrap(), VarName::known(name));
        }
    }

    fn root_app(name: &str) -> Vec<ProgramRecord> {
        vec![ProgramRecord {
            id: String::new(),
            state: ProgramState::Idle,
            app: Some(name.to_owned()),
            title: None,
            msg: None,
        }]
    }

    #[test]
    fn a_pi_session_variable_needs_a_pi_root() {
        let pi = telemetry(
            "zsh",
            &[("pi.session", json!("s1")), ("pi.name", json!("Worker"))],
        );
        assert_eq!(pi.kind(&[]), Kind::Terminal);
        assert_eq!(
            pi.kind(&root_app("pi")),
            Kind::PiAgent {
                session: "s1".to_owned(),
                name: "Worker".to_owned(),
                activity: String::new()
            }
        );
        let bare = telemetry("zsh", &[("pi.session", json!(7))]);
        assert_eq!(
            bare.kind(&root_app("pi")),
            Kind::SomeAgent {
                name: "pi".to_owned()
            }
        );
        assert_eq!(
            bare.kind(&root_app("claude-code")),
            Kind::SomeAgent {
                name: "claude-code".to_owned()
            }
        );
        assert_eq!(bare.kind(&root_app("make")), Kind::Terminal);
    }

    #[test]
    fn an_ssh_destination_needs_the_ssh_foreground_and_splits_at_the_last_at_sign() {
        let vars = [("ssh.dest", json!("deploy@realm@next.test"))];
        let ssh = telemetry("ssh", &vars).kind(&root_app("claude-code"));
        assert_eq!(
            ssh,
            Kind::Ssh {
                user: "deploy@realm".to_owned(),
                host: "next.test".to_owned(),
                pane: RemoteKind::Agent {
                    name: "claude-code".to_owned()
                }
            }
        );
        assert_eq!(telemetry("zsh", &vars).kind(&[]), Kind::Terminal);
        for dest in [json!("nohost"), json!("@host"), json!("user@"), json!(5)] {
            assert_eq!(
                telemetry("ssh", &[("ssh.dest", dest)]).kind(&[]),
                Kind::Terminal
            );
        }
        let remote = telemetry("ssh", &[("ssh.dest", json!("u@h"))]).kind(&[]);
        assert_eq!(title(&remote, "t"), None);
    }

    #[test]
    fn the_title_prefers_the_pane_title_for_an_agent_and_the_name_for_a_pi_session() {
        let some = Kind::SomeAgent {
            name: "claude-code".to_owned(),
        };
        assert_eq!(title(&some, "Claude Code").as_deref(), Some("Claude Code"));
        assert_eq!(title(&some, "").as_deref(), Some("claude-code"));
        let pi = |name: &str| Kind::PiAgent {
            session: "s".to_owned(),
            name: name.to_owned(),
            activity: String::new(),
        };
        assert_eq!(title(&pi("Worker"), "pane").as_deref(), Some("Worker"));
        assert_eq!(title(&pi(""), "pane").as_deref(), Some("pane"));
        assert_eq!(title(&Kind::Terminal, "x"), None);
    }
}

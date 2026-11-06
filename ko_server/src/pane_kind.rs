use crate::ids::VarName;
use crate::pane::Pane;
use crate::program_status::{app, root};
use crate::protocol::{Foreground, ProgramRecord};
use crate::vars::Vars;

const SSH_DEST: VarName = VarName::known("ssh.dest");
pub(crate) const PI_SESSION: VarName = VarName::known("pi.session");
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
        destination: String,
        pane: RemoteKind,
    },
}

fn destination(vars: &Vars) -> Option<String> {
    vars.text(&SSH_DEST)
        .filter(|destination| !destination.is_empty())
        .map(str::to_owned)
}

pub(crate) fn classify(
    foreground: Option<&Foreground>,
    vars: &Vars,
    records: &[ProgramRecord],
) -> Kind {
    let root_app = root(records).and_then(|record| app(records, record));
    let ssh = foreground
        .is_some_and(|foreground| foreground.name == "ssh")
        .then(|| destination(vars))
        .flatten();
    if let Some(destination) = ssh {
        let pane = match root_app {
            Some(name @ ("pi" | "claude-code")) => RemoteKind::Agent {
                name: name.to_owned(),
            },
            _ => RemoteKind::Terminal,
        };
        return Kind::Ssh { destination, pane };
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

pub(crate) fn of_pane(pane: &Pane) -> Kind {
    classify(
        pane.status_foreground(),
        pane.vars(),
        &pane.telemetry().records.published().records,
    )
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
    use crate::protocol::ProgramState;
    use crate::telemetry::Telemetry;

    struct Fixture {
        telemetry: Telemetry,
        vars: Vars,
    }

    impl Fixture {
        fn kind(&self, records: &[ProgramRecord]) -> Kind {
            classify(self.telemetry.foreground.as_ref(), &self.vars, records)
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
            started: None,
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
                activity: String::new(),
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
    fn an_ssh_destination_needs_the_ssh_foreground_and_is_kept_as_typed() {
        let vars = [("ssh.dest", json!("deploy@realm@next.test"))];
        let ssh = telemetry("ssh", &vars).kind(&root_app("claude-code"));
        assert_eq!(
            ssh,
            Kind::Ssh {
                destination: "deploy@realm@next.test".to_owned(),
                pane: RemoteKind::Agent {
                    name: "claude-code".to_owned()
                }
            }
        );
        assert_eq!(telemetry("zsh", &vars).kind(&[]), Kind::Terminal);
        for dest in [json!(""), json!(5)] {
            assert_eq!(
                telemetry("ssh", &[("ssh.dest", dest)]).kind(&[]),
                Kind::Terminal
            );
        }
        let remote = telemetry("ssh", &[("ssh.dest", json!("h"))]).kind(&[]);
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

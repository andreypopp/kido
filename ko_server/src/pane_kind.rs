use crate::pane::Pane;
use crate::program_status::{app, root};
use crate::runtime::RuntimeKey;
use ko_wire::ids::VarName;
use ko_wire::protocol::{Foreground, ProgramRecord};
use ko_wire::vars::Vars;

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
pub(crate) enum LocalKind {
    Terminal,
    SomeAgent {
        name: String,
    },
    PiAgent {
        session: String,
        name: String,
        activity: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Kind {
    Host {
        pane: LocalKind,
    },
    Runtime {
        pane: LocalKind,
    },
    Ssh {
        destination: String,
        pane: RemoteKind,
    },
}

impl Kind {
    pub(crate) fn local(&self) -> Option<&LocalKind> {
        match self {
            Self::Host { pane } | Self::Runtime { pane } => Some(pane),
            Self::Ssh { .. } => None,
        }
    }
}

fn destination(vars: &Vars) -> Option<String> {
    vars.text(&SSH_DEST)
        .filter(|destination| !destination.is_empty())
        .map(str::to_owned)
}

pub(crate) fn classify(
    runtime: Option<&RuntimeKey>,
    foreground: Option<&Foreground>,
    vars: &Vars,
    records: &[ProgramRecord],
) -> Kind {
    let root_app = root(records).and_then(|record| app(records, record));
    let local = || {
        let var = |name: &VarName| vars.text(name).unwrap_or_default().to_owned();
        match root_app {
            Some("pi") => match vars.text(&PI_SESSION).filter(|session| !session.is_empty()) {
                Some(session) => LocalKind::PiAgent {
                    session: session.to_owned(),
                    name: var(&PI_NAME),
                    activity: var(&PI_ACTIVITY),
                },
                None => LocalKind::SomeAgent {
                    name: "pi".to_owned(),
                },
            },
            Some("claude-code") => LocalKind::SomeAgent {
                name: "claude-code".to_owned(),
            },
            _ => LocalKind::Terminal,
        }
    };
    match runtime {
        Some(_) => Kind::Runtime { pane: local() },
        None => {
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
            Kind::Host { pane: local() }
        }
    }
}

pub(crate) fn of_pane(pane: &Pane) -> Kind {
    classify(
        pane.runtime(),
        pane.telemetry().foreground.as_ref(),
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
        Kind::Host { pane } | Kind::Runtime { pane } => match pane {
            LocalKind::Terminal => None,
            LocalKind::SomeAgent { name } => Some(named(name)),
            LocalKind::PiAgent { name, .. } => Some(if name.is_empty() {
                pane_title.to_owned()
            } else {
                name.clone()
            }),
        },
        Kind::Ssh {
            pane: RemoteKind::Terminal,
            ..
        } => None,
        Kind::Ssh {
            pane: RemoteKind::Agent { name },
            ..
        } => Some(named(name)),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;
    use crate::telemetry::Telemetry;
    use ko_wire::protocol::ProgramState;

    struct Fixture {
        telemetry: Telemetry,
        vars: Vars,
    }

    impl Fixture {
        fn kind(&self, records: &[ProgramRecord]) -> Kind {
            classify(
                None,
                self.telemetry.foreground.as_ref(),
                &self.vars,
                records,
            )
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

    fn root_app(name: &str) -> Vec<ProgramRecord> {
        vec![ProgramRecord {
            id: String::new().try_into().unwrap(),
            started: None,
            state: ProgramState::Idle,
            app: Some(name.to_owned()),
            title: None,
            msg: None,
            selection: None,
        }]
    }

    #[test]
    fn a_pi_session_variable_needs_a_pi_root() {
        let pi = telemetry(
            "zsh",
            &[("pi.session", json!("s1")), ("pi.name", json!("Worker"))],
        );
        assert_eq!(
            pi.kind(&[]),
            Kind::Host {
                pane: LocalKind::Terminal
            }
        );
        assert_eq!(
            pi.kind(&root_app("pi")),
            Kind::Host {
                pane: LocalKind::PiAgent {
                    session: "s1".to_owned(),
                    name: "Worker".to_owned(),
                    activity: String::new(),
                }
            }
        );
        let bare = telemetry("zsh", &[("pi.session", json!(7))]);
        assert_eq!(
            bare.kind(&root_app("pi")),
            Kind::Host {
                pane: LocalKind::SomeAgent {
                    name: "pi".to_owned()
                }
            }
        );
        assert_eq!(
            bare.kind(&root_app("claude-code")),
            Kind::Host {
                pane: LocalKind::SomeAgent {
                    name: "claude-code".to_owned()
                }
            }
        );
        assert_eq!(
            bare.kind(&root_app("make")),
            Kind::Host {
                pane: LocalKind::Terminal
            }
        );
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
        assert_eq!(
            telemetry("zsh", &vars).kind(&[]),
            Kind::Host {
                pane: LocalKind::Terminal
            }
        );
        for dest in [json!(""), json!(5)] {
            assert_eq!(
                telemetry("ssh", &[("ssh.dest", dest)]).kind(&[]),
                Kind::Host {
                    pane: LocalKind::Terminal
                }
            );
        }
        let remote = telemetry("ssh", &[("ssh.dest", json!("h"))]).kind(&[]);
        assert_eq!(title(&remote, "t"), None);
    }

    #[test]
    fn runtime_membership_precedes_the_transport_and_uses_the_local_root() {
        let runtime =
            RuntimeKey::config(ko_config::values::RuntimeName::try_from("dev".to_owned()).unwrap());
        for foreground in ["zsh", "ssh"] {
            for (app, session, expected) in [
                (None, None, LocalKind::Terminal),
                (
                    Some("claude-code"),
                    None,
                    LocalKind::SomeAgent {
                        name: "claude-code".to_owned(),
                    },
                ),
                (
                    Some("pi"),
                    None,
                    LocalKind::SomeAgent {
                        name: "pi".to_owned(),
                    },
                ),
                (
                    Some("pi"),
                    Some("s"),
                    LocalKind::PiAgent {
                        session: "s".to_owned(),
                        name: "Worker".to_owned(),
                        activity: String::new(),
                    },
                ),
                (None, Some("stale"), LocalKind::Terminal),
            ] {
                let mut vars = vec![
                    ("ssh.dest", json!("transport")),
                    ("pi.name", json!("Worker")),
                ];
                if let Some(session) = session {
                    vars.push(("pi.session", json!(session)));
                }
                let fixture = telemetry(foreground, &vars);
                let records = app.map_or_else(Vec::new, root_app);
                assert_eq!(
                    classify(
                        Some(&runtime),
                        fixture.telemetry.foreground.as_ref(),
                        &fixture.vars,
                        &records
                    ),
                    Kind::Runtime {
                        pane: expected.clone()
                    }
                );
                if foreground != "ssh" {
                    assert_eq!(fixture.kind(&records), Kind::Host { pane: expected });
                }
            }
        }
    }

    #[test]
    fn the_title_prefers_the_pane_title_for_an_agent_and_the_name_for_a_pi_session() {
        let some = Kind::Host {
            pane: LocalKind::SomeAgent {
                name: "claude-code".to_owned(),
            },
        };
        assert_eq!(title(&some, "Claude Code").as_deref(), Some("Claude Code"));
        assert_eq!(title(&some, "").as_deref(), Some("claude-code"));
        let pi = |name: &str| Kind::Host {
            pane: LocalKind::PiAgent {
                session: "s".to_owned(),
                name: name.to_owned(),
                activity: String::new(),
            },
        };
        assert_eq!(title(&pi("Worker"), "pane").as_deref(), Some("Worker"));
        assert_eq!(title(&pi(""), "pane").as_deref(), Some("pane"));
        assert_eq!(
            title(
                &Kind::Host {
                    pane: LocalKind::Terminal
                },
                "x"
            ),
            None
        );
    }
}

use crate::pane::Pane;
use crate::runtime::RuntimeKey;
use ko_wire::ids::VarName;
use ko_wire::protocol::Foreground;
use ko_wire::vars::Vars;

const SSH_DEST: VarName = VarName::known("ssh.dest");
const KOA_SESSION: VarName = VarName::known("koa.session");
const KOA_NAME: VarName = VarName::known("koa.name");
const KOA_ACTIVITY: VarName = VarName::known("koa.activity");

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
    KoaAgent {
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
    pub(crate) fn is_agent(&self) -> bool {
        match self {
            Self::Host { pane } | Self::Runtime { pane } => match pane {
                LocalKind::Terminal => false,
                LocalKind::SomeAgent { .. } | LocalKind::KoaAgent { .. } => true,
            },
            Self::Ssh { pane, .. } => match pane {
                RemoteKind::Terminal => false,
                RemoteKind::Agent { .. } => true,
            },
        }
    }

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
    root_app: Option<&str>,
) -> Kind {
    let local = || {
        let var = |name: &VarName| vars.text(name).unwrap_or_default().to_owned();
        match root_app {
            Some("koa") => match vars
                .text(&KOA_SESSION)
                .filter(|session| !session.is_empty())
            {
                Some(session) => LocalKind::KoaAgent {
                    session: session.to_owned(),
                    name: var(&KOA_NAME),
                    activity: var(&KOA_ACTIVITY),
                },
                None => LocalKind::SomeAgent {
                    name: "koa".to_owned(),
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
                    Some(name @ ("koa" | "claude-code")) => RemoteKind::Agent {
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
        pane.telemetry()
            .records
            .owned_app(pane.telemetry().foreground.as_ref()),
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
            LocalKind::KoaAgent { name, .. } => Some(if name.is_empty() {
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

    struct Fixture {
        telemetry: Telemetry,
        vars: Vars,
    }

    impl Fixture {
        fn kind(&self, root_app: Option<&str>) -> Kind {
            classify(
                None,
                self.telemetry.foreground.as_ref(),
                &self.vars,
                root_app,
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

    #[test]
    fn a_koa_session_variable_needs_a_koa_root_and_a_bare_pi_is_a_terminal() {
        let koa = telemetry(
            "zsh",
            &[("koa.session", json!("s1")), ("koa.name", json!("Worker"))],
        );
        assert_eq!(
            koa.kind(None),
            Kind::Host {
                pane: LocalKind::Terminal
            }
        );
        assert_eq!(
            koa.kind(Some("koa")),
            Kind::Host {
                pane: LocalKind::KoaAgent {
                    session: "s1".to_owned(),
                    name: "Worker".to_owned(),
                    activity: String::new(),
                }
            }
        );
        let bare = telemetry("zsh", &[("koa.session", json!(7))]);
        assert_eq!(
            bare.kind(Some("koa")),
            Kind::Host {
                pane: LocalKind::SomeAgent {
                    name: "koa".to_owned()
                }
            }
        );
        assert_eq!(
            bare.kind(Some("claude-code")),
            Kind::Host {
                pane: LocalKind::SomeAgent {
                    name: "claude-code".to_owned()
                }
            }
        );
        assert_eq!(
            koa.kind(Some("pi")),
            Kind::Host {
                pane: LocalKind::Terminal
            }
        );
        assert_eq!(
            bare.kind(Some("make")),
            Kind::Host {
                pane: LocalKind::Terminal
            }
        );
    }

    #[test]
    fn an_ssh_destination_needs_the_ssh_foreground_and_is_kept_as_typed() {
        let vars = [("ssh.dest", json!("deploy@realm@next.test"))];
        let ssh = telemetry("ssh", &vars).kind(Some("claude-code"));
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
            telemetry("ssh", &vars).kind(Some("pi")),
            Kind::Ssh {
                destination: "deploy@realm@next.test".to_owned(),
                pane: RemoteKind::Terminal
            }
        );
        assert_eq!(
            telemetry("zsh", &vars).kind(None),
            Kind::Host {
                pane: LocalKind::Terminal
            }
        );
        for dest in [json!(""), json!(5)] {
            assert_eq!(
                telemetry("ssh", &[("ssh.dest", dest)]).kind(None),
                Kind::Host {
                    pane: LocalKind::Terminal
                }
            );
        }
        let remote = telemetry("ssh", &[("ssh.dest", json!("h"))]).kind(None);
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
                    Some("koa"),
                    None,
                    LocalKind::SomeAgent {
                        name: "koa".to_owned(),
                    },
                ),
                (
                    Some("koa"),
                    Some("s"),
                    LocalKind::KoaAgent {
                        session: "s".to_owned(),
                        name: "Worker".to_owned(),
                        activity: String::new(),
                    },
                ),
                (None, Some("stale"), LocalKind::Terminal),
            ] {
                let mut vars = vec![
                    ("ssh.dest", json!("transport")),
                    ("koa.name", json!("Worker")),
                ];
                if let Some(session) = session {
                    vars.push(("koa.session", json!(session)));
                }
                let fixture = telemetry(foreground, &vars);
                assert_eq!(
                    classify(
                        Some(&runtime),
                        fixture.telemetry.foreground.as_ref(),
                        &fixture.vars,
                        app
                    ),
                    Kind::Runtime {
                        pane: expected.clone()
                    }
                );
                if foreground != "ssh" {
                    assert_eq!(fixture.kind(app), Kind::Host { pane: expected });
                }
            }
        }
    }

    #[test]
    fn the_title_prefers_the_pane_title_for_an_agent_and_the_name_for_a_koa_session() {
        let some = Kind::Host {
            pane: LocalKind::SomeAgent {
                name: "claude-code".to_owned(),
            },
        };
        assert_eq!(title(&some, "Claude Code").as_deref(), Some("Claude Code"));
        assert_eq!(title(&some, "").as_deref(), Some("claude-code"));
        let koa = |name: &str| Kind::Host {
            pane: LocalKind::KoaAgent {
                session: "s".to_owned(),
                name: name.to_owned(),
                activity: String::new(),
            },
        };
        assert_eq!(title(&koa("Worker"), "pane").as_deref(), Some("Worker"));
        assert_eq!(title(&koa(""), "pane").as_deref(), Some("pane"));
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

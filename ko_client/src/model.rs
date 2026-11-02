use std::collections::BTreeMap;
use std::time::Instant;

use ko_pane_wire::frame::Limits;
use ko_server::ids::{ClientId, Instance, PaneId, VarName};
use ko_server::protocol::{self, ClientEvent, Listing, Row};
use serde_json::Value;

use crate::status::{Mark, Seen};
use crate::wire::{Link, Next, text};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notice {
    Bell(PaneId),
    Notify {
        pane: PaneId,
        title: Option<String>,
        body: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pane {
    pub row: Row,
    pub vars: BTreeMap<VarName, Value>,
}

#[derive(Debug)]
pub struct Model {
    pub client: ClientId,
    pub instance: Instance,
    pub limits: Limits,
    pub panes: Vec<Pane>,
    anchor: (u64, Instant),
    seen: Seen,
    fetching: Option<Vec<ClientEvent>>,
}

impl Model {
    pub fn welcome(link: &mut Link) -> Result<Model, String> {
        let mut next = || match link.receive().map_err(text)? {
            Next::Text(event) => protocol::decode::<ClientEvent>(event.as_bytes()).map_err(text),
            _ => Err("client event missing".to_owned()),
        };
        let ClientEvent::Welcome(welcome) = next()? else {
            return Err("welcome missing".to_owned());
        };
        let ClientEvent::Topology { panes } = next()? else {
            return Err("topology missing".to_owned());
        };
        Ok(Model::new(welcome, panes))
    }

    fn new(welcome: protocol::Welcome, rows: Vec<Row>) -> Model {
        Model {
            client: welcome.client,
            instance: welcome.instance,
            limits: welcome.limits.terminal.limits(),
            panes: rows
                .into_iter()
                .map(|row| Pane {
                    row,
                    vars: BTreeMap::new(),
                })
                .collect(),
            anchor: (welcome.now, Instant::now()),
            seen: Seen::new(welcome.now),
            fetching: Some(Vec::new()),
        }
    }

    pub fn server_now(&self) -> u64 {
        let elapsed = u64::try_from(self.anchor.1.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.anchor.0.saturating_add(elapsed)
    }

    pub fn observe(&mut self, shown: Option<PaneId>) {
        self.seen.observe(shown, &self.panes);
    }

    pub fn mark(&self, pane: &Pane) -> Mark {
        self.seen.mark(pane)
    }

    pub fn begin_fetch(&mut self) {
        self.fetching.get_or_insert_with(Vec::new);
    }

    pub fn finish_fetch(&mut self, listing: Vec<Listing>) {
        self.panes = listing
            .into_iter()
            .map(|entry| Pane {
                row: entry.row,
                vars: entry.vars,
            })
            .collect();
        for event in self.fetching.take().unwrap_or_default() {
            self.apply_now(event);
        }
    }

    fn pane_mut(&mut self, id: PaneId) -> Option<&mut Pane> {
        self.panes.iter_mut().find(|pane| pane.row.id == id)
    }

    pub fn apply(&mut self, event: ClientEvent) -> Option<Notice> {
        if let Some(fetching) = &mut self.fetching {
            fetching.push(event.clone());
        }
        self.apply_now(event)
    }

    fn apply_now(&mut self, event: ClientEvent) -> Option<Notice> {
        match event {
            ClientEvent::Topology { panes } => {
                let mut kept = std::mem::take(&mut self.panes);
                self.panes = panes
                    .into_iter()
                    .map(|row| {
                        let vars = kept
                            .iter_mut()
                            .find(|pane| pane.row.id == row.id)
                            .map(|pane| std::mem::take(&mut pane.vars))
                            .unwrap_or_default();
                        Pane { row, vars }
                    })
                    .collect();
            }
            ClientEvent::Title(title) => {
                if let Some(pane) = self.pane_mut(title.pane) {
                    pane.row.title = title.title;
                }
            }
            ClientEvent::Dead(dead) => {
                if let Some(pane) = self.pane_mut(dead.pane) {
                    pane.row.dead = Some(dead.dead);
                }
            }
            ClientEvent::Status(change) => {
                self.anchor = (change.now, Instant::now());
                if let Some(pane) = self.pane_mut(change.pane) {
                    pane.row.status = Some(change.status);
                }
            }
            ClientEvent::Var { pane, name, value } => {
                if let Some(pane) = self.pane_mut(pane) {
                    pane.vars.insert(name, value);
                }
            }
            ClientEvent::VarDeleted { pane, name } => {
                if let Some(pane) = self.pane_mut(pane) {
                    pane.vars.remove(&name);
                }
            }
            ClientEvent::Progress { pane, progress } => {
                if let Some(pane) = self.pane_mut(pane) {
                    pane.row.progress = progress;
                }
            }
            ClientEvent::Bell { pane } => return Some(Notice::Bell(pane)),
            ClientEvent::Notify { pane, title, body } => {
                return Some(Notice::Notify { pane, title, body });
            }
            ClientEvent::Welcome(_) | ClientEvent::Pwd(_) => {}
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use ko_server::protocol::{Cause, Dead};
    use serde_json::json;

    use super::*;

    fn id(number: u64) -> PaneId {
        format!("pane_{number}").parse().unwrap()
    }

    fn name(text: &str) -> VarName {
        VarName::new(text).unwrap()
    }

    fn row(number: u64) -> Row {
        serde_json::from_value(json!({
            "id": format!("pane_{number}"), "pid": 1, "command": [], "cwd": "/", "title": "",
            "dead": null
        }))
        .unwrap()
    }

    fn entry(number: u64, vars: &[(&str, Value)]) -> Listing {
        Listing {
            row: row(number),
            vars: vars
                .iter()
                .map(|(key, value)| (name(key), value.clone()))
                .collect(),
        }
    }

    fn model() -> Model {
        let welcome = serde_json::from_value(json!({
            "client": "client_1",
            "limits": {"terminal": {"scrollback": {"type": "disabled"}, "apc_max_bytes": 1,
                "kitty_images_max_bytes": 1, "continuation_max_bytes": 1}, "media": []},
            "instance": "0123456789abcdef0123456789abcdef",
            "now": 1000
        }))
        .unwrap();
        Model::new(welcome, Vec::new())
    }

    fn var(number: u64, key: &str, value: Value) -> ClientEvent {
        ClientEvent::Var {
            pane: id(number),
            name: name(key),
            value,
        }
    }

    fn vars_of(model: &Model, number: u64) -> Option<BTreeMap<String, Value>> {
        model
            .panes
            .iter()
            .find(|pane| pane.row.id == id(number))
            .map(|pane| {
                pane.vars
                    .iter()
                    .map(|(key, value)| (key.as_str().to_owned(), value.clone()))
                    .collect()
            })
    }

    #[test]
    fn a_var_event_read_during_the_fetch_is_not_lost_and_a_later_one_wins() {
        let mut model = model();
        model.apply(var(1, "a", json!(2)));
        model.apply(ClientEvent::VarDeleted {
            pane: id(1),
            name: name("gone"),
        });
        model.finish_fetch(vec![entry(
            1,
            &[("a", json!(1)), ("gone", json!(true)), ("b", json!(5))],
        )]);
        assert_eq!(
            vars_of(&model, 1),
            Some(BTreeMap::from([
                ("a".to_owned(), json!(2)),
                ("b".to_owned(), json!(5))
            ]))
        );
        model.apply(var(1, "a", json!(3)));
        assert_eq!(vars_of(&model, 1).unwrap()["a"], json!(3));
        assert!(model.fetching.is_none());
    }

    #[test]
    fn a_status_dead_or_topology_event_during_the_fetch_survives_the_snapshot() {
        let mut model = model();
        let dead = Dead {
            at: 1,
            cause: Cause::Exited { code: 0 },
        };
        model.apply(ClientEvent::Topology {
            panes: vec![row(1)],
        });
        model.apply(ClientEvent::Dead(protocol::PaneDead {
            pane: id(1),
            dead: dead.clone(),
        }));
        model.finish_fetch(vec![entry(1, &[]), entry(2, &[("x", json!(1))])]);
        assert_eq!(model.panes.len(), 1, "the removal of pane_2 survives");
        assert_eq!(model.panes[0].row.dead, Some(dead));
    }

    #[test]
    fn a_var_event_of_a_pane_removed_during_the_fetch_does_not_recreate_it() {
        let mut model = model();
        model.apply(var(2, "x", json!(1)));
        model.apply(ClientEvent::Topology {
            panes: vec![row(1)],
        });
        model.finish_fetch(vec![entry(1, &[]), entry(2, &[])]);
        assert_eq!(vars_of(&model, 2), None);
        assert_eq!(vars_of(&model, 1), Some(BTreeMap::new()));
    }

    #[test]
    fn the_server_clock_estimate_starts_at_the_last_now() {
        let model = model();
        assert!(model.server_now() >= 1_000);
    }
}

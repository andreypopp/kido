use std::collections::BTreeMap;
use std::time::Instant;

use ko_pane_wire::frame::Limits;
use ko_server::ids::{ClientId, Instance, PaneId, RunId, SessionId, VarName, WindowId};
use ko_server::protocol::{
    self, ClientEvent, ClientRequest, ClipboardContent, ClipboardLocation, Hello, LayoutPanes,
    Listing, Row, RunRow, Selection, Snapshot,
};
use ko_server::runs::Parent;
use schemars::JsonSchema;
use serde::Serialize;
use serde_json::Value;

use crate::status::{self, Mark, Seen};
use crate::tree;
use crate::wire::{Link, Next, text};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notice {
    Bell(PaneId),
    Notify {
        pane: PaneId,
        title: Option<String>,
        body: String,
    },
    ClipboardWrite {
        pane: PaneId,
        location: ClipboardLocation,
        contents: Vec<ClipboardContent>,
    },
    ClipboardRead {
        pane: PaneId,
        id: u64,
        location: ClipboardLocation,
        mimes: Vec<String>,
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
    pub layout: Snapshot,
    pub selection: Selection,
    pub panes: Vec<Pane>,
    anchor: (u64, Instant),
    seen: Seen,
    // What the caller shows, and whether the user looks: the panes that each change acknowledges.
    watched: (Vec<PaneId>, bool),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Item {
    Session {
        id: SessionId,
        name: String,
    },
    Pane {
        id: PaneId,
        window: WindowId,
        depth: usize,
    },
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct PaneJson<'a> {
    label: String,
    mark: Mark,
    records_seen: bool,
    #[serde(flatten)]
    row: &'a Row,
    vars: &'a BTreeMap<VarName, Value>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct ModelJson<'a> {
    instance: String,
    selection: &'a Selection,
    layout: &'a Snapshot,
    panes: Vec<PaneJson<'a>>,
    outline: Vec<Item>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Applied {
    Nothing,
    State,
    Layout,
    Selected,
    Notice(Notice),
}

#[derive(Debug)]
pub enum Rejoin {
    Resume(Model),
    Fresh(Model),
}

impl Model {
    pub fn join(link: &mut Link, hello: Hello) -> Result<Model, String> {
        link.send(protocol::json(&ClientRequest::Hello(hello)))
            .and_then(|()| link.flush_blocking())
            .map_err(text)?;
        let mut next = || match link.receive().map_err(text)? {
            Next::Text(event) => protocol::decode::<ClientEvent>(event.as_bytes()).map_err(text),
            _ => Err("client event missing".to_owned()),
        };
        let ClientEvent::Welcome(welcome) = next()? else {
            return Err("welcome missing".to_owned());
        };
        let ClientEvent::Layout(layout) = next()? else {
            return Err("layout missing".to_owned());
        };
        Ok(Model::new(welcome, layout))
    }

    fn new(welcome: protocol::Welcome, announced: LayoutPanes) -> Model {
        let LayoutPanes { snapshot, panes } = announced;
        let mut model = Model {
            client: welcome.client,
            instance: welcome.instance,
            limits: welcome.limits.terminal.limits(),
            layout: snapshot,
            selection: Selection::default(),
            panes: Vec::new(),
            anchor: (welcome.now, Instant::now()),
            seen: Seen::new(welcome.now),
            watched: (Vec::new(), false),
        };
        model.add(panes);
        model.acknowledge();
        model
    }

    pub fn rejoin(&mut self, link: &mut Link, hello: Hello) -> Result<Rejoin, String> {
        let joined = Model::join(link, hello)?;
        Ok(self.gate(joined))
    }

    pub(crate) fn gate(&mut self, mut joined: Model) -> Rejoin {
        if joined.instance == self.instance {
            joined.seen = std::mem::replace(&mut self.seen, Seen::new(joined.anchor.0));
            Rejoin::Resume(joined)
        } else {
            Rejoin::Fresh(joined)
        }
    }

    #[cfg(target_vendor = "apple")]
    pub(crate) fn json(&self) -> ModelJson<'_> {
        ModelJson {
            instance: self.instance.to_string(),
            selection: &self.selection,
            layout: &self.layout,
            panes: self
                .panes
                .iter()
                .map(|pane| PaneJson {
                    label: status::title(pane),
                    mark: self.mark(pane),
                    records_seen: self.seen.records_seen(pane),
                    row: &pane.row,
                    vars: &pane.vars,
                })
                .collect(),
            outline: self.outline(),
        }
    }

    pub fn server_now(&self) -> u64 {
        let elapsed = u64::try_from(self.anchor.1.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.anchor.0.saturating_add(elapsed)
    }

    // Whether a mark changed.
    pub fn observe(&mut self, shown: &[PaneId], attending: bool) -> bool {
        let marks = |model: &Model| -> Vec<(Mark, bool)> {
            model
                .panes
                .iter()
                .map(|pane| (model.seen.mark(pane), model.seen.records_seen(pane)))
                .collect()
        };
        let before = marks(self);
        self.watched = (shown.to_vec(), attending);
        self.acknowledge();
        marks(self) != before
    }

    fn acknowledge(&mut self) {
        let (shown, attending) = &self.watched;
        self.seen.observe(shown, *attending, &self.panes);
    }

    fn runs(&self) -> impl Iterator<Item = (PaneId, &RunRow)> {
        self.panes
            .iter()
            .filter_map(|pane| Some((pane.row.id, pane.row.run.as_ref()?)))
    }

    pub fn mark(&self, pane: &Pane) -> Mark {
        self.seen.mark(pane)
    }

    fn install(&mut self, announced: LayoutPanes) {
        let LayoutPanes { snapshot, panes } = announced;
        let in_layout = snapshot.layout.panes();
        self.layout = snapshot;
        self.panes.retain(|pane| in_layout.contains(&pane.row.id));
        self.add(panes);
    }

    fn add(&mut self, panes: Vec<Listing>) {
        let mut at: BTreeMap<PaneId, usize> = self
            .panes
            .iter()
            .enumerate()
            .map(|(index, pane)| (pane.row.id, index))
            .collect();
        for entry in panes {
            let added = Pane {
                row: entry.row,
                vars: entry.vars.into(),
            };
            match at.get(&added.row.id) {
                Some(index) => self.panes[*index] = added,
                None => {
                    at.insert(added.row.id, self.panes.len());
                    self.panes.push(added);
                }
            }
        }
    }

    fn pane_mut(&mut self, id: PaneId) -> Option<&mut Pane> {
        self.panes.iter_mut().find(|pane| pane.row.id == id)
    }

    pub fn apply(&mut self, event: ClientEvent) -> Applied {
        let applied = self.apply_now(event);
        self.acknowledge();
        applied
    }

    fn apply_now(&mut self, event: ClientEvent) -> Applied {
        match event {
            ClientEvent::Layout(announced) => {
                self.install(announced);
                return Applied::Layout;
            }
            ClientEvent::Focus { window, pane } => {
                let found = self
                    .layout
                    .layout
                    .sessions
                    .iter_mut()
                    .flat_map(|session| &mut session.windows)
                    .find(|candidate| candidate.id == window);
                if let Some(found) = found {
                    found.focus = pane;
                    return Applied::Layout;
                }
            }
            ClientEvent::Run(run) => {
                if let Some(pane) = run.meta.pane.and_then(|pane| self.pane_mut(pane)) {
                    pane.row.run = Some(run);
                    return Applied::State;
                }
            }
            ClientEvent::Pwd(pwd) => {
                if let Some(pane) = self.pane_mut(pwd.pane) {
                    pane.row.cwd = pwd.pwd;
                    return Applied::State;
                }
            }
            ClientEvent::Foreground { pane, foreground } => {
                if let Some(pane) = self.pane_mut(pane) {
                    pane.row.foreground = Some(foreground);
                    return Applied::State;
                }
            }
            ClientEvent::Selected(selection) => {
                self.selection = selection;
                return Applied::Selected;
            }
            ClientEvent::Title(title) => {
                if let Some(pane) = self.pane_mut(title.pane) {
                    pane.row.title = title.title;
                    return Applied::State;
                }
            }
            ClientEvent::Dead(dead) => {
                if let Some(pane) = self.pane_mut(dead.pane) {
                    pane.row.dead = Some(dead.dead);
                    return Applied::State;
                }
            }
            ClientEvent::Status(change) => {
                self.anchor = (change.now, Instant::now());
                if let Some(pane) = self.pane_mut(change.pane) {
                    pane.row.status = Some(change.status);
                    return Applied::State;
                }
            }
            ClientEvent::Var { pane, name, value } => {
                if let Some(pane) = self.pane_mut(pane) {
                    pane.vars.insert(name, value);
                    return Applied::State;
                }
            }
            ClientEvent::VarDeleted { pane, name } => {
                if let Some(pane) = self.pane_mut(pane) {
                    pane.vars.remove(&name);
                    return Applied::State;
                }
            }
            ClientEvent::Progress { pane, progress } => {
                if let Some(pane) = self.pane_mut(pane) {
                    pane.row.progress = progress;
                    return Applied::State;
                }
            }
            ClientEvent::Bell { pane } => return Applied::Notice(Notice::Bell(pane)),
            ClientEvent::Notify { pane, title, body } => {
                return Applied::Notice(Notice::Notify { pane, title, body });
            }
            ClientEvent::ClipboardWrite {
                pane,
                location,
                contents,
            } => {
                return Applied::Notice(Notice::ClipboardWrite {
                    pane,
                    location,
                    contents,
                });
            }
            ClientEvent::ClipboardRead {
                pane,
                id,
                location,
                mimes,
            } => {
                return Applied::Notice(Notice::ClipboardRead {
                    pane,
                    id,
                    location,
                    mimes,
                });
            }
            ClientEvent::Welcome(_) => {}
        }
        Applied::Nothing
    }

    pub fn outline(&self) -> Vec<Item> {
        let pane_of_run: BTreeMap<&RunId, PaneId> = self
            .runs()
            .map(|(pane, run)| (&run.meta.id, pane))
            .collect();
        let parent_of_run = |run: &RunRow| match run.meta.parent.as_ref()? {
            Parent::Pane(parent) => Some(*parent),
            Parent::Run(id) => pane_of_run.get(id).copied(),
        };
        let mut items = Vec::new();
        for session in &self.layout.layout.sessions {
            items.push(Item::Session {
                id: session.id,
                name: String::from(session.name.clone()),
            });
            let panes: Vec<(PaneId, WindowId)> = session
                .windows
                .iter()
                .flat_map(|window| window.panes().into_iter().map(|pane| (pane, window.id)))
                .collect();
            let window_of: BTreeMap<PaneId, WindowId> = panes.iter().copied().collect();
            let mut by_pane = BTreeMap::new();
            let mut by_window = BTreeMap::new();
            for (pane, run) in self.runs() {
                by_pane.entry(pane).or_insert(run);
                if let Some(window) = window_of.get(&pane) {
                    by_window.entry(*window).or_insert(run);
                }
            }
            items.extend(
                tree::order(
                    panes,
                    |(pane, _)| *pane,
                    |(pane, window)| {
                        let run = by_pane.get(pane).or_else(|| by_window.get(window))?;
                        parent_of_run(run)
                    },
                )
                .into_iter()
                .map(|((id, window), depth)| Item::Pane { id, window, depth }),
            );
        }
        items
    }

    pub fn order(&self) -> Vec<PaneId> {
        self.outline()
            .into_iter()
            .filter_map(|item| match item {
                Item::Pane { id, .. } => Some(id),
                Item::Session { .. } => None,
            })
            .collect()
    }

    pub fn step(&self, from: Option<PaneId>, steps: isize) -> Option<PaneId> {
        let order = self.order();
        let count = isize::try_from(order.len())
            .ok()
            .filter(|count| *count > 0)?;
        let at = match from.and_then(|pane| order.iter().position(|found| *found == pane)) {
            Some(at) => isize::try_from(at).ok()? + steps,
            None if steps >= 0 => 0,
            None => count - 1,
        };
        order
            .get(usize::try_from(at.rem_euclid(count)).ok()?)
            .copied()
    }

    pub fn locate(&self, pane: PaneId) -> Option<(SessionId, WindowId)> {
        self.layout
            .layout
            .locate(pane)
            .map(|(session, window)| (session.id, window.id))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use ko_server::ids::{Name, RunId};
    use ko_server::protocol::{
        Axis, Cause, Cells, Dead, Float, Layout, Leaf, Listing, Node, Revision, Session,
    };
    use ko_server::vars::Vars;
    use proptest::prelude::*;
    use serde_json::{Value, json};

    use super::*;
    use ko_server::protocol::Window;

    #[derive(Debug, Clone)]
    enum Shape {
        Leaf,
        Split(bool, Vec<Shape>),
    }

    fn shapes() -> impl Strategy<Value = Shape> {
        Just(Shape::Leaf).prop_recursive(3, 12, 3, |inner| {
            (any::<bool>(), prop::collection::vec(inner, 2..4))
                .prop_map(|(horizontal, children)| Shape::Split(horizontal, children))
        })
    }

    fn layouts() -> impl Strategy<Value = Vec<Vec<(Shape, usize)>>> {
        prop::collection::vec(prop::collection::vec((shapes(), 0usize..3), 1..4), 0..4)
    }

    fn cells() -> Cells {
        Cells::new(10).unwrap()
    }

    fn build(shape: &Shape, next: &mut u64) -> Node<Leaf> {
        match shape {
            Shape::Leaf => {
                *next += 1;
                Node::Leaf(Leaf {
                    pane: id("pane_", *next),
                    cols: cells(),
                    rows: cells(),
                })
            }
            Shape::Split(horizontal, children) => Node::Split {
                split: if *horizontal {
                    Axis::Horizontal
                } else {
                    Axis::Vertical
                },
                children: children.iter().map(|child| build(child, next)).collect(),
            },
        }
    }

    fn layout_of(sessions: &[Vec<(Shape, usize)>]) -> Layout {
        let (mut pane, mut window) = (0, 0);
        let name = || Name::try_from("n".to_owned()).unwrap();
        Layout {
            sessions: sessions
                .iter()
                .zip(1..)
                .map(|(windows, n)| Session {
                    id: id("session_", n),
                    name: name(),
                    vars: Vars::default(),
                    windows: windows
                        .iter()
                        .map(|(shape, floats)| {
                            window += 1;
                            let tree = build(shape, &mut pane);
                            let floats = (0..*floats)
                                .map(|z| {
                                    pane += 1;
                                    Float {
                                        pane: id("pane_", pane),
                                        x: 0,
                                        y: 0,
                                        cols: cells(),
                                        rows: cells(),
                                        z: u32::try_from(z).unwrap(),
                                        border: false,
                                        title: String::new(),
                                    }
                                })
                                .collect();
                            let focus = {
                                let mut leaves = Vec::new();
                                tree.leaves(&mut leaves);
                                leaves[0].pane
                            };
                            Window {
                                id: id("window_", window),
                                name: name(),
                                vars: Vars::default(),
                                cols: cells(),
                                rows: cells(),
                                cell_px: None,
                                zoom: None,
                                focus,
                                tree,
                                floats,
                            }
                        })
                        .collect(),
                })
                .collect(),
        }
    }

    fn model(layout: Layout) -> Model {
        let welcome = serde_json::from_value::<protocol::Welcome>(json!({
            "client": "client_1",
            "limits": {"terminal": {"scrollback": {"type": "disabled"}, "apc_max_bytes": 0,
                "kitty_images_max_bytes": 0, "continuation_max_bytes": 0}, "media": []},
            "instance": "0123456789abcdef0123456789abcdef",
            "now": 1000
        }))
        .unwrap();
        let snapshot = Snapshot {
            revision: Revision::FIRST,
            layout,
        };
        Model::new(
            welcome,
            LayoutPanes {
                snapshot,
                panes: Vec::new(),
            },
        )
    }

    fn announced(snapshot: Snapshot, panes: Vec<Listing>) -> ClientEvent {
        ClientEvent::Layout(LayoutPanes { snapshot, panes })
    }

    fn revision(number: u64) -> Revision {
        protocol::decode(number.to_string().as_bytes()).unwrap()
    }

    fn row(id: PaneId) -> Row {
        serde_json::from_value(json!({
            "id": id, "pid": 1, "command": [], "cwd": "/", "title": "", "dead": null
        }))
        .unwrap()
    }

    fn rows_of(layout: &Layout) -> Vec<Pane> {
        layout
            .windows()
            .flat_map(|(_, window)| window.panes())
            .map(|id| Pane {
                row: row(id),
                vars: BTreeMap::new(),
            })
            .collect()
    }

    fn listings_of(layout: &Layout) -> Vec<Listing> {
        rows_of(layout)
            .into_iter()
            .map(|pane| Listing {
                row: pane.row,
                vars: Vars::default(),
            })
            .collect()
    }

    fn name(text: &str) -> VarName {
        VarName::new(text).unwrap()
    }

    fn entry(number: u64, vars: &[(&str, Value)]) -> Listing {
        Listing {
            row: row(pane(number)),
            vars: vars_of(vars),
        }
    }

    fn vars_of(vars: &[(&str, Value)]) -> Vars {
        vars.iter()
            .map(|(key, value)| (name(key), value.clone()))
            .collect::<BTreeMap<_, _>>()
            .try_into()
            .unwrap()
    }

    fn var(number: u64, key: &str, value: Value) -> ClientEvent {
        ClientEvent::Var {
            pane: pane(number),
            name: name(key),
            value,
        }
    }

    fn vars_in(model: &Model, number: u64) -> Option<BTreeMap<VarName, Value>> {
        model
            .panes
            .iter()
            .find(|found| found.row.id == pane(number))
            .map(|found| found.vars.clone())
    }

    fn one_pane_layout(numbers: &[u64]) -> Snapshot {
        let sessions = numbers
            .iter()
            .map(|_| vec![(Shape::Leaf, 0)])
            .collect::<Vec<_>>();
        let mut layout = layout_of(&sessions);
        for (session, number) in layout.sessions.iter_mut().zip(numbers) {
            session.windows[0].tree = Node::Leaf(Leaf {
                pane: pane(*number),
                cols: cells(),
                rows: cells(),
            });
        }
        Snapshot {
            revision: Revision::FIRST,
            layout,
        }
    }

    fn pane(number: u64) -> PaneId {
        id("pane_", number)
    }

    fn id<T: std::str::FromStr>(prefix: &str, number: u64) -> T {
        format!("{prefix}{number}").parse().ok().unwrap()
    }

    #[test]
    fn the_outline_groups_panes_under_their_session_in_document_order() {
        let sessions = vec![
            vec![
                (Shape::Split(true, vec![Shape::Leaf, Shape::Leaf]), 1),
                (Shape::Leaf, 0),
            ],
            vec![(Shape::Leaf, 0)],
        ];
        let model = model(layout_of(&sessions));
        let shown: Vec<String> = model
            .outline()
            .iter()
            .map(|item| match item {
                Item::Session { id, name } => format!("{id} {name}"),
                Item::Pane { id, depth, .. } => format!("{}{id}", " ".repeat(*depth)),
            })
            .collect();
        assert_eq!(
            shown,
            [
                "session_1 n",
                "pane_1",
                "pane_2",
                "pane_3",
                "pane_4",
                "session_2 n",
                "pane_5"
            ]
        );
        assert_eq!(
            model.locate(pane(4)),
            Some((id("session_", 1), id("window_", 2)))
        );
        assert_eq!(model.locate(pane(9)), None);
    }

    fn run(number: u8, on: u64, parent: Option<Parent>) -> RunRow {
        RunRow {
            meta: ko_server::runs::Meta {
                id: format!("{number:032x}").parse().unwrap(),
                name: ko_server::runs::RunName::new("r").unwrap(),
                parent,
                pane: Some(pane(on)),
                argv: vec!["cmd".to_owned()],
                cwd: String::new(),
                started_at: ko_server::timestamp::Timestamp::from_micros(0),
            },
            outcome: None,
        }
    }

    fn run_id(number: u8) -> RunId {
        format!("{number:032x}").parse().unwrap()
    }

    fn outline_of(model: &Model) -> Vec<String> {
        model
            .outline()
            .iter()
            .filter_map(|item| match item {
                Item::Pane { id, depth, .. } => Some(format!("{depth}{id}")),
                Item::Session { .. } => None,
            })
            .collect()
    }

    #[test]
    fn a_run_pane_follows_its_parent_pane_one_level_deeper_and_the_step_order_follows_the_rows() {
        let windows = vec![
            (Shape::Leaf, 0),
            (Shape::Leaf, 0),
            (Shape::Leaf, 0),
            (Shape::Leaf, 0),
        ];
        let mut model = model(layout_of(&[windows, vec![(Shape::Leaf, 0)]]));
        model.panes = rows_of(&model.layout.layout);
        assert_eq!(
            outline_of(&model),
            ["0pane_1", "0pane_2", "0pane_3", "0pane_4", "0pane_5"]
        );
        let events = [
            run(1, 3, Some(Parent::Pane(pane(1)))),
            run(2, 4, Some(Parent::Run(run_id(1)))),
            run(3, 2, Some(Parent::Pane(pane(5)))),
        ];
        for event in events {
            assert_eq!(model.apply(ClientEvent::Run(event)), Applied::State);
        }
        assert_eq!(
            outline_of(&model),
            ["0pane_1", "1pane_3", "2pane_4", "0pane_2", "0pane_5"],
            "a parent in another session leaves the child a root of its own"
        );
        assert_eq!(model.step(Some(pane(1)), 1), Some(pane(3)));
        assert_eq!(model.step(Some(pane(4)), 1), Some(pane(2)));
        let mut without_run = model.layout.clone();
        without_run.layout.sessions[0].windows.remove(2);
        assert_eq!(
            model.apply(announced(without_run, Vec::new())),
            Applied::Layout
        );
        let mut kept: Vec<RunId> = model.runs().map(|(_, run)| run.meta.id.clone()).collect();
        kept.sort();
        assert_eq!(
            kept,
            [run_id(2), run_id(3)],
            "the run of a pane that the layout dropped goes with it"
        );
        assert_eq!(
            model.apply(ClientEvent::Run(run(9, 3, None))),
            Applied::Nothing
        );
        assert_eq!(
            model.runs().count(),
            2,
            "a run event for a pane the layout lacks changes nothing"
        );
        let mut ended = run(2, 4, Some(Parent::Run(run_id(1))));
        ended.outcome = Some(ko_server::runs::RunOutcome {
            result: ko_server::runs::RunResult::Completed,
            text: String::new(),
            at: None,
        });
        assert_eq!(model.apply(ClientEvent::Run(ended.clone())), Applied::State);
        assert_eq!(
            model
                .panes
                .iter()
                .find(|p| p.row.id == pane(4))
                .unwrap()
                .row
                .run,
            Some(ended),
            "an outcome lands on the row of the run's pane"
        );
    }

    #[test]
    fn every_pane_of_a_run_window_follows_the_runs_parent() {
        let windows = vec![
            (Shape::Leaf, 0),
            (Shape::Split(true, vec![Shape::Leaf, Shape::Leaf]), 0),
        ];
        let mut model = model(layout_of(&[windows]));
        model.panes = rows_of(&model.layout.layout);
        assert_eq!(
            model.apply(ClientEvent::Run(run(1, 3, Some(Parent::Pane(pane(1)))))),
            Applied::State
        );
        assert_eq!(
            outline_of(&model),
            ["0pane_1", "1pane_2", "1pane_3"],
            "the split beside the run pane nests under the same parent"
        );
    }

    #[test]
    fn a_step_crosses_sessions_wraps_and_starts_at_either_end() {
        let sessions = vec![
            vec![(Shape::Leaf, 0)],
            vec![(Shape::Leaf, 0), (Shape::Leaf, 0)],
        ];
        let model = model(layout_of(&sessions));
        assert_eq!(model.step(Some(pane(1)), 1), Some(pane(2)));
        assert_eq!(model.step(Some(pane(3)), 1), Some(pane(1)));
        assert_eq!(model.step(Some(pane(1)), -1), Some(pane(3)));
        assert_eq!(model.step(None, 1), Some(pane(1)));
        assert_eq!(model.step(None, -1), Some(pane(3)));
        assert_eq!(model.step(Some(pane(9)), 1), Some(pane(1)));
        let empty = Model {
            layout: Snapshot {
                revision: Revision::FIRST,
                layout: Layout { sessions: vec![] },
            },
            ..model
        };
        assert_eq!(empty.step(None, 1), None);
    }

    #[test]
    fn a_layout_event_brings_the_rows_of_its_new_panes_and_a_selected_event_the_selection() {
        let mut model = model(Layout { sessions: vec![] });
        let next = Snapshot {
            revision: revision(1),
            layout: layout_of(&[vec![(Shape::Leaf, 0)]]),
        };
        let rows = vec![entry(1, &[("a", json!(1))])];
        assert_eq!(model.apply(announced(next.clone(), rows)), Applied::Layout);
        assert_eq!(model.layout, next);
        assert_eq!(vars_in(&model, 1), Some(plain(&[("a", json!(1))])));
        let selection = Selection {
            pane: Some(pane(1)),
            ..Selection::default()
        };
        assert_eq!(
            model.apply(ClientEvent::Selected(selection)),
            Applied::Selected
        );
        assert_eq!(model.selection, selection);
        let title = ClientEvent::Title(protocol::Title {
            pane: pane(1),
            title: "t".to_owned(),
        });
        assert_eq!(model.apply(title), Applied::State);
    }

    #[test]
    fn a_focus_event_moves_the_focus_of_its_window_and_keeps_the_revision() {
        let layout = layout_of(&[vec![(Shape::Leaf, 1), (Shape::Leaf, 0)]]);
        let mut model = model(layout);
        model.layout.revision = revision(4);
        let focus = |window, number| ClientEvent::Focus {
            window: id("window_", window),
            pane: pane(number),
        };
        assert_eq!(model.apply(focus(1, 2)), Applied::Layout);
        let focused: Vec<_> = model
            .layout
            .layout
            .windows()
            .map(|(_, w)| w.focus)
            .collect();
        assert_eq!(focused, [pane(2), pane(3)]);
        assert_eq!(model.layout.revision, revision(4));
        assert_eq!(model.apply(focus(9, 1)), Applied::Nothing);
        let focused: Vec<_> = model
            .layout
            .layout
            .windows()
            .map(|(_, w)| w.focus)
            .collect();
        assert_eq!(focused, [pane(2), pane(3)]);
    }

    #[test]
    fn a_rejoin_resumes_on_the_same_instance_and_starts_fresh_on_another() {
        let mut old = model(Layout { sessions: vec![] });
        let mut same = model(Layout { sessions: vec![] });
        same.client = id("client_", 2);
        let mut other = model(Layout { sessions: vec![] });
        other.instance = Instance::try_from("fedcba9876543210fedcba9876543210".to_owned()).unwrap();
        assert!(
            matches!(old.gate(same), Rejoin::Resume(joined) if joined.client == id("client_", 2))
        );
        assert!(matches!(old.gate(other), Rejoin::Fresh(_)));
    }

    fn plain(vars: &[(&str, Value)]) -> BTreeMap<VarName, Value> {
        vars.iter()
            .map(|(key, value)| (name(key), value.clone()))
            .collect()
    }

    #[test]
    fn variables_arrive_with_their_pane_and_its_events_change_them() {
        let mut model = model(Layout { sessions: vec![] });
        let layout = one_pane_layout(&[1]);
        let rows = vec![entry(
            1,
            &[("a", json!(1)), ("gone", json!(true)), ("b", json!(5))],
        )];
        model.apply(announced(layout, rows));
        model.apply(var(1, "a", json!(2)));
        model.apply(ClientEvent::VarDeleted {
            pane: pane(1),
            name: name("gone"),
        });
        assert_eq!(
            vars_in(&model, 1),
            Some(plain(&[("a", json!(2)), ("b", json!(5))]))
        );
    }

    #[test]
    fn an_outcome_of_a_watched_pane_is_seen_as_it_arrives_and_others_stay_marked() {
        let mut model = model(Layout { sessions: vec![] });
        let layout = one_pane_layout(&[1, 2]);
        model.apply(announced(layout, vec![entry(1, &[]), entry(2, &[])]));
        assert!(!model.observe(&[pane(1)], true), "no mark changed");
        let failed = |number| {
            ClientEvent::Status(
                serde_json::from_value(json!({
                    "pane": pane(number), "now": 2000, "status": {
                        "kind": {"type": "terminal", "phase": {"type": "idle", "last":
                            {"code": 1, "command": "false", "started_at": 1500, "ended_at": 1600}}},
                        "program_status": {"serial": 0, "records": []},
                        "title": "zsh", "since": 0}
                }))
                .unwrap(),
            )
        };
        model.apply(failed(1));
        model.apply(failed(2));
        let marks: Vec<Mark> = model.panes.iter().map(|found| model.mark(found)).collect();
        assert_eq!(marks, [Mark::None, Mark::Failed]);
        assert!(
            model.observe(&[pane(2)], true),
            "showing pane 2 acknowledges its failure"
        );
    }

    #[test]
    fn each_row_field_that_changes_has_its_event() {
        let mut model = model(Layout { sessions: vec![] });
        model.apply(announced(one_pane_layout(&[1]), vec![entry(1, &[])]));
        let dead = Dead {
            at: 1,
            cause: Cause::Exited { code: 0 },
        };
        let events = [
            ClientEvent::Dead(protocol::PaneDead {
                pane: pane(1),
                dead: dead.clone(),
            }),
            ClientEvent::Title(protocol::Title {
                pane: pane(1),
                title: "t".to_owned(),
            }),
            ClientEvent::Pwd(protocol::Pwd {
                pane: pane(1),
                pwd: "/tmp".to_owned(),
            }),
            ClientEvent::Foreground {
                pane: pane(1),
                foreground: protocol::Foreground {
                    pid: 7,
                    name: "vim".to_owned(),
                },
            },
            ClientEvent::Progress {
                pane: pane(1),
                progress: Some(protocol::Progress {
                    state: protocol::ProgressState::Set,
                    progress: Some(40),
                }),
            },
        ];
        for event in events {
            assert_eq!(model.apply(event), Applied::State);
        }
        let row = &model.panes[0].row;
        assert_eq!(
            (
                row.dead.clone(),
                row.title.as_str(),
                row.cwd.as_str(),
                row.foreground.as_ref().map(|f| f.name.as_str()),
                row.progress.and_then(|p| p.progress),
            ),
            (Some(dead), "t", "/tmp", Some("vim"), Some(40))
        );
    }

    #[test]
    fn a_layout_event_adds_the_rows_it_carries_and_drops_the_panes_it_no_longer_names() {
        let mut model = model(Layout { sessions: vec![] });
        model.apply(announced(one_pane_layout(&[1]), vec![entry(1, &[])]));
        model.apply(ClientEvent::Title(protocol::Title {
            pane: pane(1),
            title: "t".to_owned(),
        }));
        model.apply(announced(
            one_pane_layout(&[1, 2]),
            vec![entry(2, &[("x", json!(1))])],
        ));
        let titles: Vec<_> = model
            .panes
            .iter()
            .map(|found| (found.row.id, found.row.title.clone()))
            .collect();
        assert_eq!(
            titles,
            [(pane(1), "t".to_owned()), (pane(2), String::new())],
            "the old row stays as its events left it"
        );
        model.apply(announced(one_pane_layout(&[1]), Vec::new()));
        assert_eq!(vars_in(&model, 2), None);
        assert_eq!(
            model.apply(var(2, "x", json!(1))),
            Applied::Nothing,
            "an event of a pane the layout lacks does nothing"
        );
        assert_eq!(vars_in(&model, 2), None);
    }

    #[test]
    fn the_server_clock_estimate_starts_at_the_last_now() {
        let model = model(Layout { sessions: vec![] });
        assert!(model.server_now() >= 1_000);
    }

    proptest! {
        #[test]
        fn any_sequence_of_layout_events_leaves_the_outline_consistent(
            sequence in prop::collection::vec(layouts(), 1..6),
            from in any::<prop::sample::Index>(),
            steps in -9isize..9,
        ) {
            let mut model = model(Layout { sessions: vec![] });
            for (n, sessions) in sequence.iter().enumerate() {
                let layout = layout_of(sessions);
                let revision = revision(n as u64 + 1);
                model.apply(announced(
                    Snapshot { revision, layout: layout.clone() },
                    listings_of(&layout),
                ));
                let outline = model.outline();
                let headers = outline
                    .iter()
                    .filter(|item| matches!(item, Item::Session { .. }))
                    .count();
                prop_assert_eq!(headers, layout.sessions.len());
                let starts_with_header = outline
                    .first()
                    .is_none_or(|first| matches!(first, Item::Session { .. }));
                prop_assert!(starts_with_header);
                let order = model.order();
                let mut sorted = order.clone();
                sorted.sort();
                sorted.dedup();
                prop_assert_eq!(sorted.len(), order.len());
                for (session, window) in layout.windows() {
                    for pane in window.panes() {
                        prop_assert_eq!(model.locate(pane), Some((session.id, window.id)));
                    }
                }
                if order.is_empty() {
                    prop_assert_eq!(model.step(None, steps), None);
                } else {
                    let start = order[from.index(order.len())];
                    let moved = model.step(Some(start), steps).unwrap();
                    prop_assert!(order.contains(&moved));
                    let count = isize::try_from(order.len()).unwrap();
                    let back = model.step(Some(moved), -steps).unwrap();
                    prop_assert_eq!(back, start);
                    prop_assert_eq!(model.step(Some(start), count), Some(start));
                }
            }
        }
    }
}

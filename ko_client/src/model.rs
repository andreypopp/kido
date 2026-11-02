use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use ko_pane_wire::frame::Limits;
use ko_server::ids::{ClientId, Instance, PaneId, RunId, SessionId, VarName, WindowId};
use ko_server::protocol::{
    self, ClientEvent, ClientRequest, Hello, Info, Listing, Route, Row, RunEvent, Selection, Show,
    Snapshot, Window,
};
use ko_server::runs::Parent;
use ko_sys::event::Wake;
use serde::Serialize;
use serde_json::Value;

use crate::status::{Mark, Seen};
use crate::tree;
use crate::wire::{self, Link, Next, text};

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
    socket: PathBuf,
    pub client: ClientId,
    pub instance: Instance,
    pub limits: Limits,
    pub layout: Snapshot,
    pub selection: Selection,
    pub panes: Vec<Pane>,
    runs: BTreeMap<RunId, RunEvent>,
    anchor: (u64, Instant),
    seen: Seen,
}

#[derive(Debug)]
pub(crate) struct Fetched {
    listing: Vec<Listing>,
    infos: Vec<Info>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Item {
    Session { id: SessionId, name: String },
    Pane { id: PaneId, depth: usize },
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
    pub fn join(
        link: &mut Link,
        hello: Hello,
        socket: &Path,
        cancel: Option<&Wake>,
    ) -> Result<Model, String> {
        Model::greet(link, hello)?;
        Model::welcome(link, socket, (cancel, wire::READ_TIMEOUT))
    }

    fn greet(link: &mut Link, hello: Hello) -> Result<(), String> {
        link.send(protocol::json(&ClientRequest::Hello(hello)))
            .and_then(|()| link.flush_blocking())
            .map_err(text)
    }

    fn welcome(
        link: &mut Link,
        socket: &Path,
        limits: (Option<&Wake>, Duration),
    ) -> Result<Model, String> {
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
        let mut model = Model::new(welcome, socket.to_owned(), layout);
        model.refresh(limits)?;
        Ok(model)
    }

    fn new(welcome: protocol::Welcome, socket: PathBuf, layout: Snapshot) -> Model {
        Model {
            socket,
            client: welcome.client,
            instance: welcome.instance,
            limits: welcome.limits.terminal.limits(),
            layout,
            selection: Selection::default(),
            panes: Vec::new(),
            runs: BTreeMap::new(),
            anchor: (welcome.now, Instant::now()),
            seen: Seen::new(welcome.now),
        }
    }

    pub fn rejoin(
        &mut self,
        link: &mut Link,
        hello: Hello,
        limits: (Option<&Wake>, Duration),
    ) -> Result<Rejoin, String> {
        Model::greet(link, hello)?;
        let joined = Model::welcome(link, &self.socket, limits)?;
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

    pub fn server_now(&self) -> u64 {
        let elapsed = u64::try_from(self.anchor.1.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.anchor.0.saturating_add(elapsed)
    }

    pub fn observe(&mut self, shown: &[PaneId], attending: bool) {
        self.seen.observe(shown, attending, &self.panes);
    }

    #[cfg(target_vendor = "apple")]
    pub(crate) fn runs(&self) -> impl Iterator<Item = &RunEvent> {
        self.runs.values()
    }

    pub fn mark(&self, pane: &Pane) -> Mark {
        self.seen.mark(pane)
    }

    fn refresh(&mut self, limits: (Option<&Wake>, Duration)) -> Result<(), String> {
        let rows = Model::fetch(&self.socket, self.client, limits)?;
        self.install(rows);
        Ok(())
    }

    pub(crate) fn fetch(
        socket: &Path,
        client: ClientId,
        limits: (Option<&Wake>, Duration),
    ) -> Result<Fetched, String> {
        let body = wire::request_within(socket, Some(client), &Route::ListPanes, b"", limits)?;
        let listing = protocol::decode(&body).map_err(text)?;
        let route = Route::ListRuns(Show::Present, None);
        let body = wire::request_within(socket, Some(client), &route, b"", limits)?;
        Ok(Fetched {
            listing,
            infos: protocol::decode(&body).map_err(text)?,
        })
    }

    pub(crate) fn install(&mut self, fetched: Fetched) {
        self.load(fetched.listing);
        self.load_runs(fetched.infos);
    }

    fn stale(&self) -> bool {
        let known: BTreeSet<PaneId> = self.panes.iter().map(|pane| pane.row.id).collect();
        known != self.order().into_iter().collect()
    }

    fn load_runs(&mut self, infos: Vec<Info>) {
        self.runs = infos
            .into_iter()
            .filter_map(|info| RunEvent::of(&info.meta, info.outcome))
            .map(|event| (event.id.clone(), event))
            .collect();
        self.forget_runs();
    }

    fn forget_runs(&mut self) {
        let in_layout: BTreeSet<PaneId> = self.order().into_iter().collect();
        self.runs.retain(|_, run| in_layout.contains(&run.pane));
    }

    fn parent_of(&self, pane: PaneId) -> Option<PaneId> {
        let run = self.runs.values().find(|run| run.pane == pane)?;
        match run.parent.as_ref()? {
            Parent::Pane(parent) => Some(*parent),
            Parent::Run(id) => self.runs.get(id).map(|parent| parent.pane),
        }
    }

    fn load(&mut self, listing: Vec<Listing>) {
        let in_layout: BTreeSet<PaneId> = self.order().into_iter().collect();
        self.panes = listing
            .into_iter()
            .filter(|entry| in_layout.contains(&entry.row.id))
            .map(|entry| Pane {
                row: entry.row,
                vars: entry.vars.into(),
            })
            .collect();
    }

    fn pane_mut(&mut self, id: PaneId) -> Option<&mut Pane> {
        self.panes.iter_mut().find(|pane| pane.row.id == id)
    }

    pub fn apply(&mut self, event: ClientEvent) -> Result<Applied, String> {
        let (applied, fetch) = self.apply_event(event);
        if fetch {
            self.refresh((None, wire::READ_TIMEOUT))?;
        }
        Ok(applied)
    }

    // The second member says that the rows are stale and `fetch` must run again.
    pub(crate) fn apply_event(&mut self, event: ClientEvent) -> (Applied, bool) {
        let layout = matches!(event, ClientEvent::Layout(_));
        let applied = self.apply_now(event);
        (applied, layout && self.stale())
    }

    fn apply_now(&mut self, event: ClientEvent) -> Applied {
        match event {
            ClientEvent::Layout(layout) => {
                self.layout = layout;
                self.forget_runs();
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
                if self.order().contains(&run.pane) {
                    self.runs.insert(run.id.clone(), run);
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
            ClientEvent::Welcome(_) | ClientEvent::Pwd(_) => {}
        }
        Applied::Nothing
    }

    pub fn outline(&self) -> Vec<Item> {
        let mut items = Vec::new();
        for session in &self.layout.layout.sessions {
            items.push(Item::Session {
                id: session.id,
                name: String::from(session.name.clone()),
            });
            let panes: Vec<PaneId> = session.windows.iter().flat_map(Window::panes).collect();
            items.extend(
                tree::order(panes, |pane| *pane, |pane| self.parent_of(*pane))
                    .into_iter()
                    .map(|(id, depth)| Item::Pane { id, depth }),
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

    use ko_server::ids::Name;
    use ko_server::protocol::{
        Axis, Cause, Cells, Dead, Float, Layout, Leaf, Node, Revision, Session,
    };
    use ko_server::vars::Vars;
    use proptest::prelude::*;
    use serde_json::{Value, json};

    use super::*;

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
        let welcome = serde_json::from_value(json!({
            "client": "client_1",
            "limits": {"terminal": {"scrollback": {"type": "disabled"}, "apc_max_bytes": 0,
                "kitty_images_max_bytes": 0, "continuation_max_bytes": 0}, "media": []},
            "instance": "0123456789abcdef0123456789abcdef",
            "now": 1000
        }))
        .unwrap();
        Model::new(
            welcome,
            PathBuf::from("/nonexistent"),
            Snapshot {
                revision: Revision::FIRST,
                layout,
            },
        )
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
                Item::Pane { id, depth } => format!("{}{id}", " ".repeat(*depth)),
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

    fn run(number: u8, on: u64, parent: Option<Parent>) -> RunEvent {
        RunEvent {
            id: format!("{number:032x}").parse().unwrap(),
            name: ko_server::runs::RunName::new("r").unwrap(),
            parent,
            pane: pane(on),
            started_at: ko_server::timestamp::Timestamp::from_micros(0),
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
                Item::Pane { id, depth } => Some(format!("{depth}{id}")),
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
            assert_eq!(model.apply(ClientEvent::Run(event)), Ok(Applied::State));
        }
        assert_eq!(
            outline_of(&model),
            ["0pane_1", "1pane_3", "2pane_4", "0pane_2", "0pane_5"],
            "a parent in another session leaves the child a root of its own"
        );
        assert_eq!(model.step(Some(pane(1)), 1), Some(pane(3)));
        assert_eq!(model.step(Some(pane(4)), 1), Some(pane(2)));
        let mut without_runs = model.layout.clone();
        without_runs.layout.sessions[0].windows.remove(2);
        model.panes = rows_of(&without_runs.layout);
        assert_eq!(
            model.apply(ClientEvent::Layout(without_runs)),
            Ok(Applied::Layout)
        );
        assert_eq!(
            model.runs.keys().cloned().collect::<Vec<_>>(),
            [run_id(2), run_id(3)],
            "the run of a pane that the layout dropped goes with it"
        );
        assert_eq!(
            model.apply(ClientEvent::Run(run(9, 3, None))),
            Ok(Applied::Nothing)
        );
        assert_eq!(
            model.runs.len(),
            2,
            "a run event for a pane the layout lacks changes nothing"
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
    fn layout_and_selected_events_replace_the_model_and_others_leave_it() {
        let mut model = model(Layout { sessions: vec![] });
        let next = Snapshot {
            revision: revision(1),
            layout: layout_of(&[vec![(Shape::Leaf, 0)]]),
        };
        model.panes = rows_of(&next.layout);
        assert_eq!(
            model.apply(ClientEvent::Layout(next.clone())),
            Ok(Applied::Layout)
        );
        assert_eq!(model.layout, next);
        let selection = Selection {
            pane: Some(pane(1)),
            ..Selection::default()
        };
        assert_eq!(
            model.apply(ClientEvent::Selected(selection)),
            Ok(Applied::Selected)
        );
        assert_eq!(model.selection, selection);
        let title = ClientEvent::Title(protocol::Title {
            pane: pane(1),
            title: "t".to_owned(),
        });
        assert_eq!(model.apply(title), Ok(Applied::State));
    }

    #[test]
    fn a_focus_event_moves_the_focus_of_its_window_and_keeps_the_revision() {
        let layout = layout_of(&[vec![(Shape::Leaf, 1), (Shape::Leaf, 0)]]);
        let mut model = model(layout);
        model.layout.revision = revision(4);
        model.panes = rows_of(&model.layout.layout);
        let focus = |window, number| ClientEvent::Focus {
            window: id("window_", window),
            pane: pane(number),
        };
        assert_eq!(model.apply(focus(1, 2)), Ok(Applied::Layout));
        let focused: Vec<_> = model
            .layout
            .layout
            .windows()
            .map(|(_, w)| w.focus)
            .collect();
        assert_eq!(focused, [pane(2), pane(3)]);
        assert_eq!(model.layout.revision, revision(4));
        assert_eq!(model.apply(focus(9, 1)), Ok(Applied::Nothing));
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
    fn events_applied_after_the_listing_win_over_it() {
        let mut model = model(one_pane_layout(&[1]).layout);
        model.load(vec![entry(
            1,
            &[("a", json!(1)), ("gone", json!(true)), ("b", json!(5))],
        )]);
        model.apply(var(1, "a", json!(2))).unwrap();
        model
            .apply(ClientEvent::VarDeleted {
                pane: pane(1),
                name: name("gone"),
            })
            .unwrap();
        assert_eq!(
            vars_in(&model, 1),
            Some(plain(&[("a", json!(2)), ("b", json!(5))]))
        );
    }

    #[test]
    fn queued_events_older_than_the_listing_never_drop_a_variable() {
        let mut model = model(one_pane_layout(&[1]).layout);
        let filler: Vec<(String, Value)> = (0..1022).map(|n| (format!("f{n}"), json!(n))).collect();
        let mut vars: Vec<(&str, Value)> = filler
            .iter()
            .map(|(key, value)| (key.as_str(), value.clone()))
            .collect();
        vars.extend([("A", json!(1)), ("B", json!(2))]);
        model.load(vec![entry(1, &vars)]);
        for event in [
            ClientEvent::VarDeleted {
                pane: pane(1),
                name: name("A"),
            },
            var(1, "C", json!(3)),
            var(1, "A", json!(1)),
            ClientEvent::VarDeleted {
                pane: pane(1),
                name: name("C"),
            },
            var(1, "B", json!(2)),
        ] {
            model.apply(event).unwrap();
        }
        let found = vars_in(&model, 1).unwrap();
        assert_eq!(found.len(), 1024);
        assert_eq!(found.get(&name("A")), Some(&json!(1)));
        assert_eq!(found.get(&name("B")), Some(&json!(2)));
    }

    #[test]
    fn a_dead_event_after_the_listing_marks_the_pane_dead() {
        let mut model = model(one_pane_layout(&[1]).layout);
        model.load(vec![entry(1, &[])]);
        let dead = Dead {
            at: 1,
            cause: Cause::Exited { code: 0 },
        };
        model
            .apply(ClientEvent::Dead(protocol::PaneDead {
                pane: pane(1),
                dead: dead.clone(),
            }))
            .unwrap();
        assert_eq!(model.panes[0].row.dead, Some(dead));
    }

    #[test]
    fn a_listing_drops_the_pane_the_layout_no_longer_has_and_its_events_do_nothing() {
        let mut model = model(one_pane_layout(&[1]).layout);
        model.load(vec![entry(1, &[]), entry(2, &[("x", json!(1))])]);
        assert_eq!(vars_in(&model, 2), None);
        model.apply(var(2, "x", json!(1))).unwrap();
        assert_eq!(vars_in(&model, 2), None);
        assert_eq!(vars_in(&model, 1), Some(BTreeMap::new()));
    }

    #[test]
    fn a_layout_event_with_another_pane_set_reads_the_listing_again() {
        let mut model = model(one_pane_layout(&[1]).layout);
        model.load(vec![entry(1, &[])]);
        let same = ClientEvent::Layout(one_pane_layout(&[1]));
        assert_eq!(model.apply(same), Ok(Applied::Layout));
        let more = ClientEvent::Layout(one_pane_layout(&[1, 2]));
        assert!(
            model.apply(more).is_err(),
            "the unreachable socket shows the read"
        );
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
                model.panes = rows_of(&layout);
                model
                    .apply(ClientEvent::Layout(Snapshot { revision, layout: layout.clone() }))
                    .unwrap();
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

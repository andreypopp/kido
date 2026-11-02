use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use ko_pane_wire::frame::Limits;
use ko_server::ids::{ClientId, Instance, PaneId, SessionId, WindowId};
use ko_server::protocol::{self, ClientEvent, Route, Row, Selection, Snapshot};

use crate::wire::{self, Link, Next, text};

#[derive(Debug)]
pub struct Model {
    socket: PathBuf,
    pub client: ClientId,
    pub instance: Instance,
    pub limits: Limits,
    pub layout: Snapshot,
    pub selection: Selection,
    pub panes: Vec<Row>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Item {
    Session { id: SessionId, name: String },
    Pane(PaneId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    Nothing,
    Layout,
    Selected,
}

#[derive(Debug)]
pub enum Rejoin {
    Resume(Model),
    Fresh(Model),
}

impl Model {
    pub fn welcome(link: &mut Link, socket: &Path) -> Result<Model, String> {
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
        let mut model = Model {
            socket: socket.to_owned(),
            client: welcome.client,
            instance: welcome.instance,
            limits: welcome.limits.terminal.limits(),
            layout,
            selection: Selection::default(),
            panes: Vec::new(),
        };
        model.refresh()?;
        Ok(model)
    }

    pub fn rejoin(&self, link: &mut Link) -> Result<Rejoin, String> {
        Ok(self.gate(Model::welcome(link, &self.socket)?))
    }

    fn refresh(&mut self) -> Result<(), String> {
        let body = wire::request(&self.socket, Some(self.client), &Route::ListPanes, b"")?;
        self.panes = protocol::decode(&body).map_err(text)?;
        Ok(())
    }

    fn gate(&self, joined: Model) -> Rejoin {
        if joined.instance == self.instance {
            Rejoin::Resume(joined)
        } else {
            Rejoin::Fresh(joined)
        }
    }

    pub fn apply(&mut self, event: ClientEvent) -> Result<Applied, String> {
        match event {
            ClientEvent::Layout(layout) => {
                self.layout = layout;
                let known: BTreeSet<PaneId> = self.panes.iter().map(|row| row.id).collect();
                if known != self.order().into_iter().collect() {
                    self.refresh()?;
                }
                return Ok(Applied::Layout);
            }
            ClientEvent::Selected(selection) => {
                self.selection = selection;
                return Ok(Applied::Selected);
            }
            ClientEvent::Title(title) => {
                for row in self.panes.iter_mut().filter(|row| row.id == title.pane) {
                    row.title.clone_from(&title.title);
                }
            }
            ClientEvent::Dead(dead) => {
                for row in self.panes.iter_mut().filter(|row| row.id == dead.pane) {
                    row.dead = Some(dead.dead.clone());
                }
            }
            ClientEvent::Welcome(_) | ClientEvent::Pwd(_) => {}
        }
        Ok(Applied::Nothing)
    }

    pub fn outline(&self) -> Vec<Item> {
        let mut items = Vec::new();
        for session in &self.layout.layout.sessions {
            items.push(Item::Session {
                id: session.id,
                name: String::from(session.name.clone()),
            });
            for window in &session.windows {
                items.extend(window.panes().into_iter().map(Item::Pane));
            }
        }
        items
    }

    pub fn order(&self) -> Vec<PaneId> {
        self.outline()
            .into_iter()
            .filter_map(|item| match item {
                Item::Pane(pane) => Some(pane),
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

    use ko_pane_wire::frame::{Limits, Scrollback};
    use ko_server::protocol::{
        Axis, Cells, Float, Layout, Leaf, Name, Node, Revision, Session, Window,
    };
    use proptest::prelude::*;

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
                    vars: BTreeMap::new(),
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
                            Window {
                                id: id("window_", window),
                                name: name(),
                                vars: BTreeMap::new(),
                                cols: cells(),
                                rows: cells(),
                                cell_px: None,
                                zoom: None,
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
        Model {
            socket: PathBuf::from("/nonexistent"),
            client: id("client_", 1),
            instance: Instance::try_from("0123456789abcdef0123456789abcdef".to_owned()).unwrap(),
            limits: Limits {
                scrollback: Scrollback::Disabled,
                apc_max_bytes: 0,
                kitty_images_max_bytes: 0,
                continuation_max_bytes: 0,
            },
            layout: Snapshot {
                revision: Revision::FIRST,
                layout,
            },
            selection: Selection::default(),
            panes: Vec::new(),
        }
    }

    fn revision(number: u64) -> Revision {
        protocol::decode(number.to_string().as_bytes()).unwrap()
    }

    fn rows_of(layout: &Layout) -> Vec<Row> {
        layout
            .windows()
            .flat_map(|(_, window)| window.panes())
            .map(|id| Row {
                id,
                pid: 1,
                command: Vec::new(),
                cwd: String::new(),
                title: String::new(),
                dead: None,
            })
            .collect()
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
                Item::Pane(pane) => pane.to_string(),
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
        assert_eq!(model.apply(title), Ok(Applied::Nothing));
    }

    #[test]
    fn a_rejoin_resumes_on_the_same_instance_and_starts_fresh_on_another() {
        let old = model(Layout { sessions: vec![] });
        let mut same = model(Layout { sessions: vec![] });
        same.client = id("client_", 2);
        let mut other = model(Layout { sessions: vec![] });
        other.instance = Instance::try_from("fedcba9876543210fedcba9876543210".to_owned()).unwrap();
        assert!(
            matches!(old.gate(same), Rejoin::Resume(joined) if joined.client == id("client_", 2))
        );
        assert!(matches!(old.gate(other), Rejoin::Fresh(_)));
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

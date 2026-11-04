use std::collections::BTreeMap;

use ko_pane_wire::frame::Size;

use crate::ids::{ClientId, PaneId, SessionId, WindowId};
use crate::layout::nearest;
use crate::protocol::{ClientRequest, ClipboardServed, Direction, Layout, Over, Selection, Switch};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Current {
    pub(crate) session: SessionId,
    pub(crate) window: WindowId,
    pub(crate) pane: PaneId,
}

impl From<Current> for Selection {
    fn from(current: Current) -> Selection {
        Selection {
            session: Some(current.session),
            window: Some(current.window),
            pane: Some(current.pane),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Active {
    pub(crate) current: Option<Current>,
    pub(crate) size: Size,
    pub(crate) focused: bool,
    ignore_size: bool,
}

#[derive(Debug)]
pub(crate) struct Client {
    pub(crate) id: ClientId,
    pub(crate) active: Option<Active>,
    last_windows: BTreeMap<SessionId, WindowId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Change {
    Hello(Selection),
    Select(Selection),
    Switch(Switch),
    Claim,
    Resize,
    Nothing,
    Answer {
        id: u64,
        served: Option<ClipboardServed>,
    },
}

pub(crate) fn new_window_sizer<'a>(actives: impl Iterator<Item = &'a Active>) -> Option<Size> {
    actives
        .filter(|active| !active.ignore_size)
        .min_by_key(|active| !active.focused)
        .map(|active| active.size)
}

pub(crate) fn claims<'a>(
    client: ClientId,
    active: &Active,
    others: impl IntoIterator<Item = (ClientId, &'a Active)>,
) -> bool {
    let window = active.current.map(|current| current.window);
    let focused_elsewhere = others.into_iter().any(|(id, peer)| {
        id != client
            && peer.focused
            && !peer.ignore_size
            && peer.current.map(|current| current.window) == window
    });
    window.is_some() && !active.ignore_size && (active.focused || !focused_elsewhere)
}

fn step(count: usize, from: Option<usize>, direction: Direction) -> usize {
    match (direction, from) {
        (Direction::Next, Some(at)) => (at + 1) % count,
        (Direction::Next, None) => 0,
        (Direction::Previous, Some(at)) => (at + count - 1) % count,
        (Direction::Previous, None) => count - 1,
    }
}

impl Client {
    pub(crate) fn new(id: ClientId) -> Client {
        Client {
            id,
            active: None,
            last_windows: BTreeMap::new(),
        }
    }

    pub(crate) fn receive(&mut self, request: ClientRequest) -> Result<Change, &'static str> {
        match (&mut self.active, request) {
            (None, ClientRequest::Hello(hello)) => {
                self.active = Some(Active {
                    current: None,
                    size: hello.size.0,
                    focused: hello.focused,
                    ignore_size: hello.ignore_size,
                });
                Ok(Change::Hello(hello.selection))
            }
            (None, _) => Err("hello must be first"),
            (Some(_), ClientRequest::Select(selection)) if selection == Selection::default() => {
                Err("nothing to select")
            }
            (Some(_), ClientRequest::Select(selection)) => Ok(Change::Select(selection)),
            (Some(_), ClientRequest::Switch(switch)) => Ok(Change::Switch(switch)),
            (Some(active), ClientRequest::Size(size)) => {
                active.size = size.0;
                Ok(Change::Resize)
            }
            (Some(active), ClientRequest::Focused { focused }) => {
                active.focused = focused;
                Ok(if focused {
                    Change::Claim
                } else {
                    Change::Nothing
                })
            }
            (Some(_), ClientRequest::ClipboardAnswer { id, served }) => {
                Ok(Change::Answer { id, served })
            }
            (Some(_), ClientRequest::Hello(_)) => Err("hello already received"),
        }
    }

    pub(crate) fn current(&self) -> Option<Current> {
        self.active.and_then(|active| active.current)
    }

    pub(crate) fn set_current(&mut self, current: Option<Current>) {
        if let Some(active) = &mut self.active {
            active.current = current;
        }
        if let Some(current) = current {
            self.last_windows.insert(current.session, current.window);
        }
    }

    pub(crate) fn select(&self, layout: &Layout, selection: Selection) -> Option<Current> {
        if let Some(pane) = selection.pane {
            let (session, window) = layout.locate(pane)?;
            return Some(Current {
                session: session.id,
                window: window.id,
                pane,
            });
        }
        let (session, window) = match (selection.window, selection.session) {
            (Some(window), _) => layout.window(window)?,
            (None, Some(session)) => {
                let session = layout.session(session)?;
                let window = self
                    .last_windows
                    .get(&session.id)
                    .and_then(|last| session.windows.iter().find(|window| window.id == *last))
                    .or_else(|| session.windows.first())?;
                (session, window)
            }
            (None, None) => return None,
        };
        Some(Current {
            session: session.id,
            window: window.id,
            pane: window.focus,
        })
    }

    pub(crate) fn switch(&self, layout: &Layout, switch: Switch) -> Option<Current> {
        let current = self.current();
        let selection = match switch.over {
            Over::Window => {
                let windows: Vec<WindowId> =
                    layout.windows().map(|(_, window)| window.id).collect();
                let from = current.and_then(|c| windows.iter().position(|w| *w == c.window));
                if windows.is_empty() {
                    return None;
                }
                let at = step(windows.len(), from, switch.direction);
                Selection {
                    window: Some(windows[at]),
                    ..Selection::default()
                }
            }
            Over::Session => {
                let from = current.and_then(|c| {
                    layout
                        .sessions
                        .iter()
                        .position(|session| session.id == c.session)
                });
                if layout.sessions.is_empty() {
                    return None;
                }
                let at = step(layout.sessions.len(), from, switch.direction);
                Selection {
                    session: Some(layout.sessions[at].id),
                    ..Selection::default()
                }
            }
        };
        self.select(layout, selection)
    }

    pub(crate) fn reconcile(&self, before: &Layout, layout: &Layout) -> Option<Current> {
        let current = self.current()?;
        let named = |selection| self.select(layout, selection);
        named(Selection {
            pane: Some(current.pane),
            ..Selection::default()
        })
        .or_else(|| {
            named(Selection {
                window: Some(current.window),
                ..Selection::default()
            })
        })
        .or_else(|| {
            let order: Vec<WindowId> = before.windows().map(|(_, window)| window.id).collect();
            let at = order.iter().position(|window| *window == current.window)?;
            let survivor = nearest(&order, at, |window| layout.window(*window).is_some())?;
            named(Selection {
                window: Some(survivor),
                ..Selection::default()
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::layout::Document;

    fn leaf() -> serde_json::Value {
        json!({"pane": {"new": {}}})
    }

    fn pair(a: serde_json::Value, b: serde_json::Value) -> serde_json::Value {
        json!({"split": "h", "children": [a, b]})
    }

    fn document(sessions: serde_json::Value) -> Document {
        let mut document = Document::empty();
        document
            .put(
                serde_json::from_value(json!({"revision": 0, "layout": {"sessions": sessions}}))
                    .unwrap(),
                None,
            )
            .unwrap();
        document.publish();
        document
    }

    fn three_documents() -> Document {
        document(json!([
            {"name": "a", "windows": [
                {"name": "w1", "tree": pair(leaf(), leaf())},
                {"name": "w2", "tree": leaf()}]},
            {"name": "b", "windows": [{"name": "w3", "tree": leaf()}]},
        ]))
    }

    fn three() -> Layout {
        three_documents().layout().clone()
    }

    fn without(document: &Document, panes: &[u64]) -> Layout {
        let mut document = document.clone();
        for pane in panes {
            document.remove_pane(PaneId::new(*pane));
        }
        document.layout().clone()
    }

    fn current(session: u64, window: u64, pane: u64) -> Current {
        Current {
            session: SessionId::new(session),
            window: WindowId::new(window),
            pane: PaneId::new(pane),
        }
    }

    fn selection(session: Option<u64>, window: Option<u64>, pane: Option<u64>) -> Selection {
        Selection {
            session: session.map(SessionId::new),
            window: window.map(WindowId::new),
            pane: pane.map(PaneId::new),
        }
    }

    fn at(current: Current) -> Client {
        let mut client = Client::new(ClientId::new(1));
        client.active = Some(Active {
            current: None,
            size: Size::DEFAULT,
            focused: false,
            ignore_size: false,
        });
        client.set_current(Some(current));
        client
    }

    #[test]
    fn a_pane_implies_its_window_a_window_its_last_focused_pane_a_session_its_last_window() {
        let mut source = three_documents();
        let client = Client::new(ClientId::new(1));
        let select = |client: &Client, source: &Document, s| client.select(source.layout(), s);
        assert_eq!(
            select(&client, &source, selection(None, None, Some(2))),
            Some(current(1, 1, 2))
        );
        assert_eq!(
            select(&client, &source, selection(Some(2), None, Some(1))),
            Some(current(1, 1, 1))
        );
        assert_eq!(
            select(&client, &source, selection(None, Some(1), None)),
            Some(current(1, 1, 1))
        );
        assert!(source.focus(WindowId::new(1), PaneId::new(2)));
        assert_eq!(
            select(&client, &source, selection(None, Some(1), None)),
            Some(current(1, 1, 2))
        );
        assert_eq!(
            select(&client, &source, selection(Some(1), None, None)),
            Some(current(1, 1, 2))
        );
        assert_eq!(
            select(&client, &source, selection(Some(2), None, None)),
            Some(current(2, 3, 4))
        );
        for missing in [
            selection(None, None, Some(9)),
            selection(None, Some(9), None),
            selection(Some(9), None, None),
            Selection::default(),
        ] {
            assert_eq!(select(&client, &source, missing), None);
        }
        let in_second = at(current(1, 2, 3));
        assert_eq!(
            in_second.select(source.layout(), selection(Some(1), None, None)),
            Some(current(1, 2, 3))
        );
    }

    #[test]
    fn a_switch_moves_in_document_order_wraps_and_starts_at_either_end() {
        let layout = three();
        let switch = |over, direction| Switch { over, direction };
        let windows = |from: Option<Current>, direction| {
            let mut client = Client::new(ClientId::new(1));
            client.active = at(current(1, 1, 1)).active;
            client.set_current(from);
            client
                .switch(&layout, switch(Over::Window, direction))
                .map(|c| c.window.to_string())
        };
        assert_eq!(
            windows(Some(current(1, 1, 1)), Direction::Next).as_deref(),
            Some("window_2")
        );
        assert_eq!(
            windows(Some(current(2, 3, 4)), Direction::Next).as_deref(),
            Some("window_1")
        );
        assert_eq!(
            windows(Some(current(1, 1, 1)), Direction::Previous).as_deref(),
            Some("window_3")
        );
        assert_eq!(windows(None, Direction::Next).as_deref(), Some("window_1"));
        assert_eq!(
            windows(None, Direction::Previous).as_deref(),
            Some("window_3")
        );
        let client = at(current(1, 2, 3));
        assert_eq!(
            client.switch(&layout, switch(Over::Session, Direction::Next)),
            Some(current(2, 3, 4))
        );
        assert_eq!(
            client.switch(&layout, switch(Over::Session, Direction::Previous)),
            Some(current(2, 3, 4))
        );
        assert_eq!(
            at(current(1, 1, 1)).switch(
                &Layout { sessions: vec![] },
                switch(Over::Window, Direction::Next)
            ),
            None
        );
    }

    #[test]
    fn when_the_current_pane_or_window_goes_the_client_gets_the_next_one_in_document_order() {
        let source = three_documents();
        let before = source.layout().clone();
        let reconcile = |after: &Layout, from| at(from).reconcile(&before, after);
        let after_1 = without(&source, &[1]);
        assert_eq!(
            reconcile(&after_1, current(1, 1, 1)),
            Some(current(1, 1, 2))
        );
        let after_3 = without(&source, &[3]);
        assert_eq!(
            reconcile(&after_3, current(1, 2, 3)),
            Some(current(2, 3, 4))
        );
        let after_4 = without(&source, &[4]);
        assert_eq!(
            reconcile(&after_4, current(2, 3, 4)),
            Some(current(1, 2, 3))
        );
        let empty = without(&source, &[1, 2, 3, 4]);
        assert_eq!(reconcile(&empty, current(1, 1, 1)), None);
        assert_eq!(reconcile(&before, current(1, 1, 2)), Some(current(1, 1, 2)));
    }

    #[test]
    fn a_pane_that_moves_to_another_window_takes_the_client_with_it() {
        let mut source = three_documents();
        let before = source.layout().clone();
        let mut edited = serde_json::to_value(&before).unwrap();
        edited["sessions"][0]["windows"][0]["tree"] = json!({"pane": "pane_2"});
        edited["sessions"][1]["windows"][0]["tree"] =
            pair(json!({"pane": "pane_4"}), json!({"pane": "pane_1"}));
        source
            .put(
                serde_json::from_value(json!({"revision": 1, "layout": edited})).unwrap(),
                None,
            )
            .unwrap();
        assert_eq!(
            at(current(1, 1, 1)).reconcile(&before, source.layout()),
            Some(current(2, 3, 1))
        );
    }

    #[test]
    fn a_window_is_claimed_by_a_focused_client_or_by_one_that_no_focused_client_shares_it_with() {
        let mine = at(current(1, 1, 1)).active.unwrap();
        let peer = |window: u64, focused, ignore_size| Active {
            current: Some(current(1, window, 1)),
            focused,
            ignore_size,
            ..mine
        };
        let me = ClientId::new(1);
        let others = [(ClientId::new(2), peer(1, true, false))];
        let claims = |active: &Active, others: &[(ClientId, Active)]| {
            claims(me, active, others.iter().map(|(id, peer)| (*id, peer)))
        };
        assert!(!claims(&mine, &others));
        assert!(claims(
            &Active {
                focused: true,
                ..mine
            },
            &others
        ));
        assert!(claims(&mine, &[(ClientId::new(2), peer(2, true, false))]));
        assert!(claims(&mine, &[(ClientId::new(2), peer(1, true, true))]));
        assert!(claims(&mine, &[(ClientId::new(2), peer(1, false, false))]));
        assert!(!claims(
            &Active {
                ignore_size: true,
                ..mine
            },
            &[]
        ));
        assert!(!claims(
            &Active {
                current: None,
                ..mine
            },
            &[]
        ));
    }

    #[test]
    fn a_request_before_the_hello_and_an_empty_selection_are_refused() {
        let mut client = Client::new(ClientId::new(1));
        let select = |selection: &str| -> ClientRequest {
            serde_json::from_str(&format!(r#"{{"type":"select"{selection}}}"#)).unwrap()
        };
        assert_eq!(
            client.receive(select(r#","pane":"pane_1""#)),
            Err("hello must be first")
        );
        let hello: ClientRequest = serde_json::from_str(
            r#"{"type":"hello","name":"t","window":"window_2","focused":false,"size":{"cols":8,"rows":8}}"#,
        )
        .unwrap();
        assert_eq!(
            client.receive(hello.clone()),
            Ok(Change::Hello(selection(None, Some(2), None)))
        );
        assert_eq!(client.receive(hello), Err("hello already received"));
        assert_eq!(client.receive(select("")), Err("nothing to select"));
        assert_eq!(
            client.receive(select(r#","session":"session_1""#)),
            Ok(Change::Select(selection(Some(1), None, None)))
        );
    }
}

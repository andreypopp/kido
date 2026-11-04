use std::path::Path;

use ko_server::api::Route;
use ko_server::ids::{Name, PaneId, SessionId, WindowId};
use ko_server::protocol::{
    self, CreatePane, DraftLayout, LayoutPanes, Node, PutLayout, Revision, Snapshot,
};
use ko_sys::event::Wake;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::fmt::Display;

use crate::edit::{Edit, Refusal, apply};
use crate::wire::{self, Rejected, Who, text};

const ATTEMPTS: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Document {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<Revision>,
    pub layout: DraftLayout,
}

pub(crate) type Put = Result<Snapshot, Snapshot>;

// What an edit made: the outermost of a new session, window or pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Created {
    Session { session: SessionId },
    Window { window: WindowId },
    Pane { pane: PaneId },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
pub struct Edited {
    pub snapshot: Snapshot,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created: Option<Created>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditError {
    Refused(Refusal),
    Rejected(Rejected),
    Exhausted,
}

impl Display for EditError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EditError::Refused(refusal) => refusal.fmt(formatter),
            EditError::Rejected(rejected) => rejected.fmt(formatter),
            EditError::Exhausted => formatter.write_str("the layout kept changing"),
        }
    }
}

fn decoded<T: Serialize + serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, Rejected> {
    protocol::decode(body).map_err(|error| Rejected::Io(text(error)))
}

fn fetch(socket: &Path, who: Who, cancel: Option<&Wake>) -> Result<Snapshot, Rejected> {
    decoded::<LayoutPanes>(&wire::request(
        socket,
        who,
        &Route::GetLayout {},
        b"",
        cancel,
    )?)
    .map(|layout| layout.snapshot)
}

pub(crate) fn send(
    socket: &Path,
    who: Who,
    revision: Revision,
    layout: DraftLayout,
    cancel: Option<&Wake>,
) -> Result<Put, Rejected> {
    let request = PutLayout { revision, layout };
    let (method, target) = Route::PutLayout {}.to_request();
    let response = wire::exchange(
        socket,
        who,
        (method, &target),
        &[],
        protocol::json(&request).as_bytes(),
        wire::READ_TIMEOUT,
        cancel,
    )?;
    match response.status {
        200 => Ok(Ok(decoded(&response.body)?)),
        409 => Ok(Err(decoded(&response.body)?)),
        status => Err(Rejected::Status {
            status,
            reason: response.reason,
            body: response.body,
        }),
    }
}

fn created(draft: &DraftLayout, done: &Snapshot) -> Option<Created> {
    let layout = &done.layout;
    let drafted = || draft.sessions.iter().flat_map(|session| &session.windows);
    let session = layout
        .sessions
        .iter()
        .map(|session| session.id)
        .find(|id| !draft.sessions.iter().any(|known| known.id == Some(*id)));
    let window = || {
        layout
            .windows()
            .map(|(_, window)| window.id)
            .find(|id| !drafted().any(|known| known.id == Some(*id)))
    };
    let pane = || {
        layout
            .windows()
            .flat_map(|(_, window)| window.panes())
            .find(|id| draft.locate(*id).is_none())
    };
    session
        .map(|session| Created::Session { session })
        .or_else(|| window().map(|window| Created::Window { window }))
        .or_else(|| pane().map(|pane| Created::Pane { pane }))
}

// Applies the edit to `first`, and again to each newer document that a conflict returns.
pub(crate) fn edit_from(
    first: Snapshot,
    edit: &Edit,
    mut put: impl FnMut(Revision, DraftLayout) -> Result<Put, Rejected>,
) -> Result<Edited, EditError> {
    let mut current = first;
    for _ in 0..ATTEMPTS {
        let mut layout = DraftLayout::from(&current.layout);
        apply(&mut layout, edit).map_err(EditError::Refused)?;
        match put(current.revision, layout.clone()).map_err(EditError::Rejected)? {
            Ok(done) => {
                return Ok(Edited {
                    created: created(&layout, &done),
                    snapshot: done,
                });
            }
            Err(newer) => current = newer,
        }
    }
    Err(EditError::Exhausted)
}

pub fn edit(socket: &Path, who: Who, edit: &Edit) -> Result<Edited, EditError> {
    let first = fetch(socket, who.clone(), None).map_err(EditError::Rejected)?;
    edit_from(first, edit, |revision, layout| {
        send(socket, who.clone(), revision, layout, None)
    })
}

pub(crate) fn replace(
    socket: &Path,
    who: Who,
    document: &Document,
    cancel: Option<&Wake>,
) -> Result<Snapshot, String> {
    let mut revision = match document.revision {
        Some(revision) => revision,
        None => fetch(socket, who.clone(), cancel)?.revision,
    };
    for _ in 0..ATTEMPTS {
        match send(
            socket,
            who.clone(),
            revision,
            document.layout.clone(),
            cancel,
        )? {
            Ok(done) => return Ok(done),
            Err(newer) => revision = newer.revision,
        }
    }
    Err(EditError::Exhausted.to_string())
}

fn ko_name() -> Result<Name, String> {
    Name::try_from("ko".to_owned()).map_err(str::to_owned)
}

// The one pane of the session or window that the edit made.
fn single(edited: &Edited) -> Result<PaneId, String> {
    let layout = &edited.snapshot.layout;
    let window = match edited.created {
        Some(Created::Session { session }) => layout
            .session(session)
            .and_then(|session| session.windows.first()),
        Some(Created::Window { window }) => layout.window(window).map(|(_, window)| window),
        Some(Created::Pane { .. }) | None => None,
    };
    match window.map(|window| &window.tree) {
        Some(Node::Leaf(leaf)) => Ok(leaf.pane),
        _ => Err("the new pane is missing from the layout".to_owned()),
    }
}

pub fn add_session(socket: &Path, who: Who, request: &CreatePane) -> Result<PaneId, String> {
    let edit = Edit::AddSession {
        name: ko_name()?,
        new: request.clone(),
    };
    single(&self::edit(socket, who, &edit).map_err(|error| error.to_string())?)
}

pub fn add_window(
    socket: &Path,
    who: Who,
    (session, after): (SessionId, WindowId),
    request: &CreatePane,
) -> Result<PaneId, String> {
    let edit = Edit::AddWindow {
        session,
        after,
        new: request.clone(),
    };
    single(&self::edit(socket, who, &edit).map_err(|error| error.to_string())?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit::Edge;
    use ko_server::protocol::{Axis, Cells};

    fn busy(revision: u64, extra: bool) -> Snapshot {
        let more = if extra {
            r#",{"id":"session_2","name":"other","vars":{},"windows":[{"id":"window_3","name":"w","vars":{},"cols":80,"rows":24,"focus":"pane_5","tree":{"pane":"pane_5","cols":80,"rows":24},"floats":[]}]}"#
        } else {
            ""
        };
        let text = format!(
            r#"{{"revision":{revision},"layout":{{"sessions":[{{"id":"session_1","name":"main","vars":{{}},"windows":[{{"id":"window_1","name":"a","vars":{{}},"cols":80,"rows":24,"focus":"pane_1","tree":{{"split":"h","children":[{{"pane":"pane_1","cols":40,"rows":24}},{{"pane":"pane_2","cols":39,"rows":24}}]}},"floats":[{{"pane":"pane_4","x":1,"y":1,"cols":10,"rows":5,"z":1,"border":false,"title":""}}]}},{{"id":"window_2","name":"b","vars":{{}},"cols":80,"rows":24,"focus":"pane_3","tree":{{"pane":"pane_3","cols":80,"rows":24}},"floats":[]}}]}}{more}]}}}}"#
        );
        protocol::decode(text.as_bytes()).unwrap()
    }

    fn pane(number: u64) -> PaneId {
        format!("pane_{number}").parse().unwrap()
    }

    #[test]
    fn every_kind_of_edit_is_applied_again_to_the_newer_document_after_a_conflict() {
        let name = |text: &str| Name::try_from(text.to_owned()).unwrap();
        let created = || CreatePane {
            cwd: None,
            command: None,
            env: Vec::new(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
            runtime: None,
        };
        let edge = Edge::Right;
        let cells = |count| Cells::new(count).unwrap();
        let edits = [
            Edit::Split {
                pane: pane(2),
                axis: Axis::Vertical,
                before: false,
                new: created(),
            },
            Edit::ResizeBy {
                pane: pane(1),
                edge,
                delta: cells(3),
            },
            Edit::ResizePair {
                first: pane(1),
                second: pane(2),
                first_size: cells(10),
            },
            Edit::Equalize { pane: pane(1) },
            Edit::Zoom {
                window: "window_1".parse().unwrap(),
                pane: Some(pane(2)),
            },
            Edit::ToggleZoom { pane: pane(2) },
            Edit::Swap {
                pane: pane(1),
                other: pane(3),
            },
            Edit::Dock {
                pane: pane(3),
                target: pane(1),
                edge,
            },
            Edit::DockWindow {
                pane: pane(3),
                window: "window_1".parse().unwrap(),
                edge,
            },
            Edit::Float {
                pane: pane(4),
                x: Some(7),
                y: None,
                cols: None,
                rows: None,
                z: Some(3),
                border: None,
                title: None,
            },
            Edit::Unfloat {
                pane: pane(4),
                target: pane(2),
                edge,
            },
            Edit::AddWindow {
                session: "session_1".parse().unwrap(),
                after: "window_1".parse().unwrap(),
                new: created(),
            },
            Edit::AddSession {
                name: name("fresh"),
                new: created(),
            },
            Edit::RenameSession {
                session: "session_1".parse().unwrap(),
                name: name("renamed"),
            },
            Edit::RenameWindow {
                window: "window_2".parse().unwrap(),
                name: name("renamed"),
            },
            Edit::ReorderSessions {
                order: vec!["session_2".parse().unwrap()],
            },
            Edit::ReorderWindows {
                session: "session_1".parse().unwrap(),
                order: vec!["window_2".parse().unwrap()],
            },
        ];
        for edit in edits {
            let mut sent = Vec::new();
            let done = edit_from(busy(1, false), &edit, |revision, layout| {
                sent.push((revision, layout));
                Ok(if sent.len() == 1 {
                    Err(busy(2, true))
                } else {
                    Ok(busy(3, true))
                })
            })
            .unwrap();
            let expected = |snapshot: &Snapshot| {
                let mut layout = DraftLayout::from(&snapshot.layout);
                apply(&mut layout, &edit).unwrap();
                layout
            };
            assert_eq!(sent.len(), 2, "{edit:?}");
            assert_eq!(
                sent[0],
                (busy(1, false).revision, expected(&busy(1, false))),
                "{edit:?}"
            );
            assert_eq!(
                sent[1],
                (busy(2, true).revision, expected(&busy(2, true))),
                "{edit:?}"
            );
            assert_eq!(done.snapshot.revision, busy(3, true).revision);
            assert!(
                sent[1].1.sessions.len()
                    > sent[0].1.sessions.len()
                        - usize::from(matches!(edit, Edit::AddSession { .. })),
                "{edit:?}"
            );
        }
    }

    #[test]
    fn an_edit_whose_target_vanished_with_the_newer_document_stops_with_the_id() {
        let edit = Edit::RenameSession {
            session: "session_2".parse().unwrap(),
            name: Name::try_from("x".to_owned()).unwrap(),
        };
        let failed = edit_from(busy(1, true), &edit, |_, _| Ok(Err(busy(2, false))));
        assert_eq!(
            failed.unwrap_err(),
            EditError::Refused(Refusal::Gone("session_2".to_owned()))
        );
    }

    #[test]
    fn a_layout_that_keeps_changing_stops_after_the_attempts() {
        let mut attempts = 0;
        let edit = Edit::Equalize {
            pane: "pane_1".parse().unwrap(),
        };
        let failed = edit_from(busy(1, false), &edit, |_, _| {
            attempts += 1;
            Ok(Err(busy(2, false)))
        });
        assert_eq!(failed.unwrap_err().to_string(), "the layout kept changing");
        assert_eq!(attempts, ATTEMPTS);
    }

    #[test]
    fn an_edit_names_the_outermost_thing_that_it_made() {
        let created = |edit: Edit, done: Snapshot| {
            edit_from(busy(1, false), &edit, |_, _| Ok(Ok(done.clone())))
                .unwrap()
                .created
        };
        let new = || CreatePane {
            cwd: None,
            command: None,
            env: Vec::new(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
            runtime: None,
        };
        assert_eq!(
            created(
                Edit::AddSession {
                    name: Name::try_from("other".to_owned()).unwrap(),
                    new: new(),
                },
                busy(2, true)
            ),
            Some(Created::Session {
                session: "session_2".parse().unwrap()
            })
        );
        let split: Snapshot = protocol::decode(
            protocol::json(&busy(2, false))
                .replace(r#"{"pane":"pane_3","cols":80,"rows":24}"#, r#"{"split":"h","children":[{"pane":"pane_3","cols":40,"rows":24},{"pane":"pane_9","cols":39,"rows":24}]}"#)
                .as_bytes(),
        )
        .unwrap();
        assert_eq!(
            created(
                Edit::Split {
                    pane: "pane_3".parse().unwrap(),
                    axis: ko_server::protocol::Axis::Horizontal,
                    before: false,
                    new: new(),
                },
                split
            ),
            Some(Created::Pane {
                pane: "pane_9".parse().unwrap()
            })
        );
        assert_eq!(
            created(
                Edit::Equalize {
                    pane: "pane_1".parse().unwrap()
                },
                busy(2, false)
            ),
            None
        );
    }
}

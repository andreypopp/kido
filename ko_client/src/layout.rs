use std::path::Path;

use ko_server::api::Route;
use ko_server::ids::{ClientId, Name, PaneId, SessionId, WindowId};
use ko_server::protocol::{
    self, CreatePane, DraftLayout, DraftSession, DraftWindow, Node, PutLayout, Revision, Snapshot,
};
use serde::{Deserialize, Serialize};

use crate::wire::{self, text};

const ATTEMPTS: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Document {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<Revision>,
    pub layout: DraftLayout,
}

type Put = Result<Snapshot, Snapshot>;

fn fetch(socket: &Path, client: Option<ClientId>) -> Result<Snapshot, String> {
    protocol::decode(&wire::request(socket, client, &Route::GetLayout {}, b"")?).map_err(text)
}

fn send(
    socket: &Path,
    client: Option<ClientId>,
    revision: Revision,
    layout: DraftLayout,
) -> Result<Put, String> {
    let request = PutLayout { revision, layout };
    let (method, target) = Route::PutLayout {}.to_request();
    let response = wire::exchange(
        socket,
        (client, None),
        (method, &target),
        protocol::json(&request).as_bytes(),
        wire::READ_TIMEOUT,
    )
    .map_err(text)?;
    match response.status {
        200 => Ok(Ok(protocol::decode(&response.body).map_err(text)?)),
        409 => Ok(Err(protocol::decode(&response.body).map_err(text)?)),
        status => Err(format!(
            "{status}: {}",
            String::from_utf8_lossy(&response.body)
        )),
    }
}

fn converge(
    first: Snapshot,
    mut put: impl FnMut(Revision, DraftLayout) -> Result<Put, String>,
    mut change: impl FnMut(&mut DraftLayout) -> Result<(), String>,
) -> Result<Snapshot, String> {
    let mut current = first;
    for _ in 0..ATTEMPTS {
        let mut layout = DraftLayout::from(&current.layout);
        change(&mut layout)?;
        match put(current.revision, layout)? {
            Ok(done) => return Ok(done),
            Err(newer) => current = newer,
        }
    }
    Err("the layout kept changing".to_owned())
}

fn edit(
    socket: &Path,
    client: Option<ClientId>,
    change: impl FnMut(&mut DraftLayout) -> Result<(), String>,
) -> Result<Snapshot, String> {
    converge(
        fetch(socket, client)?,
        |revision, layout| send(socket, client, revision, layout),
        change,
    )
}

pub(crate) fn replace(
    socket: &Path,
    client: Option<ClientId>,
    document: &Document,
) -> Result<Snapshot, String> {
    let mut revision = match document.revision {
        Some(revision) => revision,
        None => fetch(socket, client)?.revision,
    };
    for _ in 0..ATTEMPTS {
        match send(socket, client, revision, document.layout.clone())? {
            Ok(done) => return Ok(done),
            Err(newer) => revision = newer.revision,
        }
    }
    Err("the layout kept changing".to_owned())
}

fn ko_name() -> Result<Name, String> {
    Name::try_from("ko".to_owned()).map_err(str::to_owned)
}

fn single(snapshot: &Snapshot, window: Option<WindowId>) -> Result<PaneId, String> {
    let found = match window {
        Some(id) => snapshot.layout.window(id).map(|(_, window)| window),
        None => snapshot
            .layout
            .sessions
            .last()
            .and_then(|session| session.windows.first()),
    };
    match found.map(|window| &window.tree) {
        Some(Node::Leaf(leaf)) => Ok(leaf.pane),
        _ => Err("the new pane is missing from the layout".to_owned()),
    }
}

pub fn add_session(
    socket: &Path,
    client: Option<ClientId>,
    request: &CreatePane,
) -> Result<PaneId, String> {
    let added = DraftSession::single(ko_name()?, request);
    let snapshot = edit(socket, client, |layout| {
        layout.sessions.push(added.clone());
        Ok(())
    })?;
    single(&snapshot, None)
}

pub fn add_window(
    socket: &Path,
    client: Option<ClientId>,
    (session, after): (SessionId, WindowId),
    request: &CreatePane,
) -> Result<PaneId, String> {
    let added = DraftWindow::single(request);
    let snapshot = edit(socket, client, |layout| {
        let windows = &mut layout
            .sessions
            .iter_mut()
            .find(|found| found.id == Some(session))
            .ok_or("the session is gone")?
            .windows;
        let at = windows
            .iter()
            .position(|found| found.id == Some(after))
            .ok_or("the window is gone")?;
        windows.insert(at + 1, added.clone());
        Ok(())
    })?;
    let next = snapshot.layout.session(session).and_then(|session| {
        let at = session.windows.iter().position(|found| found.id == after)?;
        session.windows.get(at + 1)
    });
    single(&snapshot, next.map(|window| window.id))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(revision: u64, sessions: &[&str]) -> Snapshot {
        let sessions: Vec<String> = sessions
            .iter()
            .zip(1..)
            .map(|(name, id)| {
                format!(
                    r#"{{"id":"session_{id}","name":"{name}","vars":{{}},"windows":[{{"id":"window_{id}","name":"w","vars":{{}},"cols":80,"rows":24,"focus":"pane_{id}","tree":{{"pane":"pane_{id}","cols":80,"rows":24}},"floats":[]}}]}}"#
                )
            })
            .collect();
        let text = format!(
            r#"{{"revision":{revision},"layout":{{"sessions":[{}]}}}}"#,
            sessions.join(",")
        );
        protocol::decode(text.as_bytes()).unwrap()
    }

    fn names(layout: &DraftLayout) -> Vec<String> {
        layout
            .sessions
            .iter()
            .map(|session| String::from(session.name.clone()))
            .collect()
    }

    #[test]
    fn a_conflict_applies_the_change_again_to_the_newer_document_and_keeps_its_edits() {
        let mut sent = Vec::new();
        let mut changes = 0;
        let done = converge(
            snapshot(1, &["a"]),
            |revision, layout| {
                sent.push((revision, names(&layout)));
                Ok(if sent.len() == 1 {
                    Err(snapshot(2, &["a", "concurrent"]))
                } else {
                    Ok(snapshot(3, &[]))
                })
            },
            |layout| {
                changes += 1;
                layout.sessions.last_mut().unwrap().name = Name::try_from("mine".to_owned())?;
                Ok(())
            },
        )
        .unwrap();
        let revisions: Vec<_> = sent.iter().map(|(revision, _)| *revision).collect();
        let first = snapshot(1, &[]).revision;
        assert_eq!(revisions.len(), 2);
        assert_eq!(revisions[0], first);
        assert_eq!(
            sent.iter()
                .map(|(_, names)| names.clone())
                .collect::<Vec<_>>(),
            [
                vec!["mine".to_owned()],
                vec!["a".to_owned(), "mine".to_owned()]
            ]
        );
        assert_eq!(changes, 2);
        assert_eq!(done.revision, snapshot(3, &[]).revision);
    }

    #[test]
    fn a_layout_that_keeps_changing_stops_after_the_attempts() {
        let mut attempts = 0;
        let failed = converge(
            snapshot(1, &["a"]),
            |_, _| {
                attempts += 1;
                Ok(Err(snapshot(2, &["a"])))
            },
            |_| Ok(()),
        );
        assert_eq!(failed.unwrap_err(), "the layout kept changing");
        assert_eq!(attempts, ATTEMPTS);
    }
}

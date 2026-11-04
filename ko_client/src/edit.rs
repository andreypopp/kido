use std::fmt;

use ko_server::ids::{Name, PaneId, SessionId, WindowId};
use ko_server::protocol::{
    Axis, Cells, CreatePane, DraftFloat, DraftLayout, DraftLeaf, DraftSession, DraftWindow, Node,
    PaneRef, Tile, pick,
};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Edit {
    Split {
        pane: PaneId,
        axis: Axis,
        #[serde(default)]
        before: bool,
        new: CreatePane,
    },
    // The divider beside the pane on the axis of `edge` moves `delta` cells toward that edge;
    // the divider after the pane, or before the last pane. It unzooms the window. A float grows
    // toward right and bottom, else shrinks.
    ResizeBy {
        pane: PaneId,
        edge: Edge,
        delta: Cells,
    },
    ResizePair {
        first: PaneId,
        second: PaneId,
        first_size: Cells,
    },
    Equalize {
        pane: PaneId,
    },
    Zoom {
        window: WindowId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pane: Option<PaneId>,
    },
    // Unzooms a zoomed window of the pane, else zooms the pane.
    ToggleZoom {
        pane: PaneId,
    },
    Swap {
        pane: PaneId,
        other: PaneId,
    },
    Dock {
        pane: PaneId,
        target: PaneId,
        edge: Edge,
    },
    DockWindow {
        pane: PaneId,
        window: WindowId,
        edge: Edge,
    },
    Float {
        pane: PaneId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        x: Option<u16>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        y: Option<u16>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cols: Option<Cells>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rows: Option<Cells>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        z: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        border: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    Unfloat {
        pane: PaneId,
        target: PaneId,
        edge: Edge,
    },
    BreakPane {
        pane: PaneId,
    },
    AddWindow {
        session: SessionId,
        after: WindowId,
        new: CreatePane,
    },
    AddSession {
        name: Name,
        new: CreatePane,
    },
    RenameSession {
        session: SessionId,
        name: Name,
    },
    RenameWindow {
        window: WindowId,
        name: Name,
    },
    ReorderSessions {
        order: Vec<SessionId>,
    },
    ReorderWindows {
        session: SessionId,
        order: Vec<WindowId>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    Gone(String),
    Invalid(String),
}

impl fmt::Display for Refusal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Gone(id) => write!(formatter, "{id} is gone"),
            Refusal::Invalid(reason) => formatter.write_str(reason),
        }
    }
}

type Tree = Node<DraftLeaf>;
type Done = Result<(), Refusal>;

fn invalid<T>(reason: &str) -> Result<T, Refusal> {
    Err(Refusal::Invalid(reason.to_owned()))
}

fn is(node: &Tree, pane: PaneId) -> bool {
    matches!(node, Node::Leaf(leaf) if leaf.pane_id() == Some(pane))
}

fn leaf_count(node: &Tree) -> usize {
    match node {
        Node::Leaf(_) => 1,
        Node::Split { children, .. } => children.iter().map(leaf_count).sum(),
    }
}

fn alone(window: &DraftWindow) -> bool {
    leaf_count(&window.tree) == 1 && window.floats.is_empty()
}

fn cells(count: usize) -> Option<Cells> {
    Cells::new(u16::try_from(count).unwrap_or(u16::MAX).max(1))
}

fn set_extent(node: &mut Tree, axis: Axis, wanted: usize) {
    match node {
        Node::Leaf(leaf) => *pick(axis, &mut leaf.cols, &mut leaf.rows) = cells(wanted),
        Node::Split { split, children } if *split == axis => {
            let count = children.len();
            let room = wanted.saturating_sub(count.saturating_sub(1));
            let sizes: Vec<usize> = children
                .iter()
                .map(|child| child.known(axis).unwrap_or(1))
                .collect();
            let sum = sizes.iter().sum::<usize>().max(1);
            let mut left = room;
            for (at, (child, size)) in children.iter_mut().zip(sizes).enumerate() {
                let share = if at + 1 == count {
                    left
                } else {
                    (size * room / sum).max(1).min(left)
                };
                left = left.saturating_sub(share);
                set_extent(child, axis, share);
            }
        }
        Node::Split { children, .. } => {
            for child in children {
                set_extent(child, axis, wanted);
            }
        }
    }
}

fn spread(node: &mut Tree, cols: usize, rows: usize) {
    match node {
        Node::Leaf(leaf) => {
            leaf.cols = cells(cols);
            leaf.rows = cells(rows);
        }
        Node::Split { split, children } => {
            let count = children.len().max(1);
            let room = pick(*split, cols, rows).saturating_sub(count - 1);
            for (at, child) in children.iter_mut().enumerate() {
                let share = room / count + usize::from(at < room % count);
                match split {
                    Axis::Horizontal => spread(child, share, rows),
                    Axis::Vertical => spread(child, cols, share),
                }
            }
        }
    }
}

fn detach(node: Tree, pane: PaneId) -> (Option<Tree>, Option<DraftLeaf>) {
    match node {
        Node::Leaf(leaf) if leaf.pane_id() == Some(pane) => (None, Some(leaf)),
        Node::Leaf(leaf) => (Some(Node::Leaf(leaf)), None),
        Node::Split { split, children } => {
            let mut kept = Vec::new();
            let mut found = None;
            for child in children {
                if found.is_some() {
                    kept.push(child);
                    continue;
                }
                let (rest, taken) = detach(child, pane);
                found = taken;
                kept.extend(rest);
            }
            if kept.len() > 1 {
                (
                    Some(Node::Split {
                        split,
                        children: kept,
                    }),
                    found,
                )
            } else {
                (kept.pop(), found)
            }
        }
    }
}

fn beside(
    node: &mut Tree,
    target: PaneId,
    leaf: DraftLeaf,
    (axis, before): (Axis, bool),
) -> Option<DraftLeaf> {
    if is(node, target) {
        let old = std::mem::replace(
            node,
            Node::Split {
                split: axis,
                children: Vec::new(),
            },
        );
        let new = Node::Leaf(leaf);
        *node = Node::Split {
            split: axis,
            children: if before {
                vec![new, old]
            } else {
                vec![old, new]
            },
        };
        return None;
    }
    let Node::Split { split, children } = node else {
        return Some(leaf);
    };
    if *split == axis
        && let Some(at) = children.iter().position(|child| is(child, target))
    {
        children.insert(if before { at } else { at + 1 }, Node::Leaf(leaf));
        return None;
    }
    let mut pending = Some(leaf);
    for child in children {
        if let Some(leaf) = pending.take() {
            pending = beside(child, target, leaf, (axis, before));
        }
    }
    pending
}

fn new_leaf(pane: PaneRef) -> DraftLeaf {
    DraftLeaf {
        pane,
        cols: None,
        rows: None,
    }
}

// The window at `at`, where `locate` found `pane`.
fn window_at(
    layout: &mut DraftLayout,
    (s, w): (usize, usize),
    pane: PaneId,
) -> Result<&mut DraftWindow, Refusal> {
    layout
        .sessions
        .get_mut(s)
        .and_then(|session| session.windows.get_mut(w))
        .ok_or_else(|| Refusal::Gone(pane.to_string()))
}

fn window_of(layout: &mut DraftLayout, pane: PaneId) -> Result<&mut DraftWindow, Refusal> {
    let at = layout
        .locate(pane)
        .ok_or_else(|| Refusal::Gone(pane.to_string()))?;
    window_at(layout, at, pane)
}

fn window_by_id(layout: &mut DraftLayout, id: WindowId) -> Result<&mut DraftWindow, Refusal> {
    layout
        .window_mut(id)
        .ok_or_else(|| Refusal::Gone(id.to_string()))
}

fn session_by_id(layout: &mut DraftLayout, id: SessionId) -> Result<&mut DraftSession, Refusal> {
    layout
        .session_mut(id)
        .ok_or_else(|| Refusal::Gone(id.to_string()))
}

fn along(edge: Edge) -> (Axis, bool) {
    match edge {
        Edge::Left => (Axis::Horizontal, true),
        Edge::Right => (Axis::Horizontal, false),
        Edge::Top => (Axis::Vertical, true),
        Edge::Bottom => (Axis::Vertical, false),
    }
}

fn give(node: &mut Tree, neighbor: &mut Tree, axis: Axis, wanted: usize) {
    let (Some(own), Some(other)) = (node.known(axis), neighbor.known(axis)) else {
        return;
    };
    let total = own + other;
    let (least, most) = (
        node.minimum(axis),
        total.saturating_sub(neighbor.minimum(axis)),
    );
    if least > most {
        return;
    }
    let wanted = wanted.clamp(least, most);
    set_extent(node, axis, wanted);
    set_extent(neighbor, axis, total - wanted);
}

fn adjacent(children: &mut [Tree], at: usize, axis: Axis, wanted: usize) {
    let (left, right) = children.split_at_mut(at + 1);
    if let (Some(node), Some(neighbor)) = (left.last_mut(), right.first_mut()) {
        give(node, neighbor, axis, wanted);
    }
}

fn resize_by_in(node: &mut Tree, pane: PaneId, edge: Edge, delta: usize) -> Option<bool> {
    let Node::Split { split, children } = node else {
        return is(node, pane).then_some(false);
    };
    let at = children.iter().position(|child| child.contains(pane))?;
    let inside = children
        .get_mut(at)
        .and_then(|child| resize_by_in(child, pane, edge, delta))?;
    let (axis, leading) = along(edge);
    if inside || *split != axis {
        return Some(inside);
    }
    let first = if at + 1 < children.len() {
        at
    } else {
        at.checked_sub(1)?
    };
    let size = children.get(first).and_then(|child| child.known(axis))?;
    let wanted = if leading {
        size.saturating_sub(delta)
    } else {
        size + delta
    };
    adjacent(children, first, axis, wanted);
    Some(true)
}

fn pair_in(node: &mut Tree, (first, second): (PaneId, PaneId), size: usize) -> Option<bool> {
    let Node::Split { split, children } = node else {
        return None;
    };
    let a = children.iter().position(|child| child.contains(first))?;
    let b = children.iter().position(|child| child.contains(second))?;
    if a == b {
        return children
            .get_mut(a)
            .and_then(|child| pair_in(child, (first, second), size));
    }
    if b != a + 1 {
        return Some(false);
    }
    adjacent(children, a, *split, size);
    Some(true)
}

fn equalize_in(node: &mut Tree, pane: PaneId) -> bool {
    let Node::Split { children, .. } = node else {
        return false;
    };
    if children.iter().any(|child| is(child, pane)) {
        let (cols, rows) = (
            node.known(Axis::Horizontal).unwrap_or(1),
            node.known(Axis::Vertical).unwrap_or(1),
        );
        spread(node, cols, rows);
        return true;
    }
    children.iter_mut().any(|child| equalize_in(child, pane))
}

fn swap_refs(layout: &mut DraftLayout, a: PaneId, b: PaneId) {
    let flip = |id: PaneId| {
        if id == a {
            b
        } else if id == b {
            a
        } else {
            id
        }
    };
    fn walk(node: &mut Tree, flip: &impl Fn(PaneId) -> PaneId) {
        match node {
            Node::Leaf(leaf) => {
                if let PaneRef::Existing(id) = leaf.pane {
                    leaf.pane = PaneRef::Existing(flip(id));
                }
            }
            Node::Split { children, .. } => children.iter_mut().for_each(|child| walk(child, flip)),
        }
    }
    for window in layout
        .sessions
        .iter_mut()
        .flat_map(|session| session.windows.iter_mut())
    {
        walk(&mut window.tree, &flip);
        for float in &mut window.floats {
            if let PaneRef::Existing(id) = float.pane {
                float.pane = PaneRef::Existing(flip(id));
            }
        }
        window.zoom = window.zoom.map(flip);
    }
}

// Takes a pane out of its window, which goes with it when it was the last pane.
fn take(layout: &mut DraftLayout, pane: PaneId) -> Result<(DraftLeaf, bool), Refusal> {
    let (s, w) = layout
        .locate(pane)
        .ok_or_else(|| Refusal::Gone(pane.to_string()))?;
    let window = window_at(layout, (s, w), pane)?;
    if window.zoom == Some(pane) {
        window.zoom = None;
    }
    if let Some(at) = window
        .floats
        .iter()
        .position(|float| float.pane == PaneRef::Existing(pane))
    {
        let float = window.floats.remove(at);
        return Ok((new_leaf(float.pane), true));
    }
    let single = leaf_count(&window.tree) == 1;
    if single && !window.floats.is_empty() {
        return invalid("the window keeps its floats on the last tiled pane");
    }
    if !single {
        let tree = std::mem::replace(
            &mut window.tree,
            Node::Split {
                split: Axis::Horizontal,
                children: Vec::new(),
            },
        );
        let (rest, taken) = detach(tree, pane);
        let (Some(rest), Some(taken)) = (rest, taken) else {
            return invalid("the pane could not be taken out");
        };
        window.tree = rest;
        return Ok((new_leaf(taken.pane), false));
    }
    let session = layout
        .sessions
        .get_mut(s)
        .ok_or_else(|| Refusal::Gone(pane.to_string()))?;
    let window = session.windows.remove(w);
    if session.windows.is_empty() {
        layout.sessions.remove(s);
    }
    match window.tree {
        Node::Leaf(leaf) => Ok((new_leaf(leaf.pane), false)),
        Node::Split { .. } => invalid("the window has no single pane"),
    }
}

fn dock(layout: &mut DraftLayout, pane: PaneId, target: PaneId, edge: Edge) -> Done {
    if pane == target {
        return invalid("a pane cannot dock beside itself");
    }
    if !window_of(layout, target)?.tree.contains(target) {
        return invalid("the target is a float");
    }
    layout
        .locate(pane)
        .ok_or_else(|| Refusal::Gone(pane.to_string()))?;
    let (leaf, _) = take(layout, pane)?;
    let window = window_of(layout, target)?;
    match beside(&mut window.tree, target, leaf, along(edge)) {
        None => Ok(()),
        Some(_) => invalid("the target is a float"),
    }
}

fn float(layout: &mut DraftLayout, edit: &Edit) -> Done {
    let Edit::Float {
        pane,
        x,
        y,
        cols,
        rows,
        z,
        border,
        title,
    } = edit
    else {
        return Ok(());
    };
    let window = window_of(layout, *pane)?;
    if let Some(float) = window
        .floats
        .iter_mut()
        .find(|float| float.pane == PaneRef::Existing(*pane))
    {
        float.x = x.or(float.x);
        float.y = y.or(float.y);
        float.cols = cols.or(float.cols);
        float.rows = rows.or(float.rows);
        float.z = z.or(float.z);
        float.border = border.unwrap_or(float.border);
        if let Some(title) = title {
            float.title.clone_from(title);
        }
        return Ok(());
    }
    if leaf_count(&window.tree) < 2 {
        return invalid("the last tiled pane cannot float");
    }
    let tree = std::mem::replace(
        &mut window.tree,
        Node::Split {
            split: Axis::Horizontal,
            children: Vec::new(),
        },
    );
    let (rest, taken) = detach(tree, *pane);
    let (Some(rest), Some(taken)) = (rest, taken) else {
        return invalid("the pane could not be taken out");
    };
    window.tree = rest;
    if window.zoom == Some(*pane) {
        window.zoom = None;
    }
    window.floats.push(DraftFloat {
        pane: taken.pane,
        x: *x,
        y: *y,
        cols: *cols,
        rows: *rows,
        z: *z,
        border: border.unwrap_or(false),
        title: title.clone().unwrap_or_default(),
    });
    Ok(())
}

fn reorder<T, K: PartialEq + Copy>(items: &mut Vec<T>, order: &[K], key: impl Fn(&T) -> Option<K>) {
    let mut rest = std::mem::take(items);
    for wanted in order {
        if let Some(at) = rest.iter().position(|item| key(item) == Some(*wanted)) {
            items.push(rest.remove(at));
        }
    }
    items.append(&mut rest);
}

fn created(request: &CreatePane) -> PaneRef {
    PaneRef::New {
        new: request.clone(),
    }
}

pub(crate) fn apply(layout: &mut DraftLayout, edit: &Edit) -> Done {
    match edit {
        Edit::Split {
            pane,
            axis,
            before,
            new,
        } => {
            let window = window_of(layout, *pane)?;
            if !window.tree.contains(*pane) {
                return invalid("a float cannot be split");
            }
            match beside(
                &mut window.tree,
                *pane,
                new_leaf(created(new)),
                (*axis, *before),
            ) {
                None => Ok(()),
                Some(_) => invalid("the pane is not tiled"),
            }
        }
        Edit::ResizeBy { pane, edge, delta } => {
            let window = window_of(layout, *pane)?;
            window.zoom = None;
            let (axis, leading) = along(*edge);
            if let Some(float) = window
                .floats
                .iter_mut()
                .find(|float| float.pane == PaneRef::Existing(*pane))
            {
                let size = pick(axis, &mut float.cols, &mut float.rows);
                *size = size.and_then(|size| {
                    Cells::new(if leading {
                        size.get().saturating_sub(delta.get()).max(1)
                    } else {
                        size.get().saturating_add(delta.get())
                    })
                });
            } else {
                resize_by_in(&mut window.tree, *pane, *edge, usize::from(delta.get()));
            }
            Ok(())
        }
        Edit::ResizePair {
            first,
            second,
            first_size,
        } => {
            let window = window_of(layout, *first)?;
            if !window.holds(*second) {
                return Err(Refusal::Gone(second.to_string()));
            }
            match pair_in(
                &mut window.tree,
                (*first, *second),
                usize::from(first_size.get()),
            ) {
                Some(true) => Ok(()),
                _ => invalid("the panes are not neighbours across one divider"),
            }
        }
        Edit::Equalize { pane } => {
            let window = window_of(layout, *pane)?;
            equalize_in(&mut window.tree, *pane);
            Ok(())
        }
        Edit::Zoom { window, pane } => {
            let window = window_by_id(layout, *window)?;
            if let Some(pane) = pane
                && !window.holds(*pane)
            {
                return Err(Refusal::Gone(pane.to_string()));
            }
            window.zoom = *pane;
            Ok(())
        }
        Edit::ToggleZoom { pane } => {
            let window = window_of(layout, *pane)?;
            window.zoom = match window.zoom {
                Some(_) => None,
                None => Some(*pane),
            };
            Ok(())
        }
        Edit::Swap { pane, other } => {
            for id in [pane, other] {
                layout
                    .locate(*id)
                    .ok_or_else(|| Refusal::Gone(id.to_string()))?;
            }
            swap_refs(layout, *pane, *other);
            Ok(())
        }
        Edit::Dock { pane, target, edge } => dock(layout, *pane, *target, *edge),
        Edit::DockWindow { pane, window, edge } => {
            let id = *window;
            let target = window_by_id(layout, id)?;
            if alone(target) && target.holds(*pane) {
                return invalid("the pane is alone in the window");
            }
            layout
                .locate(*pane)
                .ok_or_else(|| Refusal::Gone(pane.to_string()))?;
            let (leaf, _) = take(layout, *pane)?;
            let window = window_by_id(layout, id)?;
            let (axis, before) = along(*edge);
            let old = std::mem::replace(
                &mut window.tree,
                Node::Split {
                    split: axis,
                    children: Vec::new(),
                },
            );
            let new = Node::Leaf(leaf);
            window.tree = Node::Split {
                split: axis,
                children: if before {
                    vec![new, old]
                } else {
                    vec![old, new]
                },
            };
            Ok(())
        }
        Edit::BreakPane { pane } => {
            let (s, w) = layout
                .locate(*pane)
                .ok_or_else(|| Refusal::Gone(pane.to_string()))?;
            let window = window_at(layout, (s, w), *pane)?;
            if alone(window) {
                return invalid("the pane is alone in the window");
            }
            let (leaf, _) = take(layout, *pane)?;
            let session = layout
                .sessions
                .get_mut(s)
                .ok_or_else(|| Refusal::Gone(pane.to_string()))?;
            session.windows.insert(w + 1, DraftWindow::leaf(leaf));
            Ok(())
        }
        Edit::Float { .. } => float(layout, edit),
        Edit::Unfloat { pane, target, edge } => {
            let window = window_of(layout, *pane)?;
            if !window
                .floats
                .iter()
                .any(|float| float.pane == PaneRef::Existing(*pane))
            {
                return invalid("the pane is not a float");
            }
            dock(layout, *pane, *target, *edge)
        }
        Edit::AddWindow {
            session,
            after,
            new,
        } => {
            let session = session_by_id(layout, *session)?;
            let at = session
                .windows
                .iter()
                .position(|window| window.id == Some(*after))
                .ok_or_else(|| Refusal::Gone(after.to_string()))?;
            session.windows.insert(at + 1, DraftWindow::single(new));
            Ok(())
        }
        Edit::AddSession { name, new } => {
            layout
                .sessions
                .push(DraftSession::single(name.clone(), new));
            Ok(())
        }
        Edit::RenameSession { session, name } => {
            session_by_id(layout, *session)?.name = name.clone();
            Ok(())
        }
        Edit::RenameWindow { window, name } => {
            window_by_id(layout, *window)?.name = Some(name.clone());
            Ok(())
        }
        Edit::ReorderSessions { order } => {
            reorder(&mut layout.sessions, order, |session| session.id);
            Ok(())
        }
        Edit::ReorderWindows { session, order } => {
            let session = session_by_id(layout, *session)?;
            reorder(&mut session.windows, order, |window| window.id);
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use ko_server::ids::Name;
    use proptest::prelude::*;

    use super::*;

    fn pane(number: u64) -> PaneId {
        format!("pane_{number}").parse().unwrap()
    }

    fn window_id(number: u64) -> WindowId {
        format!("window_{number}").parse().unwrap()
    }

    fn session_id(number: u64) -> SessionId {
        format!("session_{number}").parse().unwrap()
    }

    fn name(text: &str) -> Name {
        Name::try_from(text.to_owned()).unwrap()
    }

    fn created() -> CreatePane {
        CreatePane {
            cwd: None,
            command: None,
            env: Vec::new(),
            vars: Default::default(),
            parent: None,
            close: Default::default(),
            runtime: None,
        }
    }

    // Tree notation: `1@40x24` is a leaf, `h(..)` and `v(..)` are splits; floats follow a `|` as
    // `3@x,y,CxR,z`.
    fn parse_tree(text: &mut &str) -> Tree {
        for (prefix, axis) in [("h(", Axis::Horizontal), ("v(", Axis::Vertical)] {
            if let Some(rest) = text.strip_prefix(prefix) {
                *text = rest;
                let mut children = vec![parse_tree(text)];
                while let Some(rest) = text.strip_prefix(',') {
                    *text = rest;
                    children.push(parse_tree(text));
                }
                *text = text.strip_prefix(')').unwrap();
                return Node::Split {
                    split: axis,
                    children,
                };
            }
        }
        let end = text.find([',', ')', '|', ' ']).unwrap_or(text.len());
        let (leaf, rest) = text.split_at(end);
        *text = rest;
        let (id, size) = leaf
            .split_once('@')
            .map_or((leaf, None), |(id, size)| (id, Some(size)));
        let (cols, rows) =
            size.and_then(|size| size.split_once('x'))
                .map_or((None, None), |(c, r)| {
                    (
                        Cells::new(c.parse().unwrap()),
                        Cells::new(r.parse().unwrap()),
                    )
                });
        Node::Leaf(DraftLeaf {
            pane: PaneRef::Existing(pane(id.parse().unwrap())),
            cols,
            rows,
        })
    }

    fn window(text: &str, number: u64) -> DraftWindow {
        let (tree, floats) = text.split_once('|').map_or((text, ""), |(a, b)| (a, b));
        let mut rest = tree;
        let tree = parse_tree(&mut rest);
        let floats = floats
            .split_whitespace()
            .map(|float| {
                let (id, geometry) = float.split_once('@').unwrap();
                let parts: Vec<&str> = geometry.split(',').collect();
                let (c, r) = parts[2].split_once('x').unwrap();
                DraftFloat {
                    pane: PaneRef::Existing(pane(id.parse().unwrap())),
                    x: Some(parts[0].parse().unwrap()),
                    y: Some(parts[1].parse().unwrap()),
                    cols: Cells::new(c.parse().unwrap()),
                    rows: Cells::new(r.parse().unwrap()),
                    z: Some(parts[3].parse().unwrap()),
                    border: false,
                    title: String::new(),
                }
            })
            .collect();
        DraftWindow {
            id: Some(window_id(number)),
            name: Some(name("w")),
            vars: Default::default(),
            cols: Cells::new(80),
            rows: Cells::new(24),
            cell_px: None,
            zoom: None,
            tree,
            floats,
        }
    }

    fn layout(windows: &[&str]) -> DraftLayout {
        DraftLayout {
            sessions: vec![DraftSession {
                id: Some(session_id(1)),
                name: name("s"),
                vars: Default::default(),
                windows: windows
                    .iter()
                    .zip(1..)
                    .map(|(text, number)| window(text, number))
                    .collect(),
            }],
        }
    }

    fn show_tree(node: &Tree) -> String {
        match node {
            Node::Leaf(leaf) => {
                let id = match &leaf.pane {
                    PaneRef::Existing(id) => id.to_string().replace("pane_", ""),
                    PaneRef::New { .. } => "new".to_owned(),
                };
                match (leaf.cols, leaf.rows) {
                    (Some(c), Some(r)) => format!("{id}@{}x{}", c.get(), r.get()),
                    (Some(c), None) => format!("{id}@{}x_", c.get()),
                    (None, Some(r)) => format!("{id}@_x{}", r.get()),
                    (None, None) => id,
                }
            }
            Node::Split { split, children } => {
                let letter = match split {
                    Axis::Horizontal => "h",
                    Axis::Vertical => "v",
                };
                let inner: Vec<String> = children.iter().map(show_tree).collect();
                format!("{letter}({})", inner.join(","))
            }
        }
    }

    fn show_window(window: &DraftWindow) -> String {
        let mut text = show_tree(&window.tree);
        if !window.floats.is_empty() {
            text.push_str(" |");
            for float in &window.floats {
                let PaneRef::Existing(id) = float.pane else {
                    continue;
                };
                text.push_str(&format!(
                    " {}@{},{},{}x{},{}",
                    id.to_string().replace("pane_", ""),
                    float.x.unwrap_or(0),
                    float.y.unwrap_or(0),
                    float.cols.map_or(0, Cells::get),
                    float.rows.map_or(0, Cells::get),
                    float.z.unwrap_or(0)
                ));
            }
        }
        if let Some(zoom) = window.zoom {
            text.push_str(&format!(" zoom {zoom}"));
        }
        text
    }

    fn show(layout: &DraftLayout) -> Vec<String> {
        layout
            .sessions
            .iter()
            .flat_map(|session| session.windows.iter())
            .map(show_window)
            .collect()
    }

    fn applied(windows: &[&str], edit: Edit) -> Vec<String> {
        let mut draft = layout(windows);
        apply(&mut draft, &edit).unwrap();
        show(&draft)
    }

    fn split(pane_number: u64, axis: Axis, before: bool) -> Edit {
        Edit::Split {
            pane: pane(pane_number),
            axis,
            before,
            new: created(),
        }
    }

    #[test]
    fn a_split_adds_a_sibling_on_its_axis_or_a_new_split_across_it() {
        let two = ["h(1@40x24,2@39x24)"];
        assert_eq!(
            applied(&two, split(2, Axis::Horizontal, false)),
            ["h(1@40x24,2@39x24,new)"]
        );
        assert_eq!(
            applied(&two, split(2, Axis::Horizontal, true)),
            ["h(1@40x24,new,2@39x24)"]
        );
        assert_eq!(
            applied(&two, split(2, Axis::Vertical, false)),
            ["h(1@40x24,v(2@39x24,new))"]
        );
        assert_eq!(
            applied(&["1@80x24"], split(1, Axis::Vertical, true)),
            ["v(new,1@80x24)"]
        );
    }

    #[test]
    fn a_resize_moves_the_divider_beside_the_pane_toward_its_edge_and_stops_at_the_minimum() {
        let by = |pane_number, edge, delta| Edit::ResizeBy {
            pane: pane(pane_number),
            edge,
            delta: Cells::new(delta).unwrap(),
        };
        let two = ["h(1@40x24,2@39x24)"];
        assert_eq!(
            applied(&two, by(1, Edge::Right, 10)),
            ["h(1@50x24,2@29x24)"]
        );
        assert_eq!(
            applied(&two, by(2, Edge::Right, 10)),
            ["h(1@50x24,2@29x24)"],
            "the last pane of a split moves the divider before it, toward the edge"
        );
        assert_eq!(applied(&two, by(2, Edge::Left, 10)), ["h(1@30x24,2@49x24)"]);
        assert_eq!(
            applied(&two, by(1, Edge::Right, 500)),
            ["h(1@78x24,2@1x24)"]
        );
        let mut draft = layout(&two);
        apply(&mut draft, &by(1, Edge::Right, 3)).unwrap();
        apply(&mut draft, &by(1, Edge::Right, 3)).unwrap();
        assert_eq!(
            show(&draft),
            ["h(1@46x24,2@33x24)"],
            "two presses are two steps"
        );
        assert_eq!(
            applied(&["h(1@40x24,v(2@39x12,3@39x11))"], by(3, Edge::Top, 4)),
            ["h(1@40x24,v(2@39x8,3@39x15))"]
        );
        assert_eq!(
            applied(&["h(1@40x24,v(2@39x12,3@39x11))"], by(2, Edge::Left, 10)),
            ["h(1@30x24,v(2@49x12,3@49x11))"]
        );
        assert_eq!(applied(&["1@80x24"], by(1, Edge::Right, 5)), ["1@80x24"]);
        let mut zoomed = layout(&two);
        apply(&mut zoomed, &Edit::ToggleZoom { pane: pane(2) }).unwrap();
        apply(&mut zoomed, &by(1, Edge::Right, 10)).unwrap();
        assert_eq!(
            show(&zoomed),
            ["h(1@50x24,2@29x24)"],
            "a resize unzooms and acts on the tiled sizes"
        );
    }

    #[test]
    fn toggle_zoom_zooms_the_pane_and_a_second_press_unzooms() {
        let mut draft = layout(&["h(1,2)"]);
        let toggle = |pane_number| Edit::ToggleZoom {
            pane: pane(pane_number),
        };
        apply(&mut draft, &toggle(2)).unwrap();
        assert_eq!(show(&draft), ["h(1,2) zoom pane_2"]);
        apply(&mut draft, &toggle(1)).unwrap();
        assert_eq!(show(&draft), ["h(1,2)"], "any pane's press unzooms");
        assert!(matches!(
            apply(&mut draft, &toggle(9)),
            Err(Refusal::Gone(id)) if id == "pane_9"
        ));
    }

    #[test]
    fn a_divider_drag_moves_one_boundary_and_keeps_the_rest() {
        let three = ["h(1@20x24,2@20x24,3@36x24)"];
        let pair = |first_size| Edit::ResizePair {
            first: pane(1),
            second: pane(2),
            first_size: Cells::new(first_size).unwrap(),
        };
        assert_eq!(applied(&three, pair(30)), ["h(1@30x24,2@10x24,3@36x24)"]);
        assert_eq!(applied(&three, pair(2)), ["h(1@2x24,2@38x24,3@36x24)"]);
        let mut draft = layout(&three);
        let apart = Edit::ResizePair {
            first: pane(1),
            second: pane(3),
            first_size: Cells::new(5).unwrap(),
        };
        assert!(matches!(
            apply(&mut draft, &apart),
            Err(Refusal::Invalid(_))
        ));
    }

    #[test]
    fn equalize_gives_every_pane_of_the_enclosing_split_the_same_share() {
        assert_eq!(
            applied(
                &["h(1@60x24,2@10x24,3@7x24)"],
                Edit::Equalize { pane: pane(2) }
            ),
            ["h(1@26x24,2@26x24,3@25x24)"]
        );
        assert_eq!(
            applied(
                &["h(1@40x24,v(2@39x20,3@39x3))"],
                Edit::Equalize { pane: pane(3) }
            ),
            ["h(1@40x24,v(2@39x12,3@39x11))"]
        );
        assert_eq!(
            applied(&["1@80x24"], Edit::Equalize { pane: pane(1) }),
            ["1@80x24"]
        );
    }

    #[test]
    fn zoom_names_a_pane_of_the_window_or_none() {
        let edit = |pane_number: Option<u64>| Edit::Zoom {
            window: window_id(1),
            pane: pane_number.map(pane),
        };
        assert_eq!(applied(&["h(1,2)"], edit(Some(2))), ["h(1,2) zoom pane_2"]);
        let mut draft = layout(&["h(1,2)"]);
        assert!(matches!(
            apply(&mut draft, &edit(Some(9))),
            Err(Refusal::Gone(id)) if id == "pane_9"
        ));
        apply(&mut draft, &edit(Some(1))).unwrap();
        apply(&mut draft, &edit(None)).unwrap();
        assert_eq!(show(&draft), ["h(1,2)"]);
    }

    #[test]
    fn a_swap_exchanges_the_places_of_two_panes_also_across_windows_and_floats() {
        let swap = |a, b| Edit::Swap {
            pane: pane(a),
            other: pane(b),
        };
        assert_eq!(
            applied(&["h(1@40x24,2@39x24)"], swap(1, 2)),
            ["h(2@40x24,1@39x24)"]
        );
        assert_eq!(
            applied(&["h(1@40x24,2@39x24)", "3@80x24"], swap(1, 3)),
            ["h(3@40x24,2@39x24)", "1@80x24"]
        );
        assert_eq!(
            applied(&["h(1@40x24,2@39x24) | 3@1,1,10x5,1"], swap(2, 3)),
            ["h(1@40x24,3@39x24) | 2@1,1,10x5,1"]
        );
    }

    #[test]
    fn docking_moves_a_pane_beside_a_target_and_takes_it_from_a_float_or_a_window() {
        let dock = |p, t, edge| Edit::Dock {
            pane: pane(p),
            target: pane(t),
            edge,
        };
        assert_eq!(
            applied(&["h(1@40x24,2@39x24)"], dock(1, 2, Edge::Bottom)),
            ["v(2@39x24,1)"]
        );
        assert_eq!(
            applied(&["h(1@30x24,v(2@49x12,3@49x11))"], dock(1, 3, Edge::Left)),
            ["v(2@49x12,h(1,3@49x11))"]
        );
        assert_eq!(
            applied(&["h(1@40x24,2@39x24)", "3@80x24"], dock(3, 1, Edge::Right)),
            ["h(1@40x24,3,2@39x24)"]
        );
        assert_eq!(
            applied(
                &["h(1@40x24,2@39x24) | 3@1,1,10x5,1"],
                dock(3, 2, Edge::Top)
            ),
            ["h(1@40x24,v(3,2@39x24))"]
        );
        let mut draft = layout(&["h(1,2) | 3@1,1,10x5,1"]);
        assert!(matches!(
            apply(&mut draft, &dock(1, 3, Edge::Left)),
            Err(Refusal::Invalid(_))
        ));
        assert!(matches!(
            apply(&mut draft, &dock(1, 1, Edge::Left)),
            Err(Refusal::Invalid(_))
        ));
    }

    #[test]
    fn a_window_dock_wraps_the_whole_tree_and_an_alone_pane_cannot_dock_there() {
        let edit = |pane_number, edge| Edit::DockWindow {
            pane: pane(pane_number),
            window: window_id(1),
            edge,
        };
        assert_eq!(
            applied(
                &["h(1@40x24,v(2@39x12,3@39x11))", "4@80x24"],
                edit(4, Edge::Top)
            ),
            ["v(4,h(1@40x24,v(2@39x12,3@39x11)))"]
        );
        let mut draft = layout(&["1@80x24"]);
        assert!(matches!(
            apply(&mut draft, &edit(1, Edge::Left)),
            Err(Refusal::Invalid(_))
        ));
    }

    #[test]
    fn a_pane_floats_by_leaving_the_tree_and_a_float_changes_only_what_is_given() {
        let float = |pane_number, x, z| Edit::Float {
            pane: pane(pane_number),
            x,
            y: None,
            cols: None,
            rows: None,
            z,
            border: None,
            title: None,
        };
        assert_eq!(
            applied(&["h(1@40x24,2@39x24)"], float(2, Some(5), Some(3))),
            ["1@40x24 | 2@5,0,0x0,3"]
        );
        assert_eq!(
            applied(
                &["h(1@40x24,2@39x24) | 3@1,2,10x5,1"],
                float(3, None, Some(9))
            ),
            ["h(1@40x24,2@39x24) | 3@1,2,10x5,9"]
        );
        let mut draft = layout(&["1@80x24"]);
        assert!(matches!(
            apply(&mut draft, &float(1, None, None)),
            Err(Refusal::Invalid(_))
        ));
    }

    #[test]
    fn unfloating_docks_a_float_and_refuses_a_tiled_pane() {
        let unfloat = |p, t| Edit::Unfloat {
            pane: pane(p),
            target: pane(t),
            edge: Edge::Right,
        };
        assert_eq!(
            applied(&["1@80x24 | 2@1,1,10x5,1"], unfloat(2, 1)),
            ["h(1@80x24,2)"]
        );
        let mut draft = layout(&["h(1,2)"]);
        assert!(matches!(
            apply(&mut draft, &unfloat(1, 2)),
            Err(Refusal::Invalid(_))
        ));
    }

    #[test]
    fn windows_and_sessions_are_added_renamed_and_reordered() {
        let mut draft = layout(&["1", "2", "3"]);
        apply(
            &mut draft,
            &Edit::AddWindow {
                session: session_id(1),
                after: window_id(1),
                new: created(),
            },
        )
        .unwrap();
        apply(
            &mut draft,
            &Edit::AddSession {
                name: name("t"),
                new: created(),
            },
        )
        .unwrap();
        apply(
            &mut draft,
            &Edit::RenameWindow {
                window: window_id(3),
                name: name("renamed"),
            },
        )
        .unwrap();
        apply(
            &mut draft,
            &Edit::RenameSession {
                session: session_id(1),
                name: name("main"),
            },
        )
        .unwrap();
        apply(
            &mut draft,
            &Edit::ReorderWindows {
                session: session_id(1),
                order: vec![window_id(3), window_id(1)],
            },
        )
        .unwrap();
        let order = |draft: &DraftLayout| -> Vec<String> {
            draft.sessions[0]
                .windows
                .iter()
                .map(|window| window.id.map_or("new".to_owned(), |id| id.to_string()))
                .collect()
        };
        assert_eq!(order(&draft), ["window_3", "window_1", "new", "window_2"]);
        assert_eq!(
            draft
                .sessions
                .iter()
                .map(|s| String::from(s.name.clone()))
                .collect::<Vec<_>>(),
            ["main", "t"]
        );
        assert_eq!(
            draft.sessions[0].windows[0].name.clone().map(String::from),
            Some("renamed".to_owned())
        );
        draft.sessions[1].id = Some(session_id(2));
        apply(
            &mut draft,
            &Edit::ReorderSessions {
                order: vec![session_id(2)],
            },
        )
        .unwrap();
        assert_eq!(
            draft
                .sessions
                .iter()
                .map(|s| String::from(s.name.clone()))
                .collect::<Vec<_>>(),
            ["t", "main"]
        );
    }

    #[test]
    fn an_edit_of_something_that_is_gone_names_it() {
        let mut draft = layout(&["h(1,2)"]);
        for (edit, gone) in [
            (split(7, Axis::Horizontal, false), "pane_7"),
            (
                Edit::Swap {
                    pane: pane(1),
                    other: pane(8),
                },
                "pane_8",
            ),
            (
                Edit::RenameWindow {
                    window: window_id(4),
                    name: name("x"),
                },
                "window_4",
            ),
            (
                Edit::AddWindow {
                    session: session_id(1),
                    after: window_id(5),
                    new: created(),
                },
                "window_5",
            ),
            (
                Edit::RenameSession {
                    session: session_id(6),
                    name: name("x"),
                },
                "session_6",
            ),
        ] {
            assert_eq!(
                apply(&mut draft, &edit),
                Err(Refusal::Gone(gone.to_owned())),
                "{edit:?}"
            );
        }
    }

    fn panes_of(layout: &DraftLayout) -> (Vec<PaneId>, usize) {
        fn walk(node: &Tree, ids: &mut Vec<PaneId>, fresh: &mut usize) {
            match node {
                Node::Leaf(leaf) => match leaf.pane {
                    PaneRef::Existing(id) => ids.push(id),
                    PaneRef::New { .. } => *fresh += 1,
                },
                Node::Split { children, .. } => {
                    children.iter().for_each(|child| walk(child, ids, fresh));
                }
            }
        }
        let (mut ids, mut fresh) = (Vec::new(), 0);
        for window in layout
            .sessions
            .iter()
            .flat_map(|session| session.windows.iter())
        {
            walk(&window.tree, &mut ids, &mut fresh);
            for float in &window.floats {
                match float.pane {
                    PaneRef::Existing(id) => ids.push(id),
                    PaneRef::New { .. } => fresh += 1,
                }
            }
        }
        ids.sort();
        (ids, fresh)
    }

    fn trees() -> impl Strategy<Value = (Vec<Vec<u64>>, Vec<bool>)> {
        (
            prop::collection::vec(
                prop::collection::vec(any::<u8>().prop_map(u64::from), 1..5),
                1..4,
            ),
            prop::collection::vec(any::<bool>(), 12),
        )
    }

    // Windows of 1 to 4 panes, as a right-leaning chain of splits with some floats.
    fn generated((windows, flags): &(Vec<Vec<u64>>, Vec<bool>)) -> DraftLayout {
        let mut next = 0;
        let mut texts = Vec::new();
        for (index, panes) in windows.iter().enumerate() {
            let mut ids = Vec::new();
            for _ in panes {
                next += 1;
                ids.push(next);
            }
            let tiled = ids.len().div_ceil(2);
            let leaf = |id: &u64, at: usize| {
                let size = if flags.get(at).copied().unwrap_or(false) {
                    "@20x10"
                } else {
                    ""
                };
                format!("{id}{size}")
            };
            let tree = if tiled == 1 {
                leaf(&ids[0], index)
            } else {
                let axis = if flags.get(index + 6).copied().unwrap_or(false) {
                    "h"
                } else {
                    "v"
                };
                let inner: Vec<String> = ids
                    .iter()
                    .take(tiled)
                    .enumerate()
                    .map(|(at, id)| leaf(id, at + index))
                    .collect();
                format!("{axis}({})", inner.join(","))
            };
            let floats: Vec<String> = ids
                .iter()
                .skip(tiled)
                .map(|id| format!("{id}@1,1,10x5,1"))
                .collect();
            texts.push(if floats.is_empty() {
                tree
            } else {
                format!("{tree} | {}", floats.join(" "))
            });
        }
        let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
        layout(&refs)
    }

    #[test]
    fn break_pane_keeps_the_other_leaves_and_inserts_after_its_window() {
        let mut draft = layout(&["h(1@40x24,2@39x24)", "3@80x24"]);
        draft.sessions[0].windows[0].zoom = Some(pane(2));
        apply(&mut draft, &Edit::BreakPane { pane: pane(2) }).unwrap();
        assert_eq!(show(&draft), ["1@40x24", "2", "3@80x24"]);
        assert_eq!(draft.sessions[0].windows[0].zoom, None);
        assert_eq!(
            applied(
                &["1@80x24 | 2@1,2,20x10,0", "3@80x24"],
                Edit::BreakPane { pane: pane(2) }
            ),
            ["1@80x24", "2", "3@80x24"]
        );
        let mut alone = layout(&["1@80x24"]);
        let before = alone.clone();
        assert_eq!(
            apply(&mut alone, &Edit::BreakPane { pane: pane(1) }),
            invalid("the pane is alone in the window")
        );
        assert_eq!(alone, before);
        let mut floats = layout(&["1@80x24 | 2@1,2,20x10,0"]);
        assert_eq!(
            apply(&mut floats, &Edit::BreakPane { pane: pane(1) }),
            invalid("the window keeps its floats on the last tiled pane")
        );
    }

    fn edits(total: u64) -> impl Strategy<Value = Edit> {
        let any_pane = move || (1..=total + 1).prop_map(pane);
        let edge = prop_oneof![
            Just(Edge::Left),
            Just(Edge::Right),
            Just(Edge::Top),
            Just(Edge::Bottom)
        ];
        let axis = prop_oneof![Just(Axis::Horizontal), Just(Axis::Vertical)];
        let size = (1u16..200).prop_map(|n| Cells::new(n).unwrap());
        prop_oneof![
            (any_pane(), axis, any::<bool>()).prop_map(|(pane, axis, before)| Edit::Split {
                pane,
                axis,
                before,
                new: created()
            }),
            (any_pane(), edge.clone(), size.clone())
                .prop_map(|(pane, edge, delta)| Edit::ResizeBy { pane, edge, delta }),
            any_pane().prop_map(|pane| Edit::ToggleZoom { pane }),
            (any_pane(), any_pane(), size.clone()).prop_map(|(first, second, first_size)| {
                Edit::ResizePair {
                    first,
                    second,
                    first_size,
                }
            }),
            any_pane().prop_map(|pane| Edit::Equalize { pane }),
            any_pane().prop_map(|pane| Edit::BreakPane { pane }),
            (1u64..4, prop::option::of(any_pane())).prop_map(|(window, pane)| Edit::Zoom {
                window: window_id(window),
                pane
            }),
            (any_pane(), any_pane()).prop_map(|(pane, other)| Edit::Swap { pane, other }),
            (any_pane(), any_pane(), edge.clone()).prop_map(|(pane, target, edge)| Edit::Dock {
                pane,
                target,
                edge
            }),
            (any_pane(), 1u64..4, edge.clone()).prop_map(|(pane, window, edge)| Edit::DockWindow {
                pane,
                window: window_id(window),
                edge
            }),
            (
                any_pane(),
                prop::option::of(0u16..30),
                prop::option::of(size.clone()),
                prop::option::of(0u32..9)
            )
                .prop_map(|(pane, x, cols, z)| Edit::Float {
                    pane,
                    x,
                    y: None,
                    cols,
                    rows: None,
                    z,
                    border: None,
                    title: None
                }),
            (any_pane(), any_pane(), edge).prop_map(|(pane, target, edge)| Edit::Unfloat {
                pane,
                target,
                edge
            }),
        ]
    }

    proptest! {
        #[test]
        fn an_edit_that_applies_keeps_every_live_pane_exactly_once(
            shape in trees(),
            edit in edits(12),
        ) {
            let mut draft = generated(&shape);
            let (before, _) = panes_of(&draft);
            if apply(&mut draft, &edit).is_ok() {
                let (after, fresh) = panes_of(&draft);
                prop_assert_eq!(after, before);
                prop_assert_eq!(fresh, usize::from(matches!(edit, Edit::Split { .. })));
            }
        }
    }
}

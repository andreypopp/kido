use std::cell::OnceCell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use ko_pane_wire::frame::{Dim, Size};

use crate::ids::{Name, PaneId, SessionId, WindowId};
use crate::protocol::{
    Axis, CellPixels, Cells, Command, CreatePane, DraftFloat, DraftLayout, DraftLeaf, DraftWindow,
    Float, Layout, Leaf, Node, PaneRef, PutLayout, Revision, Session, Snapshot, Tile, Window, pick,
};
use crate::vars::Vars;

const UNSIZED_WINDOW: Size = Size {
    cell_px: None,
    ..Size::DEFAULT
};

#[derive(Debug, Clone, Copy)]
struct Ids {
    pane: u64,
    session: u64,
    window: u64,
}

fn mint(counter: &mut u64) -> u64 {
    let id = *counter;
    *counter = counter.saturating_add(1);
    id
}

impl Ids {
    fn pane(&mut self) -> PaneId {
        PaneId::new(mint(&mut self.pane))
    }

    fn session(&mut self) -> SessionId {
        SessionId::new(mint(&mut self.session))
    }

    fn window(&mut self) -> WindowId {
        WindowId::new(mint(&mut self.window))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PutError {
    Stale,
    Invalid(String),
}

#[derive(Debug, Clone)]
pub(crate) struct Document {
    revision: Revision,
    unpublished: bool,
    layout: Layout,
    ids: Ids,
}

impl Window {
    pub(crate) fn single(&self) -> bool {
        matches!(self.tree, Node::Leaf(_)) && self.floats.is_empty()
    }
}

#[derive(Debug)]
pub(crate) struct Removal {
    pub(crate) panes: Vec<PaneId>,
    pub(crate) before: Layout,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Resized {
    Unknown,
    Same,
    Changed,
}

impl Document {
    pub(crate) fn new() -> Document {
        Document {
            revision: Revision::FIRST,
            unpublished: false,
            layout: Layout { sessions: vec![] },
            ids: Ids {
                pane: 1,
                session: 1,
                window: 1,
            },
        }
    }

    #[cfg(test)]
    pub(crate) fn empty() -> Document {
        Document::new()
    }

    #[cfg(test)]
    pub(crate) fn put(
        &mut self,
        request: PutLayout,
        new_window: Option<Size>,
    ) -> Result<Vec<(PaneId, CreatePane, Vars)>, PutError> {
        self.put_with_shell(request, new_window, &|| base_name("sh"))
    }

    pub(crate) fn layout(&self) -> &Layout {
        &self.layout
    }

    pub(crate) fn revision(&self) -> Revision {
        self.revision
    }

    pub(crate) fn snapshot(&self) -> Snapshot {
        Snapshot {
            revision: self.revision,
            layout: self.layout.clone(),
        }
    }

    pub(crate) fn put_with_shell(
        &mut self,
        request: PutLayout,
        new_window: Option<Size>,
        shell: &dyn Fn() -> Option<Name>,
    ) -> Result<Vec<(PaneId, CreatePane, Vars)>, PutError> {
        if request.revision != self.revision {
            return Err(PutError::Stale);
        }
        let normalized = normalize(
            request.layout,
            &self.layout,
            self.ids,
            shell,
            new_window.unwrap_or(UNSIZED_WINDOW),
        )
        .map_err(PutError::Invalid)?;
        self.ids = normalized.ids;
        self.replace(normalized.layout);
        Ok(normalized.created)
    }

    fn removal(&mut self, panes: Vec<PaneId>, change: impl FnOnce(&mut Layout)) -> Removal {
        let before = self.layout.clone();
        change(&mut self.layout);
        settle(&before, &mut self.layout);
        self.unpublished = true;
        Removal { panes, before }
    }

    pub(crate) fn remove_pane(&mut self, pane: PaneId) -> Option<Removal> {
        self.layout.locate(pane)?;
        Some(self.removal(vec![pane], |layout| remove_pane(layout, pane)))
    }

    pub(crate) fn remove_window(&mut self, window: WindowId) -> Option<Removal> {
        let panes = self.layout.window(window)?.1.panes();
        Some(self.removal(panes, |layout| {
            for session in &mut layout.sessions {
                session.windows.retain(|found| found.id != window);
            }
            prune(layout);
        }))
    }

    pub(crate) fn remove_session(&mut self, session: SessionId) -> Option<Removal> {
        let panes = self
            .layout
            .session(session)?
            .windows
            .iter()
            .flat_map(Window::panes)
            .collect();
        Some(self.removal(panes, |layout| {
            layout.sessions.retain(|found| found.id != session);
        }))
    }

    pub(crate) fn unpublished(&self) -> bool {
        self.unpublished
    }

    pub(crate) fn publish(&mut self) {
        if self.unpublished {
            self.unpublished = false;
            self.revision = self.revision.next();
        }
    }

    pub(crate) fn focus(&mut self, window: WindowId, pane: PaneId) -> bool {
        let Some(found) = self
            .layout
            .sessions
            .iter_mut()
            .flat_map(|session| &mut session.windows)
            .find(|candidate| candidate.id == window)
            .filter(|found| found.focus != pane && found.has(pane))
        else {
            return false;
        };
        found.focus = pane;
        true
    }

    pub(crate) fn rollback(&mut self, before: Document) {
        let ids = self.ids;
        *self = Document { ids, ..before };
    }

    pub(crate) fn resize_window(
        &mut self,
        window: WindowId,
        cols: Cells,
        rows: Cells,
        cell_px: Option<CellPixels>,
    ) -> Resized {
        let Some(found) = self
            .layout
            .sessions
            .iter_mut()
            .flat_map(|session| &mut session.windows)
            .find(|candidate| candidate.id == window)
        else {
            return Resized::Unknown;
        };
        let wanted = (usize::from(cols.get()), usize::from(rows.get()));
        if resize(found, wanted, cell_px) {
            self.unpublished = true;
            Resized::Changed
        } else {
            Resized::Same
        }
    }

    fn replace(&mut self, mut layout: Layout) {
        settle(&self.layout, &mut layout);
        if layout != self.layout {
            self.layout = layout;
            self.unpublished = true;
        }
    }
}

pub(crate) fn nearest<T: Copy>(order: &[T], at: usize, keep: impl Fn(&T) -> bool) -> Option<T> {
    order[at..]
        .iter()
        .chain(order[..at].iter().rev())
        .find(|item| keep(item))
        .copied()
}

pub(crate) fn shell_name(shell: &Path) -> Option<Name> {
    shell.to_str().and_then(base_name)
}

fn base_name(word: &str) -> Option<Name> {
    let base = Path::new(word).file_name()?.to_str()?;
    Name::try_from(base.to_owned()).ok()
}

fn prune(layout: &mut Layout) {
    layout
        .sessions
        .retain(|session| !session.windows.is_empty());
}

fn settle(before: &Layout, after: &mut Layout) {
    let olds: BTreeMap<WindowId, &Window> = before
        .windows()
        .map(|(_, window)| (window.id, window))
        .collect();
    for window in after
        .sessions
        .iter_mut()
        .flat_map(|session| &mut session.windows)
    {
        let Some(old) = olds.get(&window.id) else {
            continue;
        };
        if window.has(old.focus) {
            window.focus = old.focus;
            continue;
        }
        let (now, order) = (window.panes(), old.panes());
        if let Some(pane) = order
            .iter()
            .position(|pane| *pane == old.focus)
            .and_then(|at| nearest(&order, at, |pane| now.contains(pane)))
        {
            window.focus = pane;
        }
    }
}

struct Normalized {
    layout: Layout,
    created: Vec<(PaneId, CreatePane, Vars)>,
    ids: Ids,
}

struct Raw {
    pane: PaneId,
    cols: Option<usize>,
    rows: Option<usize>,
}

struct FloatIn {
    pane: PaneId,
    x: Option<usize>,
    y: Option<usize>,
    cols: Option<usize>,
    rows: Option<usize>,
    z: Option<u32>,
    border: bool,
    title: String,
}

impl Tile for Raw {
    fn pane_id(&self) -> Option<PaneId> {
        Some(self.pane)
    }

    fn extent(&self, axis: Axis) -> Option<usize> {
        pick(axis, self.cols, self.rows)
    }
}

fn shares(children: &[Node<Raw>], axis: Axis, total: usize) -> Vec<usize> {
    let count = children.len();
    let dividers = count.saturating_sub(1);
    let room = total.saturating_sub(dividers);
    let mut prefs: Vec<Option<usize>> = children.iter().map(|child| child.known(axis)).collect();
    if prefs.iter().all(Option::is_none) {
        prefs = (0..count)
            .map(|index| Some(room / count + usize::from(index < room % count)))
            .collect();
    }
    for index in 0..count {
        if prefs[index].is_some() {
            continue;
        }
        let donor = (0..index)
            .rev()
            .chain(index + 1..count)
            .find(|&other| prefs[other].is_some());
        let given = match donor.and_then(|other| prefs[other].map(|size| (other, size))) {
            Some((other, size)) if size >= 3 => {
                let given = size.div_ceil(2) - 1;
                prefs[other] = Some(size - 1 - given);
                given
            }
            _ => 1,
        };
        prefs[index] = Some(given);
    }
    let sizes: Vec<usize> = prefs.into_iter().flatten().collect();
    let sum = sizes.iter().sum::<usize>();
    let mins: Vec<usize> = children.iter().map(|child| child.minimum(axis)).collect();
    let mut left = total;
    let mut out = Vec::with_capacity(count);
    for (index, size) in sizes.iter().enumerate() {
        let share = if index + 1 == count {
            left
        } else {
            let after = count - 1 - index;
            let reserve = mins[index + 1..].iter().sum::<usize>() + after;
            (size * room / sum)
                .min(left.saturating_sub(reserve))
                .max(mins[index])
        };
        left = left.saturating_sub(share + 1);
        out.push(share);
    }
    out
}

fn fit(node: Node<Raw>, cols: usize, rows: usize) -> Node<Leaf> {
    match node {
        Node::Leaf(raw) => Node::Leaf(Leaf {
            pane: raw.pane,
            cols: Cells::clamped(cols),
            rows: Cells::clamped(rows),
        }),
        Node::Split { split, children } => {
            let along = shares(&children, split, pick(split, cols, rows));
            Node::Split {
                split,
                children: children
                    .into_iter()
                    .zip(along)
                    .map(|(child, share)| match split {
                        Axis::Horizontal => fit(child, share, rows),
                        Axis::Vertical => fit(child, cols, share),
                    })
                    .collect(),
            }
        }
    }
}

fn first_leaf<L>(node: &Node<L>) -> Option<&L> {
    match node {
        Node::Leaf(leaf) => Some(leaf),
        Node::Split { children, .. } => children.iter().find_map(first_leaf),
    }
}

fn raw(node: &Node<Leaf>) -> Node<Raw> {
    match node {
        Node::Leaf(leaf) => Node::Leaf(Raw {
            pane: leaf.pane,
            cols: Some(usize::from(leaf.cols.get())),
            rows: Some(usize::from(leaf.rows.get())),
        }),
        Node::Split { split, children } => Node::Split {
            split: *split,
            children: children.iter().map(raw).collect(),
        },
    }
}

fn place(floats: Vec<FloatIn>, cols: usize, rows: usize) -> Vec<Float> {
    let mut floats = floats;
    floats.sort_by_key(|float| float.z.unwrap_or(u32::MAX));
    floats
        .into_iter()
        .zip(0..)
        .map(|(float, z)| {
            let pad = usize::from(float.border);
            let size = |wanted: Option<usize>, window: usize| {
                let room = window.saturating_sub(2 * pad).max(1);
                wanted.unwrap_or(window.div_ceil(2)).clamp(1, room)
            };
            let (width, height) = (size(float.cols, cols), size(float.rows, rows));
            let offset = |wanted: Option<usize>, window: usize, extent: usize| {
                let offset = wanted.unwrap_or(window.saturating_sub(extent) / 2).max(pad);
                if offset + extent + pad <= window {
                    offset
                } else if extent + 2 * pad >= window {
                    pad
                } else {
                    window - extent - pad
                }
            };
            Float {
                pane: float.pane,
                x: u16::try_from(offset(float.x, cols, width)).unwrap_or(u16::MAX),
                y: u16::try_from(offset(float.y, rows, height)).unwrap_or(u16::MAX),
                cols: Cells::clamped(width),
                rows: Cells::clamped(height),
                z,
                border: float.border,
                title: float.title,
            }
        })
        .collect()
}

fn extent<L>(tree: &Node<L>, floats: bool, (cols, rows): (usize, usize)) -> (usize, usize) {
    let outer = if floats { 3 } else { 1 };
    (
        cols.max(tree.minimum(Axis::Horizontal)).max(outer),
        rows.max(tree.minimum(Axis::Vertical)).max(outer),
    )
}

fn resize(window: &mut Window, wanted: (usize, usize), cell_px: Option<CellPixels>) -> bool {
    let bordered = window.floats.iter().any(|float| float.border);
    let (cols, rows) = extent(&window.tree, bordered, wanted);
    let tree = fit(raw(&window.tree), cols, rows);
    let cell_px = cell_px.or(window.cell_px);
    let floats = window
        .floats
        .iter()
        .map(|float| FloatIn {
            pane: float.pane,
            x: Some(usize::from(float.x)),
            y: Some(usize::from(float.y)),
            cols: Some(usize::from(float.cols.get())),
            rows: Some(usize::from(float.rows.get())),
            z: Some(float.z),
            border: float.border,
            title: float.title.clone(),
        })
        .collect();
    let floats = place(floats, cols, rows);
    let (cols, rows) = (Cells::clamped(cols), Cells::clamped(rows));
    let changed = tree != window.tree
        || floats != window.floats
        || (cols, rows, cell_px) != (window.cols, window.rows, window.cell_px);
    if changed {
        (window.tree, window.floats) = (tree, floats);
        (window.cols, window.rows, window.cell_px) = (cols, rows, cell_px);
    }
    changed
}

fn grow(node: &mut Node<Leaf>, axis: Axis, delta: usize) {
    match node {
        Node::Leaf(leaf) => {
            let (cols, rows) = (usize::from(leaf.cols.get()), usize::from(leaf.rows.get()));
            match axis {
                Axis::Horizontal => leaf.cols = Cells::clamped(cols + delta),
                Axis::Vertical => leaf.rows = Cells::clamped(rows + delta),
            }
        }
        Node::Split { split, children } if *split == axis => {
            let count = children.len();
            for (index, child) in children.iter_mut().enumerate() {
                grow(
                    child,
                    axis,
                    delta / count + usize::from(index < delta % count),
                );
            }
        }
        Node::Split { children, .. } => {
            children
                .iter_mut()
                .for_each(|child| grow(child, axis, delta));
        }
    }
}

fn remove_leaf(node: Node<Leaf>, pane: PaneId) -> Option<Node<Leaf>> {
    match node {
        Node::Leaf(leaf) if leaf.pane == pane => None,
        Node::Leaf(_) => Some(node),
        Node::Split {
            split,
            mut children,
        } => {
            let Some(index) = children.iter().position(|child| child.contains(pane)) else {
                return Some(Node::Split { split, children });
            };
            let child = children.remove(index);
            match child {
                Node::Leaf(leaf) => {
                    let freed = pick(
                        split,
                        usize::from(leaf.cols.get()),
                        usize::from(leaf.rows.get()),
                    ) + 1;
                    let neighbour = index.min(children.len() - 1);
                    grow(&mut children[neighbour], split, freed);
                }
                Node::Split { .. } => {
                    if let Some(node) = remove_leaf(child, pane) {
                        children.insert(index, node);
                    }
                }
            }
            if children.len() == 1 {
                children.pop()
            } else {
                Some(Node::Split { split, children })
            }
        }
    }
}

fn remove_pane(layout: &mut Layout, pane: PaneId) {
    let Some((session, window)) = layout.sessions.iter().enumerate().find_map(|(s, session)| {
        let w = session.windows.iter().position(|window| window.has(pane))?;
        Some((s, w))
    }) else {
        return;
    };
    let windows = &mut layout.sessions[session].windows;
    let target = &mut windows[window];
    if let Some(index) = target.floats.iter().position(|float| float.pane == pane) {
        target.floats.remove(index);
    } else {
        let tree = std::mem::replace(
            &mut target.tree,
            Node::Split {
                split: Axis::Horizontal,
                children: vec![],
            },
        );
        match remove_leaf(tree, pane) {
            Some(node) => target.tree = node,
            None if target.floats.is_empty() => {
                windows.remove(window);
                prune(layout);
                return;
            }
            None => {
                let float = target.floats.remove(0);
                target.tree = Node::Leaf(Leaf {
                    pane: float.pane,
                    cols: target.cols,
                    rows: target.rows,
                });
            }
        }
    }
    for (float, z) in target.floats.iter_mut().zip(0..) {
        float.z = z;
    }
    if target.zoom == Some(pane) {
        target.zoom = None;
    }
}

struct Claims<'a> {
    current: &'a Layout,
    shell: &'a dyn Fn() -> Option<Name>,
    shell_name: OnceCell<Option<Name>>,
    live: &'a BTreeSet<PaneId>,
    seen: BTreeSet<PaneId>,
    ids: Ids,
    created: Vec<(PaneId, CreatePane, Vars)>,
}

impl Claims<'_> {
    fn default_name(&self, first: &PaneRef) -> Option<Name> {
        let shell = || self.shell_name.get_or_init(self.shell).clone();
        let word = match first {
            PaneRef::Existing(pane) => {
                return self
                    .current
                    .locate(*pane)
                    .map_or_else(shell, |(_, window)| Some(window.name.clone()));
            }
            PaneRef::New { new } => match &new.command {
                None => return shell(),
                Some(Command::Argv { argv }) => argv.first().map(String::as_str),
                Some(Command::Shell { command }) => command.split_whitespace().next(),
            },
        };
        word.and_then(base_name).or_else(shell)
    }

    fn pane(&mut self, reference: PaneRef) -> Result<PaneId, String> {
        let pane = match reference {
            PaneRef::Existing(pane) if self.live.contains(&pane) => pane,
            PaneRef::Existing(pane) => return Err(format!("{pane} is not a live pane")),
            PaneRef::New { mut new } => {
                let vars = Vars::checked(std::mem::take(&mut new.vars))?;
                let pane = self.ids.pane();
                self.created.push((pane, new, vars));
                pane
            }
        };
        if !self.seen.insert(pane) {
            return Err(format!("{pane} is in the layout twice"));
        }
        Ok(pane)
    }

    fn node(&mut self, node: Node<DraftLeaf>) -> Result<Node<Raw>, String> {
        match node {
            Node::Leaf(leaf) => Ok(Node::Leaf(Raw {
                pane: self.pane(leaf.pane)?,
                cols: leaf.cols.map(|cells| usize::from(cells.get())),
                rows: leaf.rows.map(|cells| usize::from(cells.get())),
            })),
            Node::Split { split, children } => {
                let mut children = children
                    .into_iter()
                    .map(|child| self.node(child))
                    .collect::<Result<Vec<_>, _>>()?;
                match children.len() {
                    0 => Err("a split needs a child".to_owned()),
                    1 => Ok(children.remove(0)),
                    _ => Ok(Node::Split { split, children }),
                }
            }
        }
    }
}

fn window(
    draft: DraftWindow,
    id: WindowId,
    previous: Option<&Window>,
    new_window: Size,
    claims: &mut Claims<'_>,
) -> Result<Window, String> {
    let name = match (draft.name, previous) {
        (Some(name), _) => name,
        (None, Some(old)) => old.name.clone(),
        (None, None) => first_leaf(&draft.tree)
            .and_then(|leaf| claims.default_name(&leaf.pane))
            .ok_or("the window needs a name")?,
    };
    let tree = claims.node(draft.tree)?;
    let focus = first_leaf(&tree).ok_or("a window needs a pane")?.pane;
    let mut floats = vec![];
    for float in draft.floats {
        let DraftFloat {
            pane,
            x,
            y,
            cols,
            rows,
            z,
            border,
            title,
        } = float;
        floats.push(FloatIn {
            pane: claims.pane(pane)?,
            x: x.map(usize::from),
            y: y.map(usize::from),
            cols: cols.map(|cells| usize::from(cells.get())),
            rows: rows.map(|cells| usize::from(cells.get())),
            z,
            border,
            title,
        });
    }
    let wanted = |given: Option<Cells>, old: Option<Cells>, default: Dim| {
        usize::from(given.or(old).map_or(default.get(), Cells::get))
    };
    let bordered = floats.iter().any(|float| float.border);
    let (cols, rows) = extent(
        &tree,
        bordered,
        (
            wanted(draft.cols, previous.map(|old| old.cols), new_window.cols),
            wanted(draft.rows, previous.map(|old| old.rows), new_window.rows),
        ),
    );
    if cols > usize::from(Dim::MAX.get()) || rows > usize::from(Dim::MAX.get()) {
        return Err(format!(
            "{id} needs {cols}x{rows} cells, more than the limit"
        ));
    }
    let built = Window {
        id,
        name,
        vars: Vars::checked(draft.vars)?,
        cols: Cells::clamped(cols),
        rows: Cells::clamped(rows),
        cell_px: draft
            .cell_px
            .or(previous.map_or(new_window.cell_px.map(CellPixels), |old| old.cell_px)),
        zoom: draft.zoom,
        focus,
        tree: fit(tree, cols, rows),
        floats: place(floats, cols, rows),
    };
    match built.zoom {
        Some(zoom) if !built.has(zoom) => Err(format!("{zoom} is not in {id}")),
        _ => Ok(built),
    }
}

fn normalize(
    draft: DraftLayout,
    current: &Layout,
    ids: Ids,
    shell: &dyn Fn() -> Option<Name>,
    new_window: Size,
) -> Result<Normalized, String> {
    let live = current.panes();
    let mut claims = Claims {
        current,
        shell,
        shell_name: OnceCell::new(),
        live: &live,
        seen: BTreeSet::new(),
        ids,
        created: vec![],
    };
    let mut session_ids = BTreeSet::new();
    let mut window_ids = BTreeSet::new();
    let mut sessions = vec![];
    for draft in draft.sessions {
        let id = match draft.id {
            Some(id) if current.session(id).is_some() => id,
            Some(id) => return Err(format!("{id} is not a session")),
            None => claims.ids.session(),
        };
        if !session_ids.insert(id) {
            return Err(format!("{id} is in the layout twice"));
        }
        if draft.windows.is_empty() {
            return Err(format!("{id} needs a window"));
        }
        let mut windows = vec![];
        for draft in draft.windows {
            let id = match draft.id {
                Some(id) if current.window(id).is_some() => id,
                Some(id) => return Err(format!("{id} is not a window")),
                None => claims.ids.window(),
            };
            if !window_ids.insert(id) {
                return Err(format!("{id} is in the layout twice"));
            }
            windows.push(self::window(
                draft,
                id,
                current.window(id).map(|(_, window)| window),
                new_window,
                &mut claims,
            )?);
        }
        sessions.push(Session {
            id,
            name: draft.name,
            vars: Vars::checked(draft.vars)?,
            windows,
        });
    }
    if let Some(pane) = live.iter().find(|pane| !claims.seen.contains(pane)) {
        return Err(format!("{pane} is in no window"));
    }
    Ok(Normalized {
        layout: Layout { sessions },
        created: claims.created,
        ids: claims.ids,
    })
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;
    use serde_json::{Value, json};

    use super::*;
    use crate::protocol::Cwd;
    use ko_config::values::AbsPath;

    fn new_pane() -> Value {
        json!({"new": {}})
    }

    fn leaf(pane: Value, cols: u16, rows: u16) -> Value {
        json!({"pane": pane, "cols": cols, "rows": rows})
    }

    fn unsized_leaf(pane: Value) -> Value {
        json!({"pane": pane})
    }

    fn split(axis: &str, children: Vec<Value>) -> Value {
        json!({"split": axis, "children": children})
    }

    fn window(tree: Value) -> Value {
        json!({"name": "w", "tree": tree})
    }

    fn session(windows: Vec<Value>) -> Value {
        json!({"name": "s", "windows": windows})
    }

    fn request(document: &Document, sessions: Vec<Value>) -> PutLayout {
        serde_json::from_value(json!({
            "revision": document.snapshot().revision,
            "layout": {"sessions": sessions},
        }))
        .unwrap()
    }

    fn document_of(window: Value) -> Document {
        let mut document = Document::empty();
        document
            .put(request(&document, vec![session(vec![window])]), None)
            .unwrap();
        document.publish();
        document
    }

    fn edit(
        document: &mut Document,
        tree: Value,
    ) -> Result<Vec<(PaneId, CreatePane, Vars)>, PutError> {
        let mut edited = window(tree);
        edited["id"] = json!("window_1");
        let mut named = session(vec![edited]);
        named["id"] = json!("session_1");
        let created = document.put(request(document, vec![named]), None)?;
        document.publish();
        Ok(created)
    }

    fn first_window(document: &Document) -> Window {
        document.snapshot().layout.sessions[0].windows[0].clone()
    }

    fn shape(node: &Node<Leaf>) -> String {
        match node {
            Node::Leaf(leaf) => format!(
                "{}:{}x{}",
                leaf.pane.to_string().trim_start_matches("pane_"),
                leaf.cols.get(),
                leaf.rows.get()
            ),
            Node::Split { split, children } => format!(
                "{}[{}]",
                match split {
                    Axis::Horizontal => "h",
                    Axis::Vertical => "v",
                },
                children.iter().map(shape).collect::<Vec<_>>().join(" ")
            ),
        }
    }

    fn tree_shape(document: &Document) -> String {
        shape(&first_window(document).tree)
    }

    fn invalid(document: &mut Document, sessions: Vec<Value>) -> String {
        match document.put(request(document, sessions), None) {
            Err(PutError::Invalid(message)) => message,
            other => panic!("expected invalid, got {other:?}"),
        }
    }

    fn dims(node: &Node<Leaf>) -> (usize, usize) {
        match node {
            Node::Leaf(leaf) => (usize::from(leaf.cols.get()), usize::from(leaf.rows.get())),
            Node::Split { split, children } => {
                assert!(children.len() >= 2);
                let sizes: Vec<_> = children.iter().map(dims).collect();
                let count = sizes.len() - 1;
                match split {
                    Axis::Horizontal => {
                        assert!(sizes.iter().all(|size| size.1 == sizes[0].1));
                        (
                            sizes.iter().map(|size| size.0).sum::<usize>() + count,
                            sizes[0].1,
                        )
                    }
                    Axis::Vertical => {
                        assert!(sizes.iter().all(|size| size.0 == sizes[0].0));
                        (
                            sizes[0].0,
                            sizes.iter().map(|size| size.1).sum::<usize>() + count,
                        )
                    }
                }
            }
        }
    }

    fn check(layout: &Layout) {
        let mut seen = BTreeSet::new();
        for window in layout.sessions.iter().flat_map(|session| &session.windows) {
            assert_eq!(
                dims(&window.tree),
                (
                    usize::from(window.cols.get()),
                    usize::from(window.rows.get())
                )
            );
            let panes = window.panes();
            assert!(panes.iter().all(|pane| seen.insert(*pane)));
            assert!(window.zoom.is_none_or(|zoom| panes.contains(&zoom)));
            for (z, float) in window.floats.iter().enumerate() {
                assert_eq!(usize::try_from(float.z).unwrap(), z);
                let pad = usize::from(float.border);
                let (x, cols) = (usize::from(float.x), usize::from(float.cols.get()));
                let (y, rows) = (usize::from(float.y), usize::from(float.rows.get()));
                let (width, height) = (
                    usize::from(window.cols.get()),
                    usize::from(window.rows.get()),
                );
                assert!(x >= pad && x + cols + pad <= width);
                assert!(y >= pad && y + rows + pad <= height);
            }
        }
    }

    #[test]
    fn recorded_trees_come_back_unchanged() {
        let recorded = [
            (
                split(
                    "h",
                    vec![leaf(new_pane(), 40, 24), leaf(new_pane(), 39, 24)],
                ),
                (80, 24),
                "h[1:40x24 2:39x24]",
            ),
            (
                split(
                    "v",
                    vec![leaf(new_pane(), 80, 12), leaf(new_pane(), 80, 11)],
                ),
                (80, 24),
                "v[1:80x12 2:80x11]",
            ),
            (
                split(
                    "v",
                    vec![
                        split(
                            "h",
                            vec![leaf(new_pane(), 20, 20), leaf(new_pane(), 179, 20)],
                        ),
                        leaf(new_pane(), 200, 59),
                    ],
                ),
                (200, 80),
                "v[h[1:20x20 2:179x20] 3:200x59]",
            ),
        ];
        for (tree, (cols, rows), expected) in recorded {
            let mut tree_window = window(tree);
            tree_window["cols"] = json!(cols);
            tree_window["rows"] = json!(rows);
            let mut document = document_of(tree_window);
            assert_eq!(tree_shape(&document), expected);
            let before = document.snapshot();
            document
                .put(
                    serde_json::from_value(json!({
                        "revision": before.revision,
                        "layout": before.layout,
                    }))
                    .unwrap(),
                    None,
                )
                .unwrap();
            assert_eq!(document.snapshot(), before);
        }
    }

    #[test]
    fn a_recorded_float_keeps_its_place_above_a_split() {
        let mut floating = window(split(
            "v",
            vec![leaf(new_pane(), 80, 12), leaf(new_pane(), 80, 11)],
        ));
        floating["floats"] = json!([{"pane": new_pane(), "x": 6, "y": 4, "cols": 28, "rows": 8}]);
        let document = document_of(floating);
        let window = first_window(&document);
        assert_eq!(shape(&window.tree), "v[1:80x12 2:80x11]");
        assert_eq!(
            serde_json::to_value(&window.floats).unwrap(),
            json!([{"pane": "pane_3", "x": 6, "y": 4, "cols": 28, "rows": 8, "z": 0,
                    "border": false, "title": ""}])
        );
    }

    #[test]
    fn a_new_leaf_beside_an_old_one_takes_half() {
        let old = || leaf(json!("pane_1"), 80, 24);
        for (children, expected) in [
            (vec![old(), unsized_leaf(new_pane())], "h[1:40x24 2:39x24]"),
            (vec![unsized_leaf(new_pane()), old()], "h[2:39x24 1:40x24]"),
        ] {
            let mut document = document_of(window(unsized_leaf(new_pane())));
            assert_eq!(tree_shape(&document), "1:80x24");
            edit(&mut document, split("h", children)).unwrap();
            assert_eq!(tree_shape(&document), expected);
        }
        let mut document = document_of(window(unsized_leaf(new_pane())));
        let nested = split(
            "v",
            vec![
                old(),
                split(
                    "h",
                    vec![unsized_leaf(new_pane()), unsized_leaf(new_pane())],
                ),
            ],
        );
        edit(&mut document, nested).unwrap();
        assert_eq!(tree_shape(&document), "v[1:80x12 h[2:40x11 3:39x11]]");
    }

    #[test]
    fn ids_are_minted_in_document_order() {
        let mut document = document_of(window(unsized_leaf(new_pane())));
        let created = edit(
            &mut document,
            split(
                "h",
                vec![
                    leaf(json!("pane_1"), 80, 24),
                    unsized_leaf(json!({"new": {"cwd": "/tmp"}})),
                ],
            ),
        )
        .unwrap();
        assert_eq!(
            created
                .iter()
                .map(|(pane, ..)| pane.to_string())
                .collect::<Vec<_>>(),
            ["pane_2"]
        );
        assert_eq!(
            created[0].1.cwd,
            Some(Cwd::Path(AbsPath::try_from("/tmp".to_owned()).unwrap()))
        );
    }

    #[test]
    fn children_without_sizes_share_equally_and_the_first_take_the_remainder() {
        let three = |cols: u16| {
            let mut tree_window = window(split(
                "h",
                (0..3).map(|_| unsized_leaf(new_pane())).collect(),
            ));
            tree_window["cols"] = json!(cols);
            document_of(tree_window)
        };
        assert_eq!(tree_shape(&three(80)), "h[1:26x24 2:26x24 3:26x24]");
        assert_eq!(tree_shape(&three(81)), "h[1:27x24 2:26x24 3:26x24]");
    }

    #[test]
    fn sizes_that_do_not_fit_scale_proportionally_without_the_dividers() {
        let mut tree_window = window(split(
            "h",
            vec![leaf(new_pane(), 40, 24), leaf(new_pane(), 39, 24)],
        ));
        tree_window["cols"] = json!(100);
        tree_window["rows"] = json!(30);
        assert_eq!(tree_shape(&document_of(tree_window)), "h[1:50x30 2:49x30]");
        let mut tree_window = window(split(
            "h",
            vec![leaf(new_pane(), 60, 24), leaf(new_pane(), 20, 24)],
        ));
        tree_window["cols"] = json!(40);
        assert_eq!(tree_shape(&document_of(tree_window)), "h[1:29x24 2:10x24]");
    }

    #[test]
    fn a_window_grows_to_hold_one_cell_per_pane() {
        let mut tree_window = window(split(
            "h",
            (0..4).map(|_| unsized_leaf(new_pane())).collect(),
        ));
        tree_window["cols"] = json!(3);
        let document = document_of(tree_window);
        assert_eq!(tree_shape(&document), "h[1:1x24 2:1x24 3:1x24 4:1x24]");
        assert_eq!(first_window(&document).cols.get(), 7);
    }

    #[test]
    fn floats_are_clamped_into_the_window_and_ordered_by_z() {
        let mut tree_window = window(unsized_leaf(new_pane()));
        tree_window["floats"] = json!([
            {"pane": new_pane(), "x": 70, "y": 20, "cols": 30, "rows": 4, "z": 9},
            {"pane": new_pane(), "border": true, "x": 0, "y": 0, "cols": 200, "rows": 200,
             "z": 2, "title": "t"},
            {"pane": new_pane()},
        ]);
        let floats = first_window(&document_of(tree_window)).floats;
        let shaped: Vec<_> = floats
            .iter()
            .map(|float| {
                (
                    float.pane.to_string(),
                    (
                        float.x,
                        float.y,
                        float.cols.get(),
                        float.rows.get(),
                        float.z,
                    ),
                )
            })
            .collect();
        assert_eq!(
            shaped,
            [
                ("pane_3".to_owned(), (1, 1, 78, 22, 0)),
                ("pane_2".to_owned(), (50, 20, 30, 4, 1)),
                ("pane_4".to_owned(), (20, 6, 40, 12, 2)),
            ]
        );
        assert!(floats[0].border && floats[0].title == "t");
    }

    #[test]
    fn a_bordered_float_and_its_border_fit_in_the_window() {
        let mut tree_window = window(unsized_leaf(new_pane()));
        tree_window["cols"] = json!(1);
        tree_window["rows"] = json!(1);
        tree_window["floats"] = json!([{"pane": new_pane(), "border": true, "cols": 5, "rows": 5}]);
        let mut document = document_of(tree_window);
        let shown = first_window(&document);
        assert_eq!((shown.cols.get(), shown.rows.get()), (3, 3));
        assert_eq!(
            (
                shown.floats[0].x,
                shown.floats[0].y,
                shown.floats[0].cols.get()
            ),
            (1, 1, 1)
        );
        let size = |count| Cells::new(count).unwrap();
        document.resize_window(WindowId::new(1), size(1), size(1), None);
        check(document.layout());
        assert_eq!(first_window(&document).cols.get(), 3);
    }

    #[test]
    fn a_broken_structure_is_refused_and_changes_nothing() {
        let mut document = document_of(window(split(
            "h",
            vec![unsized_leaf(new_pane()), unsized_leaf(new_pane())],
        )));
        let before = document.snapshot();
        let with_ids = |tree: Value| {
            let mut edited = window(tree);
            edited["id"] = json!("window_1");
            let mut named = session(vec![edited]);
            named["id"] = json!("session_1");
            vec![named]
        };
        let bare = |pane: &str| unsized_leaf(json!(pane));
        let cases = [
            (with_ids(bare("pane_1")), "pane_2 is in no window"),
            (
                with_ids(split(
                    "h",
                    vec![bare("pane_1"), bare("pane_1"), bare("pane_2")],
                )),
                "pane_1 is in the layout twice",
            ),
            (
                with_ids(split("h", vec![bare("pane_1"), bare("pane_9")])),
                "pane_9 is not a live pane",
            ),
            (with_ids(split("h", vec![])), "a split needs a child"),
            (vec![json!({"name": "s", "windows": []})], "needs a window"),
        ];
        for (sessions, message) in cases {
            assert!(
                invalid(&mut document, sessions.clone()).contains(message),
                "{sessions:?}"
            );
        }
        let mut stray = with_ids(split("h", vec![bare("pane_1"), bare("pane_2")]));
        stray[0]["windows"][0]["id"] = json!("window_9");
        assert_eq!(
            invalid(&mut document, stray.clone()),
            "window_9 is not a window"
        );
        stray[0]["windows"][0]["id"] = json!("window_1");
        stray[0]["windows"][0]["zoom"] = json!("pane_7");
        assert_eq!(
            invalid(&mut document, stray.clone()),
            "pane_7 is not in window_1"
        );
        stray[0]["windows"][0]["zoom"] = Value::Null;
        stray[0]["id"] = json!("session_8");
        assert_eq!(invalid(&mut document, stray), "session_8 is not a session");
        assert_eq!(document.snapshot(), before);
    }

    #[test]
    fn a_window_too_big_is_refused() {
        let mut document = Document::empty();
        let wide = split("h", (0..2100).map(|_| unsized_leaf(new_pane())).collect());
        assert!(
            invalid(&mut document, vec![session(vec![window(wide)])])
                .contains("more than the limit")
        );
        assert_eq!(document.snapshot().layout.sessions.len(), 0);
    }

    #[test]
    fn names_and_sizes_are_checked_when_the_body_decodes() {
        let body = |name: &str, cols: u16| {
            json!({"revision": 0, "layout": {"sessions": [{"name": name, "windows": [
                {"name": "w", "cols": cols, "tree": {"pane": {"new": {}}}}]}]}})
            .to_string()
        };
        assert!(crate::protocol::decode::<PutLayout>(body("ok", 80).as_bytes()).is_ok());
        for bad in [
            body("a\nb", 80),
            body(&"x".repeat(257), 80),
            body("ok", 0),
            body("ok", 4097),
        ] {
            assert!(
                crate::protocol::decode::<PutLayout>(bad.as_bytes()).is_err(),
                "{bad}"
            );
        }
    }

    #[test]
    fn a_rollback_keeps_the_ids_that_were_handed_out() {
        let mut document = document_of(window(unsized_leaf(new_pane())));
        let before = document.clone();
        let created = edit(
            &mut document,
            split(
                "h",
                vec![leaf(json!("pane_1"), 80, 24), unsized_leaf(new_pane())],
            ),
        )
        .unwrap();
        assert_eq!(created[0].0.to_string(), "pane_2");
        document.rollback(before);
        assert_eq!(document.revision(), Revision::FIRST.next());
        assert!(!document.unpublished());
        assert_eq!(tree_shape(&document), "1:80x24");
        let created = edit(
            &mut document,
            split(
                "h",
                vec![leaf(json!("pane_1"), 80, 24), unsized_leaf(new_pane())],
            ),
        )
        .unwrap();
        assert_eq!(created[0].0.to_string(), "pane_3");
    }

    #[test]
    fn a_stale_revision_is_refused_and_an_unchanged_document_keeps_its_revision() {
        let mut document = document_of(window(unsized_leaf(new_pane())));
        let first = document.snapshot().revision;
        let stale = request(&document, vec![]);
        assert_eq!(
            document.put(
                PutLayout {
                    revision: Revision::FIRST,
                    ..stale
                },
                None
            ),
            Err(PutError::Stale)
        );
        let again = json!({"revision": first, "layout": document.snapshot().layout});
        document
            .put(serde_json::from_value(again).unwrap(), None)
            .unwrap();
        assert_eq!(document.snapshot().revision, first);
        edit(
            &mut document,
            split(
                "h",
                vec![leaf(json!("pane_1"), 80, 24), unsized_leaf(new_pane())],
            ),
        )
        .unwrap();
        assert_eq!(document.snapshot().revision, first.next());
    }

    #[test]
    fn removing_a_pane_gives_its_cells_to_the_sibling_and_collapses_the_split() {
        let mut tree_window = window(split(
            "v",
            vec![
                split(
                    "h",
                    vec![leaf(new_pane(), 20, 20), leaf(new_pane(), 179, 20)],
                ),
                leaf(new_pane(), 200, 59),
            ],
        ));
        tree_window["cols"] = json!(200);
        tree_window["rows"] = json!(80);
        let mut document = document_of(tree_window);
        let revision = document.snapshot().revision;
        assert!(document.remove_pane(PaneId::new(1)).is_some());
        assert_eq!(tree_shape(&document), "v[2:200x20 3:200x59]");
        assert_eq!(document.snapshot().revision, revision);
        document.publish();
        assert_eq!(document.snapshot().revision, revision.next());
        assert!(document.remove_pane(PaneId::new(1)).is_none());
        assert!(document.remove_pane(PaneId::new(3)).is_some());
        assert_eq!(tree_shape(&document), "2:200x80");
        assert!(document.remove_pane(PaneId::new(2)).is_some());
        assert_eq!(document.snapshot().layout.sessions, vec![]);
    }

    #[test]
    fn a_neighbour_that_is_a_split_takes_the_cells_on_its_own_axis() {
        let mut tree_window = window(split(
            "h",
            vec![
                leaf(new_pane(), 10, 24),
                split(
                    "v",
                    vec![leaf(new_pane(), 69, 12), leaf(new_pane(), 69, 11)],
                ),
            ],
        ));
        tree_window["cols"] = json!(80);
        let mut document = document_of(tree_window);
        document.remove_pane(PaneId::new(1));
        assert_eq!(tree_shape(&document), "v[2:80x12 3:80x11]");
        let mut tree_window = window(split(
            "h",
            vec![
                split(
                    "h",
                    vec![leaf(new_pane(), 10, 24), leaf(new_pane(), 10, 24)],
                ),
                leaf(new_pane(), 58, 24),
            ],
        ));
        tree_window["cols"] = json!(80);
        let mut document = document_of(tree_window);
        document.remove_pane(PaneId::new(3));
        assert_eq!(tree_shape(&document), "h[1:40x24 2:39x24]");
    }

    #[test]
    fn removing_a_float_or_the_last_tiled_pane_keeps_the_rest_of_the_window() {
        let mut tree_window = window(unsized_leaf(new_pane()));
        tree_window["floats"] = json!([{"pane": new_pane()}, {"pane": new_pane(), "z": 5}]);
        tree_window["zoom"] = Value::Null;
        let mut document = document_of(tree_window);
        assert!(document.remove_pane(PaneId::new(2)).is_some());
        assert_eq!(first_window(&document).floats.len(), 1);
        assert!(document.remove_pane(PaneId::new(1)).is_some());
        let window = first_window(&document);
        assert_eq!(shape(&window.tree), "3:80x24");
        assert_eq!(window.floats, vec![]);
    }

    #[test]
    fn removing_the_zoomed_pane_ends_the_zoom_and_the_last_window_takes_its_session() {
        let mut first = window(split(
            "h",
            vec![unsized_leaf(new_pane()), unsized_leaf(new_pane())],
        ));
        first["zoom"] = json!("pane_1");
        let mut document = Document::empty();
        document
            .put(
                request(
                    &document,
                    vec![session(vec![first, window(unsized_leaf(new_pane()))])],
                ),
                None,
            )
            .unwrap();
        document.remove_pane(PaneId::new(1));
        assert_eq!(first_window(&document).zoom, None);
        document.remove_pane(PaneId::new(2));
        let remaining = &document.snapshot().layout.sessions[0].windows;
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].id.to_string(), "window_2");
    }

    #[test]
    fn resizing_scales_the_tree_and_the_floats_and_keeps_the_pixels() {
        let mut tree_window = window(split(
            "h",
            vec![leaf(new_pane(), 40, 24), leaf(new_pane(), 39, 24)],
        ));
        tree_window["floats"] =
            json!([{"pane": new_pane(), "x": 60, "y": 10, "cols": 20, "rows": 10}]);
        let mut document = document_of(tree_window);
        let pixels = CellPixels(ko_pane_wire::frame::CellPx::DEFAULT);
        let size = |count| Cells::new(count).unwrap();
        assert_eq!(
            document.resize_window(WindowId::new(1), size(100), size(30), Some(pixels)),
            Resized::Changed
        );
        let resized = first_window(&document);
        assert_eq!(shape(&resized.tree), "h[1:50x30 2:49x30]");
        assert_eq!((resized.floats[0].x, resized.floats[0].y), (60, 10));
        assert_eq!(resized.cell_px, Some(pixels));
        assert_eq!(
            document.resize_window(WindowId::new(1), size(30), size(8), None),
            Resized::Changed
        );
        let resized = first_window(&document);
        assert_eq!(shape(&resized.tree), "h[1:14x8 2:15x8]");
        assert_eq!(
            (
                resized.floats[0].x,
                resized.floats[0].y,
                resized.floats[0].cols.get()
            ),
            (10, 0, 20)
        );
        assert_eq!(resized.cell_px, Some(pixels));
        assert_eq!(
            document.resize_window(WindowId::new(9), size(30), size(8), None),
            Resized::Unknown
        );
        assert_eq!(
            document.resize_window(WindowId::new(1), size(30), size(8), None),
            Resized::Same
        );
    }

    #[test]
    fn a_row_scaled_to_one_column_for_each_pane_scales_back() {
        let mut tree_window = window(split(
            "h",
            vec![
                unsized_leaf(new_pane()),
                split(
                    "v",
                    vec![unsized_leaf(new_pane()), unsized_leaf(new_pane())],
                ),
                unsized_leaf(new_pane()),
            ],
        ));
        tree_window["cols"] = json!(90);
        let mut document = document_of(tree_window);
        let size = |count| Cells::new(count).unwrap();
        document.resize_window(WindowId::new(1), size(1), size(1), None);
        let narrow = first_window(&document);
        assert_eq!(shape(&narrow.tree), "h[1:1x3 v[2:1x1 3:1x1] 4:1x3]");
        assert_eq!((narrow.cols.get(), narrow.rows.get()), (5, 3));
        document.resize_window(WindowId::new(1), size(90), size(24), None);
        assert_eq!(
            tree_shape(&document),
            "h[1:29x24 v[2:29x11 3:29x12] 4:30x24]"
        );
        check(&document.snapshot().layout);
    }

    fn two_sessions() -> Document {
        let mut document = Document::empty();
        document
            .put(
                request(
                    &document,
                    vec![
                        session(vec![
                            window(split(
                                "h",
                                vec![unsized_leaf(new_pane()), unsized_leaf(new_pane())],
                            )),
                            window(unsized_leaf(new_pane())),
                        ]),
                        session(vec![window(unsized_leaf(new_pane()))]),
                    ],
                ),
                None,
            )
            .unwrap();
        document.publish();
        document
    }

    #[test]
    fn deleting_a_window_or_a_session_is_one_change_that_returns_its_panes() {
        let mut document = two_sessions();
        let revision = document.revision();
        assert_eq!(
            document
                .remove_window(WindowId::new(9))
                .map(|removed| removed.panes),
            None
        );
        assert_eq!(
            document
                .remove_session(SessionId::new(9))
                .map(|removed| removed.panes),
            None
        );
        assert_eq!(document.revision(), revision);
        assert_eq!(
            document
                .remove_window(WindowId::new(1))
                .map(|removed| removed.panes),
            Some(vec![PaneId::new(1), PaneId::new(2)])
        );
        document.publish();
        assert_eq!(document.revision(), revision.next());
        assert_eq!(document.layout().sessions[0].windows.len(), 1);
        assert_eq!(
            document
                .remove_window(WindowId::new(3))
                .map(|removed| removed.panes),
            Some(vec![PaneId::new(4)])
        );
        document.publish();
        assert_eq!(document.revision(), revision.next().next());
        assert_eq!(document.layout().sessions.len(), 1);
        assert_eq!(
            document
                .remove_window(WindowId::new(2))
                .map(|removed| removed.panes),
            Some(vec![PaneId::new(3)])
        );
        assert_eq!(document.layout().sessions, vec![]);
        let mut document = two_sessions();
        assert_eq!(
            document
                .remove_session(SessionId::new(1))
                .map(|removed| removed.panes),
            Some(vec![PaneId::new(1), PaneId::new(2), PaneId::new(3)])
        );
        assert_eq!(document.layout().sessions.len(), 1);
        assert_eq!(document.layout().sessions[0].id, SessionId::new(2));
    }

    #[test]
    fn a_window_is_focused_on_the_first_pane_until_a_focus_is_noted_and_a_put_cannot_change_it() {
        let mut document = two_sessions();
        let window = WindowId::new(1);
        let focus = |document: &Document| document.layout().window(window).unwrap().1.focus;
        assert_eq!(focus(&document), PaneId::new(1));
        let revision = document.revision();
        assert!(!document.focus(window, PaneId::new(1)));
        assert!(!document.focus(window, PaneId::new(3)));
        assert_eq!(document.revision(), revision);
        assert!(document.focus(window, PaneId::new(2)));
        assert_eq!(focus(&document), PaneId::new(2));
        assert!(!document.unpublished());
        assert_eq!(document.revision(), revision);

        let mut sent = serde_json::to_value(document.snapshot()).unwrap();
        sent["layout"]["sessions"][0]["windows"][0]["focus"] = json!("pane_1");
        sent["layout"]["sessions"][0]["windows"][1]["focus"] = json!("pane_99");
        document
            .put(serde_json::from_value(sent).unwrap(), None)
            .unwrap();
        assert_eq!(focus(&document), PaneId::new(2));
        assert!(!document.unpublished());
        assert_eq!(document.revision(), revision);
    }

    #[test]
    fn the_focus_passes_to_the_next_pane_in_order_when_its_pane_goes() {
        let source = document_of(window(split(
            "h",
            vec![
                unsized_leaf(new_pane()),
                unsized_leaf(new_pane()),
                unsized_leaf(new_pane()),
            ],
        )));
        for (focused, gone, expected) in [(2, 2, 3), (3, 3, 2), (1, 1, 2), (2, 3, 2)] {
            let mut document = source.clone();
            document.focus(WindowId::new(1), PaneId::new(focused));
            document.remove_pane(PaneId::new(gone));
            assert_eq!(
                first_window(&document).focus,
                PaneId::new(expected),
                "{focused} {gone}"
            );
        }
    }

    #[test]
    fn the_focus_of_a_pane_moved_out_of_its_window_falls_to_a_pane_that_stays() {
        let mut document = two_sessions();
        document.focus(WindowId::new(1), PaneId::new(2));
        let mut moved = serde_json::to_value(document.snapshot()).unwrap();
        let tree = moved["layout"]["sessions"][0]["windows"][1]["tree"].take();
        moved["layout"]["sessions"][0]["windows"][1]["tree"] =
            split("h", vec![tree, unsized_leaf(json!("pane_2"))]);
        moved["layout"]["sessions"][0]["windows"][0]["tree"] = unsized_leaf(json!("pane_1"));
        document
            .put(serde_json::from_value(moved).unwrap(), None)
            .unwrap();
        let windows = &document.layout().sessions[0].windows;
        assert_eq!(windows[0].focus, PaneId::new(1));
        assert_eq!(windows[1].focus, PaneId::new(3));
    }

    #[test]
    fn a_new_window_without_a_name_takes_its_first_panes_program_and_an_old_one_keeps_its_name() {
        let named = |command: Value| {
            let pane = json!({"new": {"command": command}});
            json!({"tree": split("h", vec![json!({"pane": pane}), unsized_leaf(new_pane())])})
        };
        let argv = |words: &[&str]| json!({"type": "argv", "argv": words});
        let mut document = Document::empty();
        let created = json!({"name": "s", "windows": [
            named(argv(&["/usr/bin/vim", "a"])),
            named(json!({"type": "shell", "command": "ls -l | wc"})),
            {"tree": unsized_leaf(new_pane())},
            named(argv(&["/"])),
            {"name": "given", "tree": unsized_leaf(new_pane())},
        ]});
        document
            .put(request(&document, vec![created]), None)
            .unwrap();
        let names = |document: &Document| -> Vec<String> {
            document.layout().sessions[0]
                .windows
                .iter()
                .map(|window| String::from(window.name.clone()))
                .collect()
        };
        let created_names = names(&document);
        assert_eq!(created_names, ["vim", "ls", "sh", "sh", "given"]);

        let mut edited = serde_json::to_value(document.snapshot()).unwrap();
        let windows = edited["layout"]["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap();
        windows[0].as_object_mut().unwrap().remove("name");
        windows[1]["name"] = json!("renamed");
        windows[4]["name"] = json!("given");
        document
            .put(serde_json::from_value(edited).unwrap(), None)
            .unwrap();
        let renamed_names = names(&document);
        assert_eq!(renamed_names, ["vim", "renamed", "sh", "sh", "given"]);

        let mut moved = serde_json::to_value(document.snapshot()).unwrap();
        moved["layout"]["sessions"][0]["windows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"tree": {"pane": "pane_1"}}));
        let first = moved["layout"]["sessions"][0]["windows"][0]["tree"]["children"]
            .as_array_mut()
            .unwrap();
        first.remove(0);
        document
            .put(serde_json::from_value(moved).unwrap(), None)
            .unwrap();
        let windows = &document.layout().sessions[0].windows;
        assert_eq!(String::from(windows[5].name.clone()), "vim");
    }

    #[derive(Debug, Clone)]
    enum Shape {
        Leaf(Option<(u16, u16)>),
        Split(bool, Vec<Shape>),
    }

    fn shapes() -> impl Strategy<Value = Shape> {
        let leaf = prop::option::of((1u16..120, 1u16..60)).prop_map(Shape::Leaf);
        leaf.prop_recursive(4, 24, 5, |inner| {
            (any::<bool>(), prop::collection::vec(inner, 1..5))
                .prop_map(|(horizontal, children)| Shape::Split(horizontal, children))
        })
    }

    fn tree_json(shape: &Shape) -> Value {
        match shape {
            Shape::Leaf(None) => unsized_leaf(new_pane()),
            Shape::Leaf(Some((cols, rows))) => leaf(new_pane(), *cols, *rows),
            Shape::Split(horizontal, children) => split(
                if *horizontal { "h" } else { "v" },
                children.iter().map(tree_json).collect(),
            ),
        }
    }

    fn windows() -> impl Strategy<Value = Value> {
        let float = (
            prop::option::of(0u16..200),
            prop::option::of(0u16..80),
            prop::option::of(1u16..200),
            prop::option::of(1u16..80),
            prop::option::of(0u32..5),
            any::<bool>(),
        )
            .prop_map(|(x, y, cols, rows, z, border)| {
                json!({"pane": new_pane(), "x": x, "y": y, "cols": cols, "rows": rows,
                       "z": z, "border": border})
            });
        (
            shapes(),
            prop::option::of(1u16..200),
            prop::option::of(1u16..80),
            prop::collection::vec(float, 0..4),
        )
            .prop_map(|(shape, cols, rows, floats)| {
                let mut generated = window(tree_json(&shape));
                generated["cols"] = json!(cols);
                generated["rows"] = json!(rows);
                generated["floats"] = json!(floats);
                generated
            })
    }

    fn unsize(node: &mut Node<DraftLeaf>) {
        match node {
            Node::Leaf(leaf) => (leaf.cols, leaf.rows) = (None, None),
            Node::Split { children, .. } => children.iter_mut().for_each(unsize),
        }
    }

    fn equalizing(document: &Document) -> PutLayout {
        let mut layout = DraftLayout::from(document.layout());
        for window in layout
            .sessions
            .iter_mut()
            .flat_map(|session| &mut session.windows)
        {
            unsize(&mut window.tree);
        }
        PutLayout {
            revision: document.revision(),
            layout,
        }
    }

    fn pane_count(layout: &Layout) -> usize {
        layout.panes().len()
    }

    proptest! {
            #[test]
            fn any_draft_normalizes_to_a_consistent_document(generated in windows()) {
                let mut document = Document::empty();
                let created = document
                    .put(request(&document, vec![session(vec![generated])]), None)
                    .unwrap();
                let layout = document.snapshot().layout;
                check(&layout);
                prop_assert_eq!(pane_count(&layout), created.len());
                prop_assert_eq!(
                    layout.panes(),
                    created.iter().map(|(pane, ..)| *pane).collect::<BTreeSet<_>>()
                );
            }

            #[test]
            fn a_normalized_document_is_a_fixed_point(generated in windows()) {
                let mut document = document_of(generated);
                let before = document.snapshot();
                let created = document
                    .put(
                        serde_json::from_value(json!({
                            "revision": before.revision,
                            "layout": before.layout,
                        }))
                        .unwrap(),
                    None,
    )
                    .unwrap();
                prop_assert!(created.is_empty());
                prop_assert_eq!(document.snapshot(), before);
            }

            #[test]
            fn omitting_every_size_equalizes_into_a_consistent_fixed_point(generated in windows()) {
                let mut document = document_of(generated);
                let before = document.snapshot().layout;
                let created = document.put(equalizing(&document), None).unwrap();
                prop_assert!(created.is_empty());
                let equalized = document.snapshot().layout;
                check(&equalized);
                prop_assert_eq!(equalized.panes(), before.panes());
                let (old, new) = (&before.sessions[0].windows[0], &equalized.sessions[0].windows[0]);
                prop_assert_eq!((new.cols, new.rows), (old.cols, old.rows));
                let (mut leaves, mut was) = (vec![], vec![]);
                new.tree.leaves(&mut leaves);
                old.tree.leaves(&mut was);
                prop_assert_eq!(
                    leaves.iter().map(|leaf| leaf.pane).collect::<Vec<_>>(),
                    was.iter().map(|leaf| leaf.pane).collect::<Vec<_>>()
                );
                prop_assert!(leaves.iter().all(|leaf| leaf.cols.get() >= 1 && leaf.rows.get() >= 1));
                let again = document.put(equalizing(&document), None).unwrap();
                prop_assert!(again.is_empty());
                prop_assert_eq!(document.snapshot().layout, equalized);
            }

            #[test]
            fn omitting_the_sizes_of_a_flat_split_shares_its_axis_within_one_cell(
                sizes in prop::collection::vec((1u16..60, 1u16..40), 2..7),
                horizontal in any::<bool>(),
                cols in 1u16..200,
                rows in 1u16..80,
            ) {
                let leaves = sizes.iter().map(|(c, r)| leaf(new_pane(), *c, *r)).collect();
                let mut generated = window(split(if horizontal { "h" } else { "v" }, leaves));
                generated["cols"] = json!(cols);
                generated["rows"] = json!(rows);
                let mut document = document_of(generated);
                document.put(equalizing(&document), None).unwrap();
                let (mut shared, tree) = (vec![], first_window(&document).tree);
                tree.leaves(&mut shared);
                let along: Vec<_> = shared
                    .iter()
                    .map(|leaf| usize::from(if horizontal { leaf.cols } else { leaf.rows }.get()))
                    .collect();
                let (low, high) = (along.iter().min().unwrap(), along.iter().max().unwrap());
                prop_assert!(high - low <= 1, "{along:?}");
            }

            #[test]
            fn scaling_keeps_every_rule_and_returns_from_the_smallest_size(
                generated in windows(),
                cols in 1u16..300,
                rows in 1u16..100,
            ) {
                let mut document = document_of(generated);
                let start = first_window(&document);
                let size = |count| Cells::new(count).unwrap();
                document.resize_window(start.id, size(cols), size(rows), None);
                check(&document.snapshot().layout);
                document.resize_window(start.id, size(1), size(1), None);
                let smallest = first_window(&document);
                check(&document.snapshot().layout);
                let outer = if smallest.floats.iter().any(|float| float.border) { 3 } else { 1 };
                prop_assert_eq!(
                    (usize::from(smallest.cols.get()), usize::from(smallest.rows.get())),
                    (
                        smallest.tree.minimum(Axis::Horizontal).max(outer),
                        smallest.tree.minimum(Axis::Vertical).max(outer)
                    )
                );
                document.resize_window(start.id, start.cols, start.rows, None);
                let back = first_window(&document);
                check(&document.snapshot().layout);
                prop_assert_eq!((back.cols, back.rows), (start.cols, start.rows));
                prop_assert_eq!(back.panes().len(), start.panes().len());
            }

            #[test]
            fn removing_any_pane_leaves_a_consistent_document(
                generated in windows(),
                pick in any::<prop::sample::Index>(),
            ) {
                let mut document = document_of(generated);
                let before = document.snapshot().layout;
                let panes: Vec<_> = before.panes().into_iter().collect();
                let victim = panes[pick.index(panes.len())];
                prop_assert!(document.remove_pane(victim).is_some());
                let after = document.snapshot().layout;
                check(&after);
                let mut expected = before.panes();
                expected.remove(&victim);
                prop_assert_eq!(after.panes(), expected);
                let order = |layout: &Layout| {
                    let mut panes = vec![];
                    if let Some(window) = layout.sessions.first().and_then(|session| session.windows.first()) {
                        let mut tiled = vec![];
                        window.tree.leaves(&mut tiled);
                        panes.extend(tiled.into_iter().map(|leaf| leaf.pane));
                    }
                    panes
                };
                let mut tiled = order(&before);
                let promoted = order(&after).len() == 1 && tiled.len() == 1;
                tiled.retain(|pane| *pane != victim);
                if !promoted {
                    prop_assert_eq!(order(&after), tiled);
                }
                if let Some(window) = after.sessions.first().and_then(|session| session.windows.first()) {
                    let old = &before.sessions[0].windows[0];
                    prop_assert_eq!((window.cols, window.rows), (old.cols, old.rows));
                }
            }
        }
}

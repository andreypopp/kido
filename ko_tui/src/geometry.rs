use std::collections::BTreeSet;

use ko_client::edit::Edge;
use ko_server::ids::PaneId;
use ko_server::protocol::{Axis, Cells, Leaf, Node, Window, pick};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Rect {
    pub(crate) x: usize,
    pub(crate) y: usize,
    pub(crate) cols: usize,
    pub(crate) rows: usize,
}

impl Rect {
    pub(crate) fn contains(self, x: usize, y: usize) -> bool {
        x >= self.x && y >= self.y && x - self.x < self.cols && y - self.y < self.rows
    }

    pub(crate) fn grown(self, by: usize) -> Rect {
        Rect {
            x: self.x.saturating_sub(by),
            y: self.y.saturating_sub(by),
            cols: self.cols + by + self.x.min(by),
            rows: self.rows + by + self.y.min(by),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Pane {
    pub(crate) pane: PaneId,
    pub(crate) rect: Rect,
    pub(crate) border: Option<String>,
}

impl Pane {
    pub(crate) fn outer(&self) -> Rect {
        self.rect.grown(usize::from(self.border.is_some()))
    }

    pub(crate) fn covers(&self, x: usize, y: usize) -> bool {
        self.outer().contains(x, y)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Connections(u8);

impl Connections {
    const UP: Self = Self(1);
    const RIGHT: Self = Self(2);
    const DOWN: Self = Self(4);
    const LEFT: Self = Self(8);
    pub(crate) const VERTICAL: Self = Self(Self::UP.0 | Self::DOWN.0);
    pub(crate) const HORIZONTAL: Self = Self(Self::LEFT.0 | Self::RIGHT.0);
    pub(crate) const TOP_LEFT: Self = Self(Self::RIGHT.0 | Self::DOWN.0);
    pub(crate) const TOP_RIGHT: Self = Self(Self::LEFT.0 | Self::DOWN.0);
    pub(crate) const BOTTOM_LEFT: Self = Self(Self::RIGHT.0 | Self::UP.0);
    pub(crate) const BOTTOM_RIGHT: Self = Self(Self::LEFT.0 | Self::UP.0);
    pub(crate) const BRANCH_RIGHT: Self = Self(Self::VERTICAL.0 | Self::RIGHT.0);
    pub(crate) const BRANCH_LEFT: Self = Self(Self::VERTICAL.0 | Self::LEFT.0);
    pub(crate) const BRANCH_DOWN: Self = Self(Self::HORIZONTAL.0 | Self::DOWN.0);
    pub(crate) const BRANCH_UP: Self = Self(Self::HORIZONTAL.0 | Self::UP.0);
    pub(crate) const CROSS: Self = Self(Self::VERTICAL.0 | Self::HORIZONTAL.0);

    fn with(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Divider {
    pub(crate) rect: Rect,
    pub(crate) connections: Vec<Connections>,
    pub(crate) panes: Vec<PaneId>,
    pub(crate) grip: Grip,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Geometry {
    pub(crate) panes: Vec<Pane>,
    pub(crate) dividers: Vec<Divider>,
}

impl Geometry {
    pub(crate) fn top(&self, x: usize, y: usize) -> Option<&Pane> {
        self.panes.iter().rev().find(|pane| pane.covers(x, y))
    }

    pub(crate) fn divider(&self, x: usize, y: usize) -> Option<Grip> {
        if self.top(x, y).is_some() {
            return None;
        }
        self.dividers
            .iter()
            .find(|line| line.rect.contains(x, y))
            .map(|line| line.grip)
    }
}

fn walk(
    node: &Node<Leaf>,
    x: usize,
    y: usize,
    panes: &mut Vec<Pane>,
    lines: &mut Vec<(Grip, Rect)>,
) {
    match node {
        Node::Leaf(leaf) => panes.push(Pane {
            pane: leaf.pane,
            rect: Rect {
                x,
                y,
                cols: usize::from(leaf.cols.get()),
                rows: usize::from(leaf.rows.get()),
            },
            border: None,
        }),
        Node::Split { split, children } => {
            let mut offset = 0;
            let mut previous = None;
            for (at, child) in children.iter().enumerate() {
                let first = panes.len();
                let start = pick(*split, x, y) + offset;
                walk(
                    child,
                    x + pick(*split, offset, 0),
                    y + pick(*split, 0, offset),
                    panes,
                    lines,
                );
                if let Some(pane) = panes.get(first) {
                    if let Some((first, start, rect)) = previous.take() {
                        lines.push((
                            Grip {
                                first,
                                second: pane.pane,
                                axis: *split,
                                start,
                            },
                            rect,
                        ));
                    }
                    offset += child.known(*split).unwrap_or(0);
                    if at + 1 < children.len() {
                        previous = Some((
                            pane.pane,
                            start,
                            Rect {
                                x: x + pick(*split, offset, 0),
                                y: y + pick(*split, 0, offset),
                                cols: pick(*split, 1, node.known(Axis::Horizontal).unwrap_or(0)),
                                rows: pick(*split, node.known(Axis::Vertical).unwrap_or(0), 1),
                            },
                        ));
                        offset += 1;
                    }
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Grip {
    pub(crate) first: PaneId,
    pub(crate) second: PaneId,
    axis: Axis,
    start: usize,
}

impl Grip {
    pub(crate) fn first_size(self, x: usize, y: usize) -> Option<Cells> {
        let size = pick(self.axis, x, y).checked_sub(self.start)?;
        Cells::try_from(u16::try_from(size).unwrap_or(u16::MAX)).ok()
    }
}

pub(crate) fn left_edge(shown: &Window, pane: PaneId) -> bool {
    shown.tree.contains(pane) && neighbour(shown, pane, Edge::Left, (0, 0)).is_none()
}

pub(crate) fn neighbour(
    window: &Window,
    active: PaneId,
    edge: Edge,
    cursor: (usize, usize),
) -> Option<PaneId> {
    let mut panes = Vec::new();
    walk(&window.tree, 0, 0, &mut panes, &mut Vec::new());
    let rect = panes.iter().find(|pane| pane.pane == active)?.rect;
    let axis = match edge {
        Edge::Left | Edge::Right => Axis::Horizontal,
        Edge::Top | Edge::Bottom => Axis::Vertical,
    };
    let start = pick(axis, rect.y, rect.x);
    let len = pick(axis, rect.rows, rect.cols);
    let position = start + pick(axis, cursor.1, cursor.0).min(len.saturating_sub(1));
    panes
        .iter()
        .filter_map(|pane| {
            let other = pane.rect;
            let across = match edge {
                Edge::Left => other.x + other.cols + 1 == rect.x,
                Edge::Right => rect.x + rect.cols + 1 == other.x,
                Edge::Top => other.y + other.rows + 1 == rect.y,
                Edge::Bottom => rect.y + rect.rows + 1 == other.y,
            };
            let other_start = pick(axis, other.y, other.x);
            let other_len = pick(axis, other.rows, other.cols);
            let overlap = (start + len)
                .min(other_start + other_len)
                .saturating_sub(start.max(other_start));
            (across && overlap > 0).then_some((
                pane.pane,
                (
                    other.contains(pick(axis, other.x, position), pick(axis, position, other.y)),
                    overlap,
                ),
            ))
        })
        .max_by_key(|(_, rank)| *rank)
        .map(|(pane, _)| pane)
}

pub(crate) fn window(window: &Window) -> Geometry {
    if let Some(pane) = window.zoom {
        return Geometry {
            panes: vec![Pane {
                pane,
                rect: Rect {
                    x: 0,
                    y: 0,
                    cols: usize::from(window.cols.get()),
                    rows: usize::from(window.rows.get()),
                },
                border: None,
            }],
            dividers: Vec::new(),
        };
    }
    let mut result = Geometry::default();
    let mut lines = Vec::new();
    walk(&window.tree, 0, 0, &mut result.panes, &mut lines);
    let mut cells = BTreeSet::new();
    for (_, r) in &lines {
        for y in r.y..r.y + r.rows {
            for x in r.x..r.x + r.cols {
                cells.insert((x, y));
            }
        }
    }
    for (grip, r) in lines {
        let axis = grip.axis;
        let start = pick(axis, r.y, r.x);
        let end = start + pick(axis, r.rows, r.cols);
        let mut cuts = BTreeSet::from([start, end]);
        for pane in &result.panes {
            let grown = pane.rect.grown(1);
            for edge in [
                pick(axis, grown.y, grown.x),
                pick(axis, grown.y + grown.rows, grown.x + grown.cols),
            ] {
                if edge > start && edge < end {
                    cuts.insert(edge);
                }
            }
        }
        let cuts: Vec<_> = cuts.into_iter().collect();
        for pair in cuts.windows(2) {
            let (Some(&first), Some(&last)) = (pair.first(), pair.get(1)) else {
                continue;
            };
            let rect = Rect {
                x: pick(axis, r.x, first),
                y: pick(axis, first, r.y),
                cols: pick(axis, 1, last - first),
                rows: pick(axis, last - first, 1),
            };
            let panes = result
                .panes
                .iter()
                .filter(|pane| {
                    pane.rect.grown(1).contains(rect.x, rect.y)
                        && !pane.rect.contains(rect.x, rect.y)
                })
                .map(|pane| pane.pane)
                .collect();
            let mut connections = Vec::new();
            for y in rect.y..rect.y + rect.rows {
                for x in rect.x..rect.x + rect.cols {
                    let mut connection = pick(axis, Connections::VERTICAL, Connections::HORIZONTAL);
                    for (dx, dy, direction) in [
                        (0isize, -1isize, Connections::UP),
                        (1, 0, Connections::RIGHT),
                        (0, 1, Connections::DOWN),
                        (-1, 0, Connections::LEFT),
                    ] {
                        if let (Some(nx), Some(ny)) =
                            (x.checked_add_signed(dx), y.checked_add_signed(dy))
                            && cells.contains(&(nx, ny))
                        {
                            connection = connection.with(direction);
                        }
                    }
                    connections.push(connection);
                }
            }
            result.dividers.push(Divider {
                grip,
                rect,
                connections,
                panes,
            });
        }
    }
    let mut floats: Vec<_> = window.floats.iter().collect();
    floats.sort_by_key(|float| float.z);
    result.panes.extend(floats.into_iter().map(|float| Pane {
        pane: float.pane,
        rect: Rect {
            x: usize::from(float.x),
            y: usize::from(float.y),
            cols: usize::from(float.cols.get()),
            rows: usize::from(float.rows.get()),
        },
        border: float.border.then(|| float.title.clone()),
    }));
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use ko_server::protocol::Cells;
    use proptest::prelude::*;

    fn sample() -> Window {
        ko_server::protocol::decode(br#"{"id":"window_1","name":"w","vars":{},"cols":80,"rows":24,"focus":"pane_1","tree":{"split":"h","children":[{"pane":"pane_1","cols":40,"rows":24},{"split":"v","children":[{"pane":"pane_2","cols":39,"rows":12},{"pane":"pane_3","cols":39,"rows":11}]}]},"floats":[]}"#).unwrap()
    }

    #[test]
    fn left_edge_uses_the_unzoomed_tree_and_excludes_floats() {
        let mut w = sample();
        let panes = w.panes();
        assert!(left_edge(&w, panes[0]));
        assert!(!left_edge(&w, panes[1]));
        assert!(!left_edge(&w, panes[2]));
        if let Node::Split { children, .. } = &mut w.tree {
            children.swap(0, 1);
        }
        assert!(!left_edge(&w, panes[0]));
        assert!(left_edge(&w, panes[1]));
        assert!(left_edge(&w, panes[2]));
        let float = "pane_4".parse().unwrap();
        w.floats.push(ko_server::protocol::decode(br#"{"pane":"pane_4","x":0,"y":0,"cols":5,"rows":4,"z":0,"border":false,"title":""}"#).unwrap());
        assert!(!left_edge(&w, float));
        if let Node::Split { children, .. } = &mut w.tree {
            children.swap(0, 1);
        }
        for pane in panes.iter().copied().chain([float]) {
            w.zoom = Some(pane);
            assert_eq!(left_edge(&w, pane), pane == panes[0]);
        }
    }

    #[test]
    fn divider_hits_use_adjacent_children_first_leaves_and_parent_junctions() {
        let mut w = sample();
        let panes = w.panes();
        for (point, pair, moved, size) in [
            ((40, 3), (panes[0], panes[1]), (37, 3), 37),
            ((40, 20), (panes[0], panes[1]), (43, 20), 43),
            ((50, 12), (panes[1], panes[2]), (50, 10), 10),
            ((40, 12), (panes[0], panes[1]), (38, 12), 38),
        ] {
            let hit = window(&w).divider(point.0, point.1).unwrap();
            assert_eq!((hit.first, hit.second), pair);
            assert_eq!(
                hit.first_size(moved.0, moved.1),
                Some(Cells::try_from(size as u16).unwrap())
            );
            assert_eq!(hit.first_size(0, 0), None);
        }
        assert_eq!(window(&w).divider(3, 3), None);
        w.floats.push(ko_server::protocol::decode(br#"{"pane":"pane_4","x":40,"y":10,"cols":5,"rows":4,"z":0,"border":true,"title":""}"#).unwrap());
        assert_eq!(window(&w).divider(40, 12), None);
        assert_eq!(window(&w).divider(40, 9), None);
        w.zoom = Some(panes[0]);
        assert_eq!(window(&w).divider(40, 3), None);
    }

    #[test]
    fn neighbours_follow_the_cursor_and_ignore_zoom_and_floats() {
        let mut w = sample();
        let panes = w.panes();
        assert_eq!(neighbour(&w, panes[0], Edge::Right, (0, 3)), Some(panes[1]));
        assert_eq!(
            neighbour(&w, panes[0], Edge::Right, (0, 20)),
            Some(panes[2])
        );
        assert_eq!(
            neighbour(&w, panes[0], Edge::Right, (0, 12)),
            Some(panes[1])
        );
        assert_eq!(neighbour(&w, panes[0], Edge::Left, (0, 3)), None);
        assert_eq!(
            neighbour(&w, panes[1], Edge::Bottom, (3, 0)),
            Some(panes[2])
        );
        assert_eq!(neighbour(&w, panes[2], Edge::Top, (3, 0)), Some(panes[1]));
        w.zoom = Some(panes[0]);
        assert_eq!(
            neighbour(&w, panes[0], Edge::Right, (0, 20)),
            Some(panes[2])
        );
        let float = "pane_4".parse().unwrap();
        w.floats.push(ko_server::protocol::decode(format!(r#"{{"pane":"{float}","x":0,"y":0,"cols":10,"rows":10,"z":0,"border":false,"title":""}}"#).as_bytes()).unwrap());
        assert_eq!(neighbour(&w, float, Edge::Right, (0, 0)), None);
        assert_eq!(neighbour(&w, panes[0], Edge::Right, (0, 3)), Some(panes[1]));
    }

    #[test]
    fn nested_splits_join_and_zoom_hides_the_other_panes() {
        let mut w = sample();
        let g = window(&w);
        assert_eq!(
            g.panes.iter().map(|pane| pane.rect).collect::<Vec<_>>(),
            [
                Rect {
                    x: 0,
                    y: 0,
                    cols: 40,
                    rows: 24
                },
                Rect {
                    x: 41,
                    y: 0,
                    cols: 39,
                    rows: 12
                },
                Rect {
                    x: 41,
                    y: 13,
                    cols: 39,
                    rows: 11
                },
            ]
        );
        let junction = g
            .dividers
            .iter()
            .find(|segment| segment.rect.contains(40, 12))
            .unwrap();
        assert_eq!(
            junction.connections[12 - junction.rect.y],
            Connections::BRANCH_RIGHT
        );
        assert_eq!(
            g.dividers
                .iter()
                .map(|segment| segment.connections.len())
                .sum::<usize>(),
            63
        );
        w.zoom = Some("pane_2".parse().unwrap());
        let g = window(&w);
        assert_eq!(g.panes.len(), 1);
        assert_eq!(g.panes[0].pane, w.zoom.unwrap());
        assert_eq!(
            g.panes[0].rect,
            Rect {
                x: 0,
                y: 0,
                cols: 80,
                rows: 24
            }
        );
        assert_eq!(g.dividers, []);
    }

    #[test]
    fn overlapping_floats_follow_z_order_after_the_tree() {
        let mut w = sample();
        for (id, z) in [(4, 10), (5, 2)] {
            w.floats.push(ko_server::protocol::Float {
                pane: format!("pane_{id}").parse().unwrap(),
                x: 2,
                y: 2,
                cols: Cells::try_from(10u16).unwrap(),
                rows: Cells::try_from(5u16).unwrap(),
                z,
                border: true,
                title: format!("float {id}"),
            });
        }
        let g = window(&w);
        assert_eq!(
            g.panes
                .iter()
                .map(|pane| pane.pane.to_string())
                .collect::<Vec<_>>(),
            ["pane_1", "pane_2", "pane_3", "pane_5", "pane_4"]
        );
        assert_eq!(g.panes[3].rect, g.panes[4].rect);
        assert_eq!(g.panes[4].border.as_deref(), Some("float 4"));
    }

    fn generated(cols: u16, rows: u16, choices: &[bool], next: &mut u64) -> Node<Leaf> {
        if let Some((&horizontal, rest)) = choices.split_first() {
            if horizontal && cols >= 3 {
                let first = (cols - 1) / 2;
                return Node::Split {
                    split: Axis::Horizontal,
                    children: vec![
                        generated(first, rows, rest, next),
                        generated(cols - first - 1, rows, rest, next),
                    ],
                };
            } else if rows >= 3 {
                let first = (rows - 1) / 2;
                return Node::Split {
                    split: Axis::Vertical,
                    children: vec![
                        generated(cols, first, rest, next),
                        generated(cols, rows - first - 1, rest, next),
                    ],
                };
            }
        }
        *next += 1;
        Node::Leaf(Leaf {
            pane: format!("pane_{next}").parse().unwrap(),
            cols: Cells::try_from(cols).unwrap(),
            rows: Cells::try_from(rows).unwrap(),
        })
    }

    proptest! {
        #[test]
        fn leaves_and_dividers_cover_the_window_once(cols in 1u16..100, rows in 1u16..60, choices in prop::collection::vec(any::<bool>(), 0..6)) {
            let mut w = sample();
            w.cols = Cells::try_from(cols).unwrap();
            w.rows = Cells::try_from(rows).unwrap();
            let mut count = 0;
            w.tree = generated(cols, rows, &choices, &mut count);
            let g = window(&w);
            let mut ids: Vec<_> = g.panes.iter().map(|pane| pane.pane).collect();
            ids.sort(); ids.dedup();
            prop_assert_eq!(ids.len(), usize::try_from(count).unwrap());
            for y in 0..usize::from(rows) {
                for x in 0..usize::from(cols) {
                    let covered = g.panes.iter().filter(|pane| pane.rect.contains(x, y)).count()
                        + g.dividers.iter().filter(|segment| segment.rect.contains(x, y)).count();
                    prop_assert_eq!(covered, 1, "cell ({},{})", x, y);
                }
            }
        }
    }
}

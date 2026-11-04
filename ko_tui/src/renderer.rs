use std::fmt::Write;

use crate::copy;
use ko_client::status::Mark;
use ko_server::ids::{PaneId, WindowId};
use ko_server::protocol::{Session, Window};
use ko_vt::render::{Attribute, Attributes, Cell, Colour, CursorShape, Frame, Style};
use ko_vt::unicode::{clusters, width};

use crate::differ::Differ;
use crate::geometry::{Connections, Geometry, Rect};
use crate::keys::{HELP, Kill, Mode, Rename, State};
use crate::modes::Modes;
use crate::sidebar::Line;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Status {
    pub(crate) left: String,
    pub(crate) right: String,
}

pub(crate) fn status(
    shown: Option<(&Session, &Window)>,
    last: Option<WindowId>,
    state: &State,
    mode: Mode,
    reconnect: Option<&str>,
) -> Status {
    let mut left = String::new();
    if let Some((session, window)) = shown {
        let _ = write!(left, "[{}]", session.name.as_str());
        for (at, found) in session.windows.iter().enumerate() {
            let flag = if found.id == window.id {
                "*"
            } else if Some(found.id) == last {
                "-"
            } else {
                ""
            };
            let _ = write!(left, " {at}:{}{flag}", found.name.as_str());
        }
    }
    let mut right = String::new();
    let _ = match (reconnect, state, mode) {
        (Some(host), _, _) => write!(right, "[reconnecting to {host} \u{2014} C-a d to detach]"),
        (None, State::Prefix, _) => right.write_str("C-a"),
        (None, State::Rename { of, text }, _) => {
            let what = match of {
                Rename::Session => "rename-session",
                Rename::Window => "rename-window",
            };
            write!(right, "({what}) {text}")
        }
        (None, State::Confirm(Kill::Window), _) => write!(
            right,
            "kill-window {}? (y/n)",
            shown.map_or("", |(_, window)| window.name.as_str())
        ),
        (None, State::Confirm(Kill::Pane), _) => right.write_str("kill-pane? (y/n)"),
        (None, State::Normal | State::Repeat { .. }, Mode::Sidebar(_)) => {
            right.write_str("[sidebar]")
        }
        (None, State::Normal | State::Repeat { .. }, Mode::Resize | Mode::SidebarResize(_)) => {
            right.write_str("[resize]")
        }
        (None, _, _) => Ok(()),
    };
    Status { left, right }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Layout {
    pub(crate) cols: usize,
    pub(crate) rows: usize,
    pub(crate) pane_x: usize,
    pub(crate) pane_rows: usize,
    pub(crate) status: Status,
    pub(crate) help: bool,
    pub(crate) resizing: Option<Resizing>,
    pub(crate) copy: Option<(PaneId, copy::Mode)>,
    pub(crate) geometry: std::rc::Rc<Geometry>,
    pub(crate) active: Option<PaneId>,
    pub(crate) sidebar: Vec<Line>,
    pub(crate) choosing: Option<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cursor {
    Hidden,
    Visible(usize, usize, CursorShape),
}

#[derive(Debug)]
pub(crate) struct PaneFrame<'a> {
    pub(crate) pane: PaneId,
    pub(crate) serial: u64,
    pub(crate) frame: &'a Frame,
    pub(crate) dead: Option<&'a str>,
}

#[derive(Debug, Default)]
pub(crate) struct Renderer {
    differ: Differ,
    layout: Option<Layout>,
    frames: Vec<(PaneId, u64)>,
    ui: Vec<Cell>,
    cells: Vec<Cell>,
    cursor: Option<Cursor>,
}

fn blank() -> Cell {
    Cell {
        text: String::new(),
        width: 1,
        style: Style::default(),
    }
}

fn put(grid: &mut [Cell], cols: usize, x: usize, y: usize, cell: &Cell) {
    if x >= cols {
        return;
    }
    let at = y * cols + x;
    if cell.width != 0 {
        if grid.get(at).is_some_and(|cell| cell.width == 0)
            && x > 0
            && let Some(left) = grid.get_mut(at - 1)
        {
            left.text.clear();
            left.width = 1;
        }
        if grid.get(at).is_some_and(|cell| cell.width == 2)
            && x + 1 < cols
            && let Some(right) = grid.get_mut(at + 1)
        {
            right.text.clear();
            right.width = 1;
        }
    }
    if let Some(slot) = grid.get_mut(at) {
        slot.clone_from(cell);
    }
}

fn line_glyph(connection: Connections) -> &'static str {
    match connection {
        Connections::VERTICAL => "│",
        Connections::HORIZONTAL => "─",
        Connections::TOP_LEFT => "┌",
        Connections::TOP_RIGHT => "┐",
        Connections::BOTTOM_LEFT => "└",
        Connections::BOTTOM_RIGHT => "┘",
        Connections::BRANCH_RIGHT => "├",
        Connections::BRANCH_LEFT => "┤",
        Connections::BRANCH_DOWN => "┬",
        Connections::BRANCH_UP => "┴",
        Connections::CROSS => "┼",
        _ => "",
    }
}

fn draw_row(
    grid: &mut [Cell],
    cols: usize,
    (x, y): (usize, usize),
    width: usize,
    base: Style,
    parts: &[(&str, Style)],
) {
    for at in 0..width {
        let blank = Cell {
            text: " ".to_owned(),
            width: 1,
            style: base,
        };
        put(grid, cols, x + at, y, &blank);
    }
    let mut at = x;
    for (text, style) in parts {
        for (cluster, wide) in clusters(text) {
            if at + usize::from(wide) > x + width {
                return;
            }
            let cell = |text: &str, width| Cell {
                text: text.to_owned(),
                width,
                style: *style,
            };
            put(grid, cols, at, y, &cell(cluster, wide.max(1)));
            if wide == 2 {
                put(grid, cols, at + 1, y, &cell("", 0));
            }
            at += usize::from(wide);
        }
    }
}

fn reversed() -> Style {
    Style {
        attrs: Attributes::default().with(Attribute::Inverse),
        ..Style::default()
    }
}

fn draw_line(
    grid: &mut [Cell],
    cols: usize,
    at: (usize, usize),
    width: usize,
    base: Style,
    text: &str,
) {
    draw_row(grid, cols, at, width, base, &[(text, base)]);
}

fn draw_status(grid: &mut [Cell], cols: usize, y: usize, status: &Status) {
    let base = Style {
        fg: Colour::Indexed(0),
        bg: Colour::Indexed(2),
        ..Style::default()
    };
    let right = width(&status.right).min(cols);
    draw_line(grid, cols, (0, y), cols - right, base, &status.left);
    draw_line(grid, cols, (cols - right, y), right, base, &status.right);
}

fn glyph(mark: Mark) -> (&'static str, Style) {
    let colour = |index, bold: bool| Style {
        fg: Colour::Indexed(index),
        attrs: if bold {
            Attributes::default().with(Attribute::Bold)
        } else {
            Attributes::default()
        },
        ..Style::default()
    };
    match mark {
        Mark::None => (" ", Style::default()),
        Mark::Running => ("\u{25fc}", colour(2, false)),
        Mark::Waiting => ("\u{25c6}", colour(3, true)),
        Mark::Done => ("\u{2713}", colour(2, true)),
        Mark::Failed => ("\u{25fc}", colour(1, false)),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Resizing {
    Panes,
    Sidebar,
}

fn draw_ui(l: &Layout) -> Vec<Cell> {
    let mut grid = vec![blank(); l.cols * l.rows];
    if l.pane_x > 0 {
        for y in 0..l.pane_rows {
            draw_line(
                &mut grid,
                l.cols,
                (0, y),
                l.pane_x - 1,
                Style::default(),
                "",
            );
            let bar = Cell {
                text: "\u{2502}".to_owned(),
                width: 1,
                style: if l.resizing == Some(Resizing::Sidebar) {
                    Style {
                        fg: Colour::Indexed(3),
                        ..Style::default()
                    }
                } else {
                    Style::default()
                },
            };
            put(&mut grid, l.cols, l.pane_x - 1, y, &bar);
        }
    }
    for (y, line) in l.sidebar.iter().enumerate().take(l.pane_rows) {
        let inverse = l.choosing.map_or(line.selected, |chosen| chosen == y);
        let (mark, style) = glyph(line.mark);
        let base = if inverse {
            reversed()
        } else {
            Style::default()
        };
        let part = |text, own| (text, if inverse { base } else { own });
        let dim = Style {
            attrs: Attributes::default().with(Attribute::Dim),
            ..Style::default()
        };
        draw_row(
            &mut grid,
            l.cols,
            (0, y),
            l.pane_x.saturating_sub(1),
            base,
            &[
                part(line.lead.as_str(), Style::default()),
                part(mark, style),
                part(line.title.as_str(), Style::default()),
                part(line.runtime.as_str(), dim),
            ],
        );
    }
    if l.help {
        for (y, text) in HELP.iter().enumerate().take(l.pane_rows) {
            let width = l.cols.saturating_sub(l.pane_x);
            draw_line(
                &mut grid,
                l.cols,
                (l.pane_x, y),
                width,
                Style::default(),
                text,
            );
        }
    }
    if let Some(y) = l.rows.checked_sub(1) {
        let status = if let Some((_, mode)) = &l.copy {
            Status {
                left: l.status.left.clone(),
                right: match mode.search_state() {
                    copy::SearchState::Normal => "[copy]".to_owned(),
                    copy::SearchState::Prompt(direction, text) => format!(
                        "{}{text}",
                        if *direction == copy::Direction::Forward {
                            '/'
                        } else {
                            '?'
                        }
                    ),
                    copy::SearchState::Searching(..) => "searching".to_owned(),
                    copy::SearchState::NoMatch => "no match".to_owned(),
                },
            }
        } else {
            l.status.clone()
        };
        draw_status(&mut grid, l.cols, y, &status);
    }
    grid
}

impl Renderer {
    pub(crate) fn invalidate(&mut self) {
        self.differ.invalidate();
        self.layout = None;
        self.cursor = None;
    }

    pub(crate) fn paint(
        &mut self,
        modes: &mut Modes,
        layout: &Layout,
        frames: &[PaneFrame<'_>],
        out: &mut String,
    ) -> bool {
        let ui_changed = self.layout.as_ref() != Some(layout);
        let serials = frames.iter().map(|pane| (pane.pane, pane.serial));
        if !ui_changed && self.frames.iter().copied().eq(serials) {
            return false;
        }
        let l = layout;
        self.frames.clear();
        self.frames
            .extend(frames.iter().map(|pane| (pane.pane, pane.serial)));
        if ui_changed {
            self.layout = Some(l.clone());
            self.ui = draw_ui(l);
        }
        self.cells.clone_from(&self.ui);
        let area = Rect {
            x: 0,
            y: 0,
            cols: l.cols.saturating_sub(l.pane_x),
            rows: l.pane_rows,
        };
        if !l.help {
            for divider in &l.geometry.dividers {
                let style = Style {
                    fg: if l.active.is_some_and(|pane| divider.panes.contains(&pane)) {
                        Colour::Indexed(if l.resizing == Some(Resizing::Panes) {
                            3
                        } else {
                            2
                        })
                    } else {
                        Colour::Default
                    },
                    ..Style::default()
                };
                for (at, connection) in divider.connections.iter().enumerate() {
                    let x = divider.rect.x + at % divider.rect.cols;
                    let y = divider.rect.y + at / divider.rect.cols;
                    if area.contains(x, y) {
                        put(
                            &mut self.cells,
                            l.cols,
                            l.pane_x + x,
                            y,
                            &Cell {
                                text: line_glyph(*connection).to_owned(),
                                width: 1,
                                style,
                            },
                        );
                    }
                }
            }
            for pane in &l.geometry.panes {
                let r = pane.rect;
                let shown = frames.iter().find(|frame| frame.pane == pane.pane);
                let copy = l
                    .copy
                    .as_ref()
                    .filter(|(id, _)| *id == pane.pane)
                    .map(|(_, mode)| mode);
                let span = copy.and_then(copy::Mode::range);
                if let Some(title) = &pane.border {
                    let outer = pane.outer();
                    for y in outer.y..outer.y + outer.rows {
                        for x in outer.x..outer.x + outer.cols {
                            if !area.contains(x, y) || r.contains(x, y) {
                                continue;
                            }
                            let connection = match (
                                r.x > 0 && x == outer.x,
                                x == r.x + r.cols,
                                r.y > 0 && y == outer.y,
                                y == r.y + r.rows,
                            ) {
                                (true, _, true, _) => Connections::TOP_LEFT,
                                (_, true, true, _) => Connections::TOP_RIGHT,
                                (true, _, _, true) => Connections::BOTTOM_LEFT,
                                (_, true, _, true) => Connections::BOTTOM_RIGHT,
                                (_, _, true, _) | (_, _, _, true) => Connections::HORIZONTAL,
                                _ => Connections::VERTICAL,
                            };
                            put(
                                &mut self.cells,
                                l.cols,
                                l.pane_x + x,
                                y,
                                &Cell {
                                    text: line_glyph(connection).to_owned(),
                                    width: 1,
                                    style: Style::default(),
                                },
                            );
                        }
                    }
                    if r.y > 0 && area.contains(r.x, r.y - 1) {
                        draw_line(
                            &mut self.cells,
                            l.cols,
                            (l.pane_x + r.x, r.y - 1),
                            r.cols.min(area.cols.saturating_sub(r.x)),
                            Style::default(),
                            title,
                        );
                    }
                }
                for y in 0..r.rows.min(area.rows.saturating_sub(r.y)) {
                    for x in 0..r.cols.min(area.cols.saturating_sub(r.x)) {
                        let source = shown.and_then(|pane| {
                            let f = pane.frame;
                            let source_y = y + usize::from(pane.dead.is_some());
                            (x < usize::from(f.cols) && source_y < usize::from(f.rows))
                                .then(|| f.cells.get(source_y * usize::from(f.cols) + x))
                                .flatten()
                        });
                        let empty = blank();
                        let cell = source.unwrap_or(&empty);
                        let mut style = cell.style;
                        let col = u16::try_from(x).unwrap_or(u16::MAX);
                        let row = u32::try_from(y).unwrap_or(u32::MAX);
                        match copy.map_or(copy::Highlight::None, |mode| {
                            mode.highlight(span, col, row, cell.width)
                        }) {
                            copy::Highlight::None => {}
                            copy::Highlight::Selected => {
                                style.attrs = style.attrs.with(Attribute::Inverse)
                            }
                            highlight @ (copy::Highlight::Match | copy::Highlight::Current) => {
                                style.bg = Colour::Indexed(3);
                                style.fg = Colour::Indexed(0);
                                if highlight == copy::Highlight::Current {
                                    style.attrs = style.attrs.with(Attribute::Bold);
                                }
                            }
                        }
                        let clipped = (cell.width == 2
                            && (x + 1 >= r.cols || !area.contains(r.x + x + 1, r.y + y)))
                            || (cell.width == 0 && x == 0);
                        if clipped {
                            put(
                                &mut self.cells,
                                l.cols,
                                l.pane_x + r.x + x,
                                r.y + y,
                                &Cell { style, ..blank() },
                            );
                        } else {
                            put(&mut self.cells, l.cols, l.pane_x + r.x + x, r.y + y, cell);
                            if let Some(cell) =
                                self.cells.get_mut((r.y + y) * l.cols + l.pane_x + r.x + x)
                            {
                                cell.style = style;
                            }
                        }
                    }
                }
                if let Some(copy) = copy
                    && r.rows > 0
                    && area.contains(r.x, r.y)
                {
                    let available = r.cols.min(area.cols.saturating_sub(r.x));
                    let indicator = format!("[{}/{}]", copy.offset(), copy.history());
                    let length = width(&indicator).min(available);
                    draw_line(
                        &mut self.cells,
                        l.cols,
                        (l.pane_x + r.x + available - length, r.y),
                        length,
                        Style {
                            fg: Colour::Indexed(3),
                            ..Style::default()
                        },
                        &indicator,
                    );
                }
                if let Some(dead) = shown.and_then(|pane| pane.dead)
                    && r.rows > 0
                    && area.contains(r.x, r.y + r.rows - 1)
                {
                    draw_line(
                        &mut self.cells,
                        l.cols,
                        (l.pane_x + r.x, r.y + r.rows - 1),
                        r.cols.min(area.cols.saturating_sub(r.x)),
                        reversed(),
                        dead,
                    );
                }
            }
        }
        let active = frames.iter().find(|frame| Some(frame.pane) == l.active);
        let start = out.len();
        out.push_str("\x1b[?2026h");
        let prefix = out.len();
        if let Some(pane) = active {
            modes.apply(pane.frame.mouse, pane.frame.keyboard, out);
        }
        let before = out.len();
        self.differ.draw(l.cols, &mut self.cells, out);
        let drew = out.len() > before;
        let cursor = active
            .and_then(|pane| {
                let r = l
                    .geometry
                    .panes
                    .iter()
                    .find(|placement| placement.pane == pane.pane)?
                    .rect;
                let c = pane.frame.cursor?;
                let (x, y) = (usize::from(c.x), usize::from(c.y));
                if pane.dead.is_some()
                    || l.help
                    || l.copy.as_ref().is_some_and(|(id, _)| *id == pane.pane)
                    || x >= r.cols
                    || y >= r.rows
                    || !area.contains(r.x + x, r.y + y)
                {
                    return None;
                }
                let top = l.geometry.top(r.x + x, r.y + y)?;
                (top.pane == pane.pane).then_some(Cursor::Visible(
                    l.pane_x + r.x + x,
                    r.y + y,
                    c.shape,
                ))
            })
            .unwrap_or(Cursor::Hidden);
        if drew || self.cursor != Some(cursor) {
            match cursor {
                Cursor::Hidden => out.push_str("\x1b[?25l"),
                Cursor::Visible(x, y, shape) => {
                    let shape = match shape {
                        CursorShape::Bar => 6,
                        CursorShape::Underline => 4,
                        CursorShape::Block | CursorShape::HollowBlock => 2,
                    };
                    out.push_str(&format!("\x1b[{shape} q\x1b[{};{}H\x1b[?25h", y + 1, x + 1));
                }
            }
            self.cursor = Some(cursor);
        }
        if out.len() == prefix {
            out.truncate(start);
        } else {
            out.push_str("\x1b[?2026l");
        }
        true
    }
}

#[cfg(test)]
mod tests {

    use super::*;

    fn pane_id() -> PaneId {
        "pane_1".parse().unwrap()
    }

    fn frames(serial: u64, frame: &Frame) -> Vec<PaneFrame<'_>> {
        vec![PaneFrame {
            pane: pane_id(),
            serial,
            frame,
            dead: None,
        }]
    }

    fn geometry(cols: usize, rows: usize) -> Geometry {
        Geometry {
            panes: vec![crate::geometry::Pane {
                pane: pane_id(),
                rect: crate::geometry::Rect {
                    x: 0,
                    y: 0,
                    cols,
                    rows,
                },
                border: None,
            }],
            dividers: Vec::new(),
        }
    }

    fn quiet() -> Status {
        Status {
            left: String::new(),
            right: String::new(),
        }
    }

    fn line(number: u64, title: &str, selected: bool) -> Line {
        Line {
            pane: Some(format!("pane_{number}").parse().unwrap()),
            lead: format!("{number} "),
            mark: Mark::None,
            title: title.to_owned(),
            runtime: String::new(),
            selected,
        }
    }

    #[test]
    fn copy_status_indicator_selection_and_cursor_are_drawn() {
        let copy = copy::Mode::open(
            ko_vt::Cursor {
                x: 2,
                y: 0,
                visible: true,
                pending_wrap: false,
            },
            12,
            4,
            (20, 3),
            copy::Entry::Here,
            |_| {
                Ok(copy::Row {
                    text: String::new(),
                    wraps: false,
                })
            },
        )
        .unwrap();
        let layout = Layout {
            cols: 20,
            rows: 4,
            pane_x: 0,
            pane_rows: 3,
            status: status(None, None, &State::Normal, Mode::Pane, None),
            help: false,
            resizing: None,
            copy: Some((pane_id(), copy)),
            geometry: std::rc::Rc::new(geometry(20, 3)),
            active: Some(pane_id()),
            sidebar: Vec::new(),
            choosing: None,
        };
        let frame = composed(&layout, &[]);
        let row = |y: usize| {
            frame.cells[y * 20..(y + 1) * 20]
                .iter()
                .map(|cell| cell.text.as_str())
                .collect::<String>()
        };
        assert!(row(0).ends_with("[4/9]"));
        assert!(row(3).ends_with("[copy]"));
        assert_eq!(frame.cells[19].style.fg, Colour::Indexed(3));
        assert!(frame.cells[42].style.attrs.has(Attribute::Inverse));
        assert_eq!(frame.cursor, None);
        let mut layout = layout;
        let mode = &mut layout.copy.as_mut().unwrap().1;
        let mut events = Vec::new();
        crate::input::Input::default().feed(b"h/needle\r", std::time::Instant::now(), &mut events);
        for event in events {
            if let crate::input::Event::Key(key) = event {
                mode.feed(
                    &key,
                    |_| {
                        Ok(copy::Row {
                            text: String::new(),
                            wraps: false,
                        })
                    },
                    |_| Ok(false),
                )
                .unwrap();
            }
        }
        let at = |row, col| ko_pane_wire::frame::Cell { row, col };
        mode.search_done(
            vec![
                ko_pane_wire::frame::Match {
                    start: at(4, 18),
                    end: at(5, 2),
                },
                ko_pane_wire::frame::Match {
                    start: at(6, 2),
                    end: at(6, 3),
                },
            ],
            |_| Ok(false),
        )
        .unwrap();
        let frame = composed(&layout, &[]);
        assert_eq!(frame.cells[20].style.bg, Colour::Indexed(3));
        assert!(!frame.cells[20].style.attrs.has(Attribute::Bold));
        assert_eq!(frame.cells[43].style.bg, Colour::Indexed(3));
        assert!(frame.cells[43].style.attrs.has(Attribute::Bold));
        assert!(frame.cells[42].style.attrs.has(Attribute::Inverse));
        assert_eq!(frame.cells[42].style.bg, Colour::Default);
    }

    #[test]
    fn only_the_highlighted_row_is_reversed_and_the_bar_sits_left_of_the_pane() {
        let layout = Layout {
            cols: 30,
            rows: 3,
            pane_x: 25,
            pane_rows: 2,
            status: quiet(),
            help: false,
            resizing: None,
            copy: None,
            geometry: Default::default(),
            active: Some(pane_id()),
            sidebar: vec![line(1, "\u{754c}", true), line(2, "/tmp", false)],
            choosing: Some(1),
        };
        let grid = draw_ui(&layout);
        let shown: Vec<String> = (0..2)
            .map(|y| {
                let row = &grid[y * 30..(y + 1) * 30];
                let reversed = row
                    .iter()
                    .filter(|c| c.style.attrs.has(Attribute::Inverse))
                    .count();
                format!("row {y}: {reversed} reversed; bar={}", row[24].text)
            })
            .collect();
        assert_eq!(
            shown,
            [
                "row 0: 0 reversed; bar=\u{2502}",
                "row 1: 24 reversed; bar=\u{2502}"
            ]
        );
    }

    #[test]
    fn a_mark_has_its_own_colour_except_on_the_reversed_row_and_titles_stay_aligned() {
        let marked = |number: u64, mark: Mark, selected: bool| Line {
            mark,
            ..line(number, "zsh", selected)
        };
        let layout = Layout {
            cols: 30,
            rows: 4,
            pane_x: 25,
            pane_rows: 3,
            status: quiet(),
            help: false,
            resizing: None,
            copy: None,
            geometry: Default::default(),
            active: Some(pane_id()),
            sidebar: vec![
                marked(1, Mark::Running, false),
                marked(2, Mark::Waiting, true),
                marked(3, Mark::None, false),
            ],
            choosing: None,
        };
        let grid = draw_ui(&layout);
        let at = |y: usize, x: usize| &grid[y * 30 + x];
        let seen: Vec<(String, Colour, bool, bool)> = (0..3)
            .map(|y| {
                let cell = at(y, 2);
                (
                    cell.text.clone(),
                    cell.style.fg,
                    cell.style.attrs.has(Attribute::Bold),
                    cell.style.attrs.has(Attribute::Inverse),
                )
            })
            .collect();
        assert_eq!(
            seen,
            [
                ("\u{25fc}".to_owned(), Colour::Indexed(2), false, false),
                ("\u{25c6}".to_owned(), Colour::Default, false, true),
                (" ".to_owned(), Colour::Default, false, false),
            ]
        );
        assert!((0..3).all(|y| at(y, 3).text == "z" && at(y, 3).style.fg == Colour::Default));
    }

    #[test]
    fn a_one_column_terminal_draws_no_negative_width() {
        let layout = Layout {
            cols: 1,
            rows: 2,
            pane_x: 0,
            pane_rows: 1,
            status: Status {
                left: "kido".to_owned(),
                ..quiet()
            },
            help: false,
            resizing: None,
            copy: None,
            geometry: Default::default(),
            active: Some(pane_id()),
            sidebar: vec![line(1, "sh", true)],
            choosing: None,
        };
        assert_eq!(draw_ui(&layout)[1].text, "k");
    }

    #[test]
    fn a_frame_and_a_cursor_paint_once_inside_synchronized_output() {
        let layout = Layout {
            cols: 4,
            rows: 3,
            pane_x: 0,
            pane_rows: 2,
            status: quiet(),
            help: false,
            resizing: None,
            copy: None,
            geometry: std::rc::Rc::new(geometry(4, 2)),
            active: Some(pane_id()),
            sidebar: Vec::new(),
            choosing: None,
        };
        let cells = vec![
            Cell {
                text: "a".to_owned(),
                width: 1,
                style: Style::default(),
            };
            4
        ];
        let frame = Frame {
            cols: 2,
            rows: 2,
            cells,
            cursor: Some(ko_vt::render::FrameCursor {
                x: 1,
                y: 0,
                shape: CursorShape::Bar,
            }),
            mouse: ko_vt::render::MouseTracking::Off,
            keyboard: 0,
        };
        let (mut renderer, mut modes) = (Renderer::default(), Modes::default());
        let (mut first, mut second, mut third) = (String::new(), String::new(), String::new());
        let painted = [
            renderer.paint(&mut modes, &layout, &frames(1, &frame), &mut first),
            renderer.paint(&mut modes, &layout, &frames(1, &frame), &mut second),
            renderer.paint(&mut modes, &layout, &frames(2, &frame), &mut third),
        ];
        assert_eq!(painted, [true, false, true]);
        assert!(
            first.starts_with("\x1b[?2026h") && first.ends_with("\x1b[?2026l"),
            "{first:?}"
        );
        assert!(first.contains("\x1b[6 q\x1b[1;2H\x1b[?25h"), "{first:?}");
        assert_eq!(third, "");
    }

    #[test]
    fn a_pane_larger_than_its_region_is_clipped_and_a_smaller_one_is_padded() {
        let layout = Layout {
            cols: 6,
            rows: 4,
            pane_x: 0,
            pane_rows: 3,
            status: quiet(),
            help: false,
            resizing: None,
            copy: None,
            geometry: std::rc::Rc::new(geometry(6, 3)),
            active: Some(pane_id()),
            sidebar: Vec::new(),
            choosing: None,
        };
        let frame = |cols: u16, rows: u16| Frame {
            cols,
            rows,
            cells: vec![
                Cell {
                    text: "a".to_owned(),
                    width: 1,
                    style: Style::default(),
                };
                usize::from(cols) * usize::from(rows)
            ],
            cursor: Some(ko_vt::render::FrameCursor {
                x: cols - 1,
                y: rows - 1,
                shape: CursorShape::Block,
            }),
            mouse: ko_vt::render::MouseTracking::Off,
            keyboard: 0,
        };
        let drawn = |frame: &Frame| {
            let (mut renderer, mut modes) = (Renderer::default(), Modes::default());
            let mut out = String::new();
            renderer.paint(&mut modes, &layout, &frames(1, frame), &mut out);
            (out.matches('a').count(), out.contains("\x1b[?25h"))
        };
        assert_eq!(drawn(&frame(8, 5)), (18, false));
        assert_eq!(drawn(&frame(2, 1)), (2, true));
    }

    #[test]
    fn the_status_line_is_green_with_the_left_text_and_the_right_field_at_the_edge() {
        let layout = Layout {
            cols: 20,
            rows: 3,
            pane_x: 0,
            pane_rows: 2,
            status: Status {
                left: "[s] 0:a* 1:b-".to_owned(),
                right: "C-a".to_owned(),
            },
            help: false,
            resizing: None,
            copy: None,
            geometry: Default::default(),
            active: Some(pane_id()),
            sidebar: Vec::new(),
            choosing: None,
        };
        let grid = draw_ui(&layout);
        let row = &grid[40..60];
        let text: String = row.iter().map(|cell| cell.text.as_str()).collect();
        assert_eq!(text, "[s] 0:a* 1:b-    C-a");
        assert!(
            row.iter()
                .all(|cell| cell.style.bg == Colour::Indexed(2)
                    && cell.style.fg == Colour::Indexed(0))
        );
        assert!(
            grid[..40]
                .iter()
                .all(|cell| cell.style.bg == Colour::Default)
        );
    }

    #[test]
    fn the_help_covers_the_pane_and_the_pane_frame_is_not_drawn() {
        let layout = Layout {
            cols: 40,
            rows: 20,
            pane_x: 0,
            pane_rows: 19,
            status: quiet(),
            help: true,
            resizing: None,
            copy: None,
            geometry: std::rc::Rc::new(geometry(40, 19)),
            active: Some(pane_id()),
            sidebar: Vec::new(),
            choosing: None,
        };
        let frame = Frame {
            cols: 40,
            rows: 19,
            cells: vec![
                Cell {
                    text: "Z".to_owned(),
                    width: 1,
                    style: Style::default(),
                };
                40 * 19
            ],
            cursor: None,
            mouse: ko_vt::render::MouseTracking::Off,
            keyboard: 0,
        };
        let (mut renderer, mut modes) = (Renderer::default(), Modes::default());
        let mut out = String::new();
        renderer.paint(&mut modes, &layout, &frames(1, &frame), &mut out);
        assert!(out.contains("C-a C-a"), "{out:?}");
        assert!(!out.contains('Z'), "{out:?}");
    }

    fn composed(layout: &Layout, frames: &[PaneFrame<'_>]) -> Frame {
        let mut output = String::new();
        Renderer::default().paint(&mut Modes::default(), layout, frames, &mut output);
        let mut vt = ko_vt::Terminal::new(
            ko_pane_wire::frame::Dim::new(u16::try_from(layout.cols).unwrap()).unwrap(),
            ko_pane_wire::frame::Dim::new(u16::try_from(layout.rows).unwrap()).unwrap(),
            ko_server::config::default_limits(),
        )
        .unwrap();
        vt.watch().unwrap();
        vt.write(output.as_bytes());
        let mut frame = Frame::default();
        vt.render_into(&mut frame).unwrap();
        frame
    }

    #[test]
    fn dividers_follow_the_active_pane_and_small_frames_leave_blank_cells() {
        let mut window: Window = ko_server::protocol::decode(br#"{"id":"window_1","name":"w","vars":{},"cols":9,"rows":5,"focus":"pane_1","tree":{"split":"h","children":[{"pane":"pane_1","cols":4,"rows":5},{"split":"v","children":[{"pane":"pane_2","cols":4,"rows":2},{"pane":"pane_3","cols":4,"rows":2}]}]},"floats":[]}"#).unwrap();
        let mut layout = Layout {
            cols: 9,
            rows: 6,
            pane_x: 0,
            pane_rows: 5,
            status: quiet(),
            help: false,
            resizing: None,
            copy: None,
            geometry: std::rc::Rc::new(crate::geometry::window(&window)),
            active: Some(pane_id()),
            sidebar: Vec::new(),
            choosing: None,
        };
        let small = Frame {
            cols: 1,
            rows: 1,
            cells: vec![Cell {
                text: "A".to_owned(),
                width: 1,
                style: Style::default(),
            }],
            ..Frame::default()
        };
        let input = frames(1, &small);
        let frame = composed(&layout, &input);
        let at = |x: usize, y: usize| &frame.cells[y * 9 + x];
        assert_eq!(
            (at(4, 0).text.as_str(), at(4, 0).style.fg),
            ("│", Colour::Indexed(2))
        );
        assert_eq!(
            (at(4, 2).text.as_str(), at(4, 2).style.fg),
            ("├", Colour::Indexed(2))
        );
        assert_eq!(
            (at(5, 2).text.as_str(), at(5, 2).style.fg),
            ("─", Colour::Default)
        );
        assert_eq!(at(0, 0).text, "A");
        assert_eq!(at(1, 0).text.trim(), "");
        assert_eq!(at(0, 1).text.trim(), "");

        layout.resizing = Some(Resizing::Panes);
        let frame = composed(&layout, &input);
        assert_eq!(frame.cells[4].style.fg, Colour::Indexed(3));
        assert_eq!(frame.cells[2 * 9 + 4].style.fg, Colour::Indexed(3));
        assert_eq!(frame.cells[2 * 9 + 5].style.fg, Colour::Default);
        layout.resizing = None;
        layout.active = Some("pane_2".parse().unwrap());
        let frame = composed(&layout, &input);
        assert_eq!(frame.cells[2 * 9 + 4].style.fg, Colour::Indexed(2));
        assert_eq!(frame.cells[2 * 9 + 5].style.fg, Colour::Indexed(2));
        assert_eq!(frame.cells[4 * 9 + 4].style.fg, Colour::Default);

        window.floats.push(ko_server::protocol::Float {
            pane: "pane_4".parse().unwrap(),
            x: 3,
            y: 2,
            cols: ko_server::protocol::Cells::try_from(3u16).unwrap(),
            rows: ko_server::protocol::Cells::try_from(1u16).unwrap(),
            z: 1,
            border: true,
            title: "pop".to_owned(),
        });
        layout.geometry = std::rc::Rc::new(crate::geometry::window(&window));
        let floating = Frame {
            cols: 3,
            rows: 1,
            cells: vec![
                Cell {
                    text: "F".to_owned(),
                    width: 1,
                    style: Style::default()
                };
                3
            ],
            ..Frame::default()
        };
        let mut input = input;
        input.push(PaneFrame {
            pane: "pane_4".parse().unwrap(),
            serial: 2,
            frame: &floating,
            dead: None,
        });
        let frame = composed(&layout, &input);
        let row = |y: usize| {
            frame.cells[y * 9..(y + 1) * 9]
                .iter()
                .map(|cell| cell.text.as_str())
                .collect::<String>()
        };
        assert_eq!(row(1).chars().skip(2).take(5).collect::<String>(), "┌pop┐");
        assert_eq!(frame.cells[2 * 9 + 4].text, "F");
        assert_eq!(frame.cells[3 * 9 + 2].text, "└");
    }

    #[test]
    fn a_float_blanks_both_halves_of_occluded_wide_cells_on_each_paint() {
        let underlying = pane_id();
        let floating = "pane_2".parse().unwrap();
        let geometry = Geometry {
            panes: vec![
                crate::geometry::Pane {
                    pane: underlying,
                    rect: Rect {
                        x: 0,
                        y: 0,
                        cols: 10,
                        rows: 3,
                    },
                    border: None,
                },
                crate::geometry::Pane {
                    pane: floating,
                    rect: Rect {
                        x: 3,
                        y: 1,
                        cols: 3,
                        rows: 1,
                    },
                    border: Some(String::new()),
                },
            ],
            dividers: Vec::new(),
        };
        let layout = Layout {
            cols: 10,
            rows: 4,
            pane_x: 0,
            pane_rows: 3,
            status: quiet(),
            help: false,
            resizing: None,
            copy: None,
            geometry: std::rc::Rc::new(geometry),
            active: Some(floating),
            sidebar: Vec::new(),
            choosing: None,
        };
        let mut tree = Frame {
            cols: 10,
            rows: 3,
            cells: vec![blank(); 30],
            ..Frame::default()
        };
        let float = Frame {
            cols: 3,
            rows: 1,
            cells: vec![
                Cell {
                    text: "F".to_owned(),
                    width: 1,
                    style: Style::default()
                };
                3
            ],
            ..Frame::default()
        };
        let mut vt = ko_vt::Terminal::new(
            ko_pane_wire::frame::Dim::new(10).unwrap(),
            ko_pane_wire::frame::Dim::new(4).unwrap(),
            ko_server::config::default_limits(),
        )
        .unwrap();
        vt.watch().unwrap();
        let (mut renderer, mut modes) = (Renderer::default(), Modes::default());
        for (serial, text) in [(1, "界"), (2, "語")] {
            for y in 0..3 {
                for x in [1, 6] {
                    tree.cells[y * 10 + x] = Cell {
                        text: text.to_owned(),
                        width: 2,
                        style: Style::default(),
                    };
                    tree.cells[y * 10 + x + 1] = Cell {
                        text: String::new(),
                        width: 0,
                        style: Style::default(),
                    };
                }
            }
            let frames = [
                PaneFrame {
                    pane: underlying,
                    serial,
                    frame: &tree,
                    dead: None,
                },
                PaneFrame {
                    pane: floating,
                    serial: 1,
                    frame: &float,
                    dead: None,
                },
            ];
            let mut output = String::new();
            renderer.paint(&mut modes, &layout, &frames, &mut output);
            vt.write(output.as_bytes());
            let mut frame = Frame::default();
            vt.render_into(&mut frame).unwrap();
            assert_eq!(frame.cells[11].text.trim(), "");
            assert_eq!(frame.cells[12].text, "│");
            assert_eq!(frame.cells[16].text, "│");
            assert_eq!(frame.cells[17].text.trim(), "");
            assert_eq!((frame.cells[11].width, frame.cells[17].width), (1, 1));
        }
    }

    fn session() -> Session {
        let window = |id: u32, name: &str| {
            format!(
                r#"{{"id":"window_{id}","name":"{name}","vars":{{}},"cols":80,"rows":24,"focus":"pane_{id}","tree":{{"pane":"pane_{id}","cols":80,"rows":24}},"floats":[]}}"#
            )
        };
        let text = format!(
            r#"{{"id":"session_1","name":"s","vars":{{}},"windows":[{},{},{}]}}"#,
            window(1, "a"),
            window(2, "b"),
            window(3, "c")
        );
        ko_server::protocol::decode(text.as_bytes()).unwrap()
    }

    #[test]
    fn the_status_names_the_windows_marks_shown_and_last_and_fills_the_right_field() {
        let session = session();
        let window = |at: usize| &session.windows[at];
        let shown = Some((&session, window(0)));
        let last = Some(window(1).id);
        let right = |state: &State, reconnect: Option<&str>| {
            status(shown, last, state, Mode::Pane, reconnect).right
        };
        assert_eq!(
            status(shown, last, &State::Normal, Mode::Pane, None).left,
            "[s] 0:a* 1:b- 2:c"
        );
        assert_eq!(
            status(None, last, &State::Normal, Mode::Pane, None).left,
            ""
        );
        assert_eq!(right(&State::Normal, None), "");
        assert_eq!(right(&State::Prefix, None), "C-a");
        assert_eq!(
            status(shown, last, &State::Normal, Mode::Resize, None).right,
            "[resize]"
        );
        assert_eq!(
            status(
                shown,
                last,
                &State::Normal,
                Mode::Sidebar("pane_1".parse().unwrap()),
                None
            )
            .right,
            "[sidebar]"
        );
        assert_eq!(
            right(
                &State::Rename {
                    of: Rename::Session,
                    text: "x".to_owned()
                },
                None
            ),
            "(rename-session) x"
        );
        assert_eq!(
            right(&State::Confirm(Kill::Window), None),
            "kill-window a? (y/n)"
        );
        assert_eq!(right(&State::Confirm(Kill::Pane), None), "kill-pane? (y/n)");
        for mode in [Mode::Resize, Mode::Sidebar("pane_1".parse().unwrap())] {
            for (state, expected) in [
                (State::Prefix, "C-a"),
                (
                    State::Rename {
                        of: Rename::Session,
                        text: "x".to_owned(),
                    },
                    "(rename-session) x",
                ),
                (State::Confirm(Kill::Pane), "kill-pane? (y/n)"),
            ] {
                assert_eq!(status(shown, last, &state, mode, None).right, expected);
            }
        }
        assert_eq!(
            right(&State::Prefix, Some("box")),
            "[reconnecting to box \u{2014} C-a d to detach]"
        );
    }

    #[test]
    fn a_wide_name_that_meets_the_right_field_leaves_no_half_cell() {
        let layout = Layout {
            cols: 10,
            rows: 2,
            pane_x: 0,
            pane_rows: 1,
            status: Status {
                left: "ab\u{754c}\u{754c}\u{754c}".to_owned(),
                right: "C-a".to_owned(),
            },
            help: false,
            resizing: None,
            copy: None,
            geometry: Default::default(),
            active: Some(pane_id()),
            sidebar: Vec::new(),
            choosing: None,
        };
        let row: Vec<(String, u8)> = draw_ui(&layout)[10..]
            .iter()
            .map(|cell| (cell.text.clone(), cell.width))
            .collect();
        let text: String = row.iter().map(|(text, _)| text.as_str()).collect();
        assert_eq!(text, "ab\u{754c}\u{754c} C-a");
        assert_eq!(row[6], (" ".to_owned(), 1));
    }
}

use std::fmt::Write;

use ko_client::status::Mark;
use ko_server::ids::WindowId;
use ko_server::protocol::{Session, Window};
use ko_vt::render::{Attribute, Attributes, Cell, Colour, CursorShape, Frame, Style};
use ko_vt::unicode::clusters;

use crate::differ::Differ;
use crate::keys::{HELP, Kill, Rename, State};
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
    let _ = match (reconnect, state) {
        (Some(host), _) => write!(right, "[reconnecting to {host} \u{2014} C-a d to detach]"),
        (None, State::Prefix) => right.write_str("C-a"),
        (None, State::Rename { of, text }) => {
            let what = match of {
                Rename::Session => "rename-session",
                Rename::Window => "rename-window",
            };
            write!(right, "({what}) {text}")
        }
        (None, State::Confirm(Kill::Window)) => write!(
            right,
            "kill-window {}? (y/n)",
            shown.map_or("", |(_, window)| window.name.as_str())
        ),
        (None, State::Confirm(Kill::Pane)) => right.write_str("kill-pane? (y/n)"),
        (None, State::Normal | State::Help | State::Chooser(_)) => Ok(()),
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
    pub(crate) dead: Option<String>,
    pub(crate) sidebar: Vec<Line>,
    pub(crate) choosing: Option<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cursor {
    Hidden,
    Visible(usize, usize, CursorShape),
}

#[derive(Debug, Default)]
pub(crate) struct Renderer {
    differ: Differ,
    layout: Option<Layout>,
    frame: Option<u64>,
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

fn put(grid: &mut [Cell], cols: usize, x: usize, y: usize, cell: Cell) {
    if x < cols
        && let Some(slot) = grid.get_mut(y * cols + x)
    {
        *slot = cell;
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
        put(grid, cols, x + at, y, blank);
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
            put(grid, cols, at, y, cell(cluster, wide.max(1)));
            if wide == 2 {
                put(grid, cols, at + 1, y, cell("", 0));
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

fn columns(text: &str) -> usize {
    clusters(text)
        .iter()
        .map(|(_, wide)| usize::from(*wide))
        .sum()
}

fn draw_status(grid: &mut [Cell], cols: usize, y: usize, status: &Status) {
    let base = Style {
        fg: Colour::Indexed(0),
        bg: Colour::Indexed(2),
        ..Style::default()
    };
    let right = columns(&status.right).min(cols);
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
                style: Style::default(),
            };
            put(&mut grid, l.cols, l.pane_x - 1, y, bar);
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
    if let Some(dead) = &l.dead {
        draw_line(
            &mut grid,
            l.cols,
            (l.pane_x, l.pane_rows.saturating_sub(1)),
            l.cols.saturating_sub(l.pane_x),
            reversed(),
            dead,
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
        draw_status(&mut grid, l.cols, y, &l.status);
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
        frame: Option<(u64, &Frame)>,
        out: &mut String,
    ) -> bool {
        let ui_changed = self.layout.as_ref() != Some(layout);
        let serial = frame.map(|(serial, _)| serial);
        if !ui_changed && self.frame == serial {
            return false;
        }
        let l = layout;
        let shift = usize::from(l.dead.is_some());
        let live = l.pane_rows.saturating_sub(shift);
        self.frame = serial;
        if ui_changed {
            self.layout = Some(l.clone());
            let mut ui = draw_ui(l);
            for (i, cell) in ui.iter_mut().enumerate() {
                if !l.help && i % l.cols.max(1) >= l.pane_x && i / l.cols.max(1) < live {
                    *cell = blank();
                }
            }
            self.ui = ui;
        }
        self.cells.clone_from(&self.ui);
        let start = out.len();
        out.push_str("\x1b[?2026h");
        let prefix = out.len();
        if let Some((_, f)) = frame {
            let (fcols, frows) = (usize::from(f.cols), usize::from(f.rows));
            let covered = if l.help { 0 } else { live };
            for y in 0..covered.min(frows.saturating_sub(shift)) {
                for x in 0..l.cols.saturating_sub(l.pane_x).min(fcols) {
                    let Some(c) = f.cells.get((y + shift) * fcols + x) else {
                        continue;
                    };
                    let clipped = c.width == 2 && x + l.pane_x == l.cols - 1;
                    if let Some(slot) = self.cells.get_mut(y * l.cols + x + l.pane_x) {
                        if clipped {
                            slot.text.clear();
                        } else {
                            slot.text.clone_from(&c.text);
                        }
                        slot.width = if clipped { 1 } else { c.width };
                        slot.style = c.style;
                    }
                }
            }
            modes.apply(f.mouse, f.keyboard, out);
        }
        let before = out.len();
        self.differ.draw(l.cols, &mut self.cells, out);
        let drew = out.len() > before;
        let cursor = match frame {
            Some((_, f)) => match f.cursor {
                Some(c)
                    if l.dead.is_none()
                        && !l.help
                        && usize::from(c.x) < l.cols.saturating_sub(l.pane_x)
                        && usize::from(c.y) < l.pane_rows =>
                {
                    Cursor::Visible(l.pane_x + usize::from(c.x), usize::from(c.y), c.shape)
                }
                _ => Cursor::Hidden,
            },
            None => Cursor::Hidden,
        };
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
    fn only_the_highlighted_row_is_reversed_and_the_bar_sits_left_of_the_pane() {
        let layout = Layout {
            cols: 30,
            rows: 3,
            pane_x: 25,
            pane_rows: 2,
            status: quiet(),
            help: false,
            dead: None,
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
            dead: None,
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
            pane_x: crate::sidebar::pane_x(1),
            pane_rows: 1,
            status: Status {
                left: "kido".to_owned(),
                ..quiet()
            },
            help: false,
            dead: Some("[exited 1]".to_owned()),
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
            dead: None,
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
            renderer.paint(&mut modes, &layout, Some((1, &frame)), &mut first),
            renderer.paint(&mut modes, &layout, Some((1, &frame)), &mut second),
            renderer.paint(&mut modes, &layout, Some((2, &frame)), &mut third),
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
            dead: None,
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
            renderer.paint(&mut modes, &layout, Some((1, frame)), &mut out);
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
            dead: None,
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
            dead: None,
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
        renderer.paint(&mut modes, &layout, Some((1, &frame)), &mut out);
        assert!(out.contains("C-a C-a"), "{out:?}");
        assert!(!out.contains('Z'), "{out:?}");
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
        let right =
            |state: &State, reconnect: Option<&str>| status(shown, last, state, reconnect).right;
        assert_eq!(
            status(shown, last, &State::Normal, None).left,
            "[s] 0:a* 1:b- 2:c"
        );
        assert_eq!(status(None, last, &State::Normal, None).left, "");
        assert_eq!(right(&State::Normal, None), "");
        assert_eq!(right(&State::Prefix, None), "C-a");
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
            dead: None,
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

use ko_vt::render::{Attribute, Attributes, Cell, Colour, CursorShape, Frame, Style};
use ko_vt::unicode::clusters;

use crate::differ::Differ;
use crate::modes::Modes;
use ko_client::status::Mark;

use crate::sidebar::Line;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Layout {
    pub(crate) cols: usize,
    pub(crate) rows: usize,
    pub(crate) pane_x: usize,
    pub(crate) pane_rows: usize,
    pub(crate) warning: bool,
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
    inverse: bool,
    parts: &[(&str, Style)],
) {
    let base = Style {
        attrs: if inverse {
            Attributes::default().with(Attribute::Inverse)
        } else {
            Attributes::default()
        },
        ..Style::default()
    };
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
        let style = if inverse { base } else { *style };
        for (cluster, wide) in clusters(text) {
            if at + usize::from(wide) > x + width {
                return;
            }
            let cell = |text: &str, width| Cell {
                text: text.to_owned(),
                width,
                style,
            };
            put(grid, cols, at, y, cell(cluster, wide.max(1)));
            if wide == 2 {
                put(grid, cols, at + 1, y, cell("", 0));
            }
            at += usize::from(wide);
        }
    }
}

fn draw_line(
    grid: &mut [Cell],
    cols: usize,
    at: (usize, usize),
    width: usize,
    inverse: bool,
    text: &str,
) {
    draw_row(grid, cols, at, width, inverse, &[(text, Style::default())]);
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
            draw_line(&mut grid, l.cols, (0, y), l.pane_x - 1, false, "");
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
        draw_row(
            &mut grid,
            l.cols,
            (0, y),
            l.pane_x.saturating_sub(1),
            inverse,
            &[
                (&line.lead, Style::default()),
                (mark, style),
                (&line.title, Style::default()),
            ],
        );
    }
    if let Some(dead) = &l.dead {
        draw_line(
            &mut grid,
            l.cols,
            (l.pane_x, l.pane_rows.saturating_sub(1)),
            l.cols.saturating_sub(l.pane_x),
            true,
            dead,
        );
    }
    if l.warning {
        draw_line(
            &mut grid,
            l.cols,
            (0, l.rows.saturating_sub(1)),
            l.cols,
            true,
            "ko: extended keys were not confirmed; use sidebar mouse switching",
        );
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
                if i % l.cols.max(1) >= l.pane_x && i / l.cols.max(1) < live {
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
            for y in 0..live.min(frows.saturating_sub(shift)) {
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

    fn line(number: u64, title: &str, selected: bool) -> Line {
        Line {
            pane: format!("pane_{number}").parse().unwrap(),
            lead: format!("{number} "),
            mark: Mark::None,
            title: title.to_owned(),
            selected,
        }
    }

    #[test]
    fn only_the_highlighted_row_is_reversed_and_the_bar_sits_left_of_the_pane() {
        let layout = Layout {
            cols: 30,
            rows: 2,
            pane_x: 25,
            pane_rows: 2,
            warning: false,
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
            rows: 3,
            pane_x: 25,
            pane_rows: 3,
            warning: false,
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
            rows: 1,
            pane_x: crate::sidebar::pane_x(1),
            pane_rows: 1,
            warning: true,
            dead: Some("[exited 1]".to_owned()),
            sidebar: vec![line(1, "sh", true)],
            choosing: None,
        };
        assert_eq!(draw_ui(&layout)[0].text, "k");
    }

    #[test]
    fn a_frame_and_a_cursor_paint_once_inside_synchronized_output() {
        let layout = Layout {
            cols: 4,
            rows: 2,
            pane_x: 0,
            pane_rows: 2,
            warning: false,
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
}

use std::fmt::Write as _;

use ko_vt::render::{Attribute, Cell, Colour, Style};

#[derive(Debug, Default)]
pub(crate) struct Differ {
    cells: Vec<Cell>,
    cols: usize,
}

const ENABLE: [(Attribute, u8); 9] = [
    (Attribute::Bold, 1),
    (Attribute::Dim, 2),
    (Attribute::Italic, 3),
    (Attribute::Underline, 4),
    (Attribute::Blink, 5),
    (Attribute::Inverse, 7),
    (Attribute::Hidden, 8),
    (Attribute::Strikethrough, 9),
    (Attribute::Overline, 53),
];

fn disable(attribute: Attribute) -> u8 {
    match attribute {
        Attribute::Bold | Attribute::Dim => 22,
        Attribute::Italic => 23,
        Attribute::Underline => 24,
        Attribute::Blink => 25,
        Attribute::Inverse => 27,
        Attribute::Hidden => 28,
        Attribute::Strikethrough => 29,
        Attribute::Overline => 55,
    }
}

struct Codes<'a> {
    out: &'a mut String,
    first: bool,
}

impl Codes<'_> {
    fn push(&mut self, code: u8) {
        if !self.first {
            self.out.push(';');
        }
        self.first = false;
        let _ = write!(self.out, "{code}");
    }

    fn colour(&mut self, colour: Colour, background: bool) {
        let base = if background { 48 } else { 38 };
        match colour {
            Colour::Default => self.push(base + 1),
            Colour::Indexed(index) => {
                self.push(base);
                self.push(5);
                self.push(index);
            }
            Colour::Rgb(r, g, b) => {
                self.push(base);
                self.push(2);
                self.push(r);
                self.push(g);
                self.push(b);
            }
        }
    }
}

fn sgr(prev: Style, style: Style, out: &mut String) {
    if prev == style {
        return;
    }
    out.push_str("\x1b[");
    let mut codes = Codes { out, first: true };
    if style == Style::default() {
        codes.push(0);
    } else {
        let removed = |attribute| prev.attrs.has(attribute) && !style.attrs.has(attribute);
        let mut intensity = false;
        for (attribute, _) in ENABLE {
            if removed(attribute) {
                let code = disable(attribute);
                if code != 22 || !std::mem::replace(&mut intensity, true) {
                    codes.push(code);
                }
            }
        }
        if prev.fg != style.fg {
            codes.colour(style.fg, false);
        }
        if prev.bg != style.bg {
            codes.colour(style.bg, true);
        }
        let shared = removed(Attribute::Bold) || removed(Attribute::Dim);
        for (attribute, code) in ENABLE {
            let added = style.attrs.has(attribute) && !prev.attrs.has(attribute);
            let again = shared
                && matches!(attribute, Attribute::Bold | Attribute::Dim)
                && style.attrs.has(attribute);
            if added || again {
                codes.push(code);
            }
        }
    }
    out.push('m');
}

impl Differ {
    pub(crate) fn invalidate(&mut self) {
        self.cells.clear();
    }

    pub(crate) fn draw(&mut self, cols: usize, cells: &mut Vec<Cell>, out: &mut String) {
        let cols = cols.max(1);
        let start = out.len();
        let force = self.cols != cols || self.cells.len() != cells.len();
        if force {
            out.push_str("\x1b[0m");
        }
        let (mut at, mut pen): (Option<usize>, Option<Style>) = (None, None);
        for (i, cell) in cells.iter().enumerate() {
            let same = !force && self.cells.get(i) == Some(cell);
            if cell.width == 0 || same {
                continue;
            }
            if at != Some(i) {
                let _ = write!(out, "\x1b[{};{}H", i / cols + 1, i % cols + 1);
            }
            if pen != Some(cell.style) {
                sgr(pen.unwrap_or_default(), cell.style, out);
                pen = Some(cell.style);
            }
            out.push_str(if cell.text.is_empty() {
                " "
            } else {
                &cell.text
            });
            at = (i % cols + usize::from(cell.width) < cols).then_some(i + usize::from(cell.width));
        }
        std::mem::swap(&mut self.cells, cells);
        self.cols = cols;
        if out.len() > start {
            out.push_str("\x1b[0m");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(text: &str, width: u8, style: Style) -> Cell {
        Cell {
            text: text.to_owned(),
            width,
            style,
        }
    }

    fn drawn(differ: &mut Differ, cols: usize, cells: &[Cell]) -> String {
        let mut out = String::new();
        differ.draw(cols, &mut cells.to_vec(), &mut out);
        out
    }

    #[test]
    fn indexed_rgb_and_unchanged_cells() {
        let mut differ = Differ::default();
        let style = Style {
            fg: Colour::Indexed(2),
            ..Style::default()
        };
        let mut cells = [cell("a", 1, style), cell("b", 1, style)];
        let shown = [
            drawn(&mut differ, 2, &cells),
            drawn(&mut differ, 2, &cells),
            {
                cells[1].style.fg = Colour::Rgb(1, 2, 3);
                drawn(&mut differ, 2, &cells)
            },
        ];
        assert_eq!(
            shown,
            [
                "\x1b[0m\x1b[1;1H\x1b[38;5;2mab\x1b[0m",
                "",
                "\x1b[1;2H\x1b[38;2;1;2;3mb\x1b[0m"
            ]
        );
    }

    #[test]
    fn wide_tails() {
        let mut differ = Differ::default();
        let plain = Style::default();
        let cells = [
            cell("界", 2, plain),
            cell("", 0, plain),
            cell("x", 1, plain),
            cell("", 1, plain),
        ];
        assert_eq!(
            drawn(&mut differ, 2, &cells),
            "\x1b[0m\x1b[1;1H界\x1b[2;1Hx \x1b[0m"
        );
    }
}

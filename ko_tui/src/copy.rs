use std::sync::Arc;

use ko_pane_wire::frame::{Cell, Match};
use ko_vt::unicode::{clusters, width};
use ko_vt::{Shape, Span};

use crate::input::{KeyEvent, MouseKind, Name};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Selection {
    Character(Cell),
    Line { anchor: Cell, first: u32, last: u32 },
    Rectangle(Cell),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Jump {
    Forward,
    Backward,
    Before,
    After,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WordClass {
    Blank,
    Word,
    Punctuation,
}

fn class(c: char, big: bool) -> WordClass {
    if c.is_whitespace() {
        WordClass::Blank
    } else if big || c.is_alphanumeric() || c == '_' {
        WordClass::Word
    } else {
        WordClass::Punctuation
    }
}

fn run_start(cells: &[(u16, u16, char)], mut at: usize, big: bool) -> usize {
    let kind = cells.get(at).map(|(_, _, c)| class(*c, big));
    while at > 0
        && cells
            .get(at - 1)
            .is_some_and(|(_, _, c)| Some(class(*c, big)) == kind)
    {
        at -= 1;
    }
    at
}

fn run_end(cells: &[(u16, u16, char)], mut at: usize, big: bool) -> usize {
    let kind = cells.get(at).map(|(_, _, c)| class(*c, big));
    while cells
        .get(at + 1)
        .is_some_and(|(_, _, c)| Some(class(*c, big)) == kind)
    {
        at += 1;
    }
    at
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Outcome {
    Stay,
    Leave,
    Copy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Entry {
    Here,
    PageUp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Row {
    pub(crate) text: String,
    pub(crate) wraps: bool,
}

impl Row {
    fn cells(&self) -> Vec<(u16, u16, char)> {
        let mut col = 0u16;
        clusters(&self.text)
            .into_iter()
            .map(|(text, width)| {
                let at = col;
                col = col.saturating_add(u16::from(width.max(1)));
                (
                    at,
                    u16::from(width.max(1)),
                    text.chars().next().unwrap_or(' '),
                )
            })
            .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Direction {
    Forward,
    Backward,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SearchState {
    Normal,
    Prompt(Direction, String),
    Searching(Direction, String),
    NoMatch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Found {
    direction: Direction,
    text: String,
    matches: Arc<[Match]>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Highlight {
    None,
    Selected,
    Match,
    Current,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Mode {
    cols: u16,
    rows: u32,
    total: u32,
    offset: u32,
    cursor: Cell,
    selection: Option<Selection>,
    pending: Option<Jump>,
    jump: Option<(Jump, char)>,
    search: SearchState,
    last: Option<Found>,
}

fn ordered(a: Cell, b: Cell) -> (Cell, Cell) {
    if (a.row, a.col) <= (b.row, b.col) {
        (a, b)
    } else {
        (b, a)
    }
}

impl Mode {
    pub(crate) fn open(
        cursor: ko_vt::Cursor,
        total: u32,
        offset: u32,
        size: (u16, u16),
        entry: Entry,
        mut row: impl FnMut(u32) -> Result<Row, String>,
    ) -> Result<Mode, String> {
        let (cols, rows) = size;
        let mut mode = Mode {
            cols,
            rows: u32::from(rows),
            total,
            offset,
            cursor: Cell {
                col: cursor.x,
                row: total
                    .saturating_sub(u32::from(rows))
                    .saturating_add(u32::from(cursor.y))
                    .clamp(
                        offset,
                        offset
                            .saturating_add(u32::from(rows).saturating_sub(1))
                            .min(total.saturating_sub(1)),
                    ),
            },
            selection: None,
            pending: None,
            jump: None,
            search: SearchState::Normal,
            last: None,
        };
        if entry == Entry::PageUp {
            mode.page(-i64::from(rows));
        }
        mode.normalize(&row(mode.cursor.row)?);
        Ok(mode)
    }

    pub(crate) fn offset(&self) -> u32 {
        self.offset
    }
    pub(crate) fn history(&self) -> u32 {
        self.total.saturating_sub(self.rows)
    }
    pub(crate) fn size(&self) -> (u16, u16) {
        (self.cols, self.rows as u16)
    }

    pub(crate) fn highlight(&self, span: Option<Span>, col: u16, y: u32, width: u8) -> Highlight {
        let point = Cell {
            col: if width == 0 {
                col.saturating_sub(1)
            } else {
                col
            },
            row: self.offset.saturating_add(y),
        };
        let width = if width == 0 { 2 } else { width };
        let selected = |point: Cell| {
            span.is_some_and(|span| match span.shape {
                Shape::Linear => {
                    (span.start.row, span.start.col) <= (point.row, point.col)
                        && (point.row, point.col) <= (span.end.row, span.end.col)
                }
                Shape::Rectangle => {
                    (span.start.row..=span.end.row).contains(&point.row)
                        && (span.start.col.min(span.end.col)..=span.start.col.max(span.end.col))
                            .contains(&point.col)
                }
            })
        };
        if point == self.cursor
            || selected(point)
            || (width == 2
                && selected(Cell {
                    col: point.col.saturating_add(1),
                    ..point
                }))
        {
            return Highlight::Selected;
        }
        let Some(found) = &self.last else {
            return Highlight::None;
        };
        let start = (point.row, point.col);
        let end = (
            point.row,
            point
                .col
                .saturating_add(u16::from(width.max(1)).saturating_sub(1)),
        );
        let at = found
            .matches
            .partition_point(|m| (m.end.row, m.end.col) < start);
        match found.matches.get(at) {
            Some(m) if (m.start.row, m.start.col) <= end => {
                if m.start == self.cursor {
                    Highlight::Current
                } else {
                    Highlight::Match
                }
            }
            _ => Highlight::None,
        }
    }

    pub(crate) fn range(&self) -> Option<Span> {
        let (anchor, shape) = match self.selection? {
            Selection::Character(anchor) => (anchor, Shape::Linear),
            Selection::Rectangle(anchor) => (anchor, Shape::Rectangle),
            Selection::Line { first, last, .. } => {
                return Some(Span {
                    start: Cell { col: 0, row: first },
                    end: Cell {
                        col: self.cols.saturating_sub(1),
                        row: last,
                    },
                    shape: Shape::Linear,
                });
            }
        };
        let (start, end) = ordered(anchor, self.cursor);
        Some(Span { start, end, shape })
    }

    fn visible(&mut self) {
        if self.cursor.row < self.offset {
            self.offset = self.cursor.row;
        }
        if self.cursor.row >= self.offset.saturating_add(self.rows) {
            self.offset = self.cursor.row.saturating_sub(self.rows.saturating_sub(1));
        }
        self.offset = self.offset.min(self.total.saturating_sub(self.rows));
    }

    fn page(&mut self, delta: i64) {
        self.cursor.row = (i64::from(self.cursor.row) + delta)
            .clamp(0, i64::from(self.total.saturating_sub(1))) as u32;
        self.scroll(delta);
    }

    fn scroll(&mut self, delta: i64) {
        self.offset = (i64::from(self.offset) + delta)
            .clamp(0, i64::from(self.total.saturating_sub(self.rows))) as u32;
        self.cursor.row = self.cursor.row.clamp(
            self.offset,
            self.offset
                .saturating_add(self.rows.saturating_sub(1))
                .min(self.total.saturating_sub(1)),
        );
    }

    fn normalize(&mut self, row: &Row) {
        self.cursor.col = self.cursor.col.min(self.cols.saturating_sub(1));
        let cells = row.cells();
        let width = width(&row.text).min(usize::from(u16::MAX)) as u16;
        if row.wraps && width == self.cols.saturating_sub(1) && self.cursor.col == width {
            self.cursor.col = self.cursor.col.saturating_sub(1);
        }
        if let Some((col, _, _)) = cells.iter().find(|(col, width, _)| {
            self.cursor.col >= *col && self.cursor.col < col.saturating_add(*width)
        }) {
            self.cursor.col = *col;
        }
    }

    fn horizontal(&mut self, right: bool, row: &Row) {
        let width = row
            .cells()
            .iter()
            .find(|(col, _, _)| *col == self.cursor.col)
            .map_or(1, |(_, width, _)| *width);
        self.cursor.col = if right {
            self.cursor
                .col
                .saturating_add(width)
                .min(self.cols.saturating_sub(1))
        } else {
            self.cursor.col.saturating_sub(1)
        };
        self.normalize(row);
    }

    fn word(&mut self, key: char, row: &Row) -> bool {
        let cells = row.cells();
        let big = key.is_ascii_uppercase();
        let class = |c| class(c, big);
        let at = cells
            .iter()
            .position(|(col, _, _)| *col >= self.cursor.col)
            .unwrap_or(cells.len());
        let target = match key.to_ascii_lowercase() {
            'b' => {
                if at == 0 {
                    return false;
                }
                let mut i = at.saturating_sub(1);
                while i > 0
                    && cells
                        .get(i)
                        .is_some_and(|(_, _, c)| class(*c) == WordClass::Blank)
                {
                    i -= 1;
                }
                run_start(&cells, i, big)
            }
            'e' => {
                let mut i = (at + 1).min(cells.len());
                while cells
                    .get(i)
                    .is_some_and(|(_, _, c)| class(*c) == WordClass::Blank)
                {
                    i += 1;
                }
                run_end(&cells, i, big)
            }
            _ => {
                let mut i = run_end(&cells, at, big).saturating_add(1);
                while cells
                    .get(i)
                    .is_some_and(|(_, _, c)| class(*c) == WordClass::Blank)
                {
                    i += 1;
                }
                i
            }
        };
        if let Some((col, _, _)) = cells.get(target) {
            self.cursor.col = *col;
            true
        } else {
            false
        }
    }

    fn word_motion(
        &mut self,
        key: char,
        row: &mut impl FnMut(u32) -> Result<Row, String>,
    ) -> Result<(), String> {
        if self.word(key, &row(self.cursor.row)?) {
            return Ok(());
        }
        let backward = matches!(key, 'b' | 'B');
        loop {
            let next = if backward {
                self.cursor.row.checked_sub(1)
            } else {
                self.cursor
                    .row
                    .checked_add(1)
                    .filter(|next| *next < self.total)
            };
            let Some(next) = next else {
                return Ok(());
            };
            self.cursor.row = next;
            let cells = row(next)?.cells();
            let big = key.is_ascii_uppercase();
            let found = if backward {
                cells.iter().rposition(|(_, _, c)| !c.is_whitespace())
            } else {
                cells.iter().position(|(_, _, c)| !c.is_whitespace())
            };
            if let Some(mut at) = found {
                if backward {
                    at = run_start(&cells, at, big);
                } else if matches!(key, 'e' | 'E') {
                    at = run_end(&cells, at, big);
                }
                self.cursor.col = cells.get(at).map_or(0, |(col, _, _)| *col);
                return Ok(());
            }
            self.cursor.col = 0;
        }
    }

    fn find(&mut self, jump: Jump, needle: char, row: &Row) -> bool {
        let forward = matches!(jump, Jump::Forward | Jump::Before);
        let till = matches!(jump, Jump::Before | Jump::After);
        let cells = row.cells();
        let found = if forward {
            cells
                .iter()
                .find(|(col, _, c)| *col > self.cursor.col && *c == needle)
        } else {
            cells
                .iter()
                .rev()
                .find(|(col, _, c)| *col < self.cursor.col && *c == needle)
        };
        if let Some((col, _, _)) = found {
            self.cursor.col = *col;
            if till {
                self.horizontal(!forward, row);
            }
            true
        } else {
            false
        }
    }

    pub(crate) fn feed(
        &mut self,
        event: &KeyEvent,
        mut read_row: impl FnMut(u32) -> Result<Row, String>,
        mut wraps: impl FnMut(u32) -> Result<bool, String>,
    ) -> Result<Outcome, String> {
        if self.search == SearchState::NoMatch {
            self.search = SearchState::Normal;
        }
        if let SearchState::Prompt(direction, text) = &mut self.search {
            match event.name {
                Name::Escape => self.search = SearchState::Normal,
                Name::Backspace if text.is_empty() => self.search = SearchState::Normal,
                Name::Backspace => {
                    text.pop();
                }
                Name::Enter => {
                    let direction = *direction;
                    let text = std::mem::take(text);
                    self.search = SearchState::Normal;
                    let text = if text.is_empty() {
                        self.last.as_ref().map(|found| found.text.clone())
                    } else {
                        Some(text)
                    };
                    if let Some(text) = text {
                        self.search = SearchState::Searching(direction, text);
                    }
                }
                _ => {
                    if let Some(c) = event.character().filter(|c| !c.is_control()) {
                        text.push(c);
                    }
                }
            }
            return Ok(Outcome::Stay);
        }
        if event.name == Name::Escape && matches!(self.search, SearchState::Searching(..)) {
            self.search = SearchState::Normal;
            self.pending = None;
            return Ok(Outcome::Stay);
        }
        let mut cache: Option<(u32, Row)> = None;
        let mut row = |at| {
            if cache.as_ref().is_none_or(|(cached, _)| *cached != at) {
                cache = Some((at, read_row(at)?));
            }
            cache
                .as_ref()
                .map(|(_, row)| row.clone())
                .ok_or_else(|| "copy row is missing".to_owned())
        };
        let before = (self.cursor, self.selection, self.offset);
        if let Some(jump) = self.pending.take() {
            if let Some(needle) = event.character() {
                self.find(jump, needle, &row(self.cursor.row)?);
                self.jump = Some((jump, needle));
            }
            return Ok(Outcome::Stay);
        }
        let key = event.character();
        match (event.ctrl(), event.name, key) {
            (_, Name::Escape, _) if self.selection.is_some() => {
                self.selection = None;
            }
            (_, Name::Escape, _) | (_, _, Some('q')) => return Ok(Outcome::Leave),
            (_, Name::Enter, _) | (_, _, Some('y')) => return Ok(Outcome::Copy),
            (Some('v'), _, _) => {
                self.selection = Some(match self.selection {
                    Some(Selection::Rectangle(anchor)) => Selection::Character(anchor),
                    Some(Selection::Character(anchor) | Selection::Line { anchor, .. }) => {
                        Selection::Rectangle(anchor)
                    }
                    None => Selection::Rectangle(self.cursor),
                })
            }
            (_, _, Some('/' | '?')) => {
                self.pending = None;
                self.search = SearchState::Prompt(
                    if key == Some('/') {
                        Direction::Forward
                    } else {
                        Direction::Backward
                    },
                    String::new(),
                );
            }
            (_, _, Some('n' | 'N')) => {
                if let Some(found) = &self.last {
                    let forward = (found.direction == Direction::Forward) != (key == Some('N'));
                    self.search_jump(forward);
                }
            }
            (_, _, Some(' ' | 'v')) => self.selection = Some(Selection::Character(self.cursor)),
            (_, _, Some('V')) => {
                self.selection = Some(Selection::Line {
                    anchor: self.cursor,
                    first: self.cursor.row,
                    last: self.cursor.row,
                })
            }
            (_, _, Some('o')) => {
                if let Some(selection) = &mut self.selection {
                    let anchor = match selection {
                        Selection::Character(anchor)
                        | Selection::Line { anchor, .. }
                        | Selection::Rectangle(anchor) => anchor,
                    };
                    std::mem::swap(anchor, &mut self.cursor);
                }
            }
            (_, Name::Left, _) | (_, _, Some('h')) => {
                self.horizontal(false, &row(self.cursor.row)?)
            }
            (_, Name::Right, _) | (_, _, Some('l')) => {
                self.horizontal(true, &row(self.cursor.row)?)
            }
            (_, Name::Up, _) | (_, _, Some('k')) => {
                self.cursor.row = self.cursor.row.saturating_sub(1)
            }
            (_, Name::Down, _) | (_, _, Some('j')) => {
                self.cursor.row = self
                    .cursor
                    .row
                    .saturating_add(1)
                    .min(self.total.saturating_sub(1))
            }
            (_, _, Some(word @ ('w' | 'b' | 'e' | 'W' | 'B' | 'E'))) => {
                self.word_motion(word, &mut row)?
            }
            (_, _, Some('0')) => self.cursor.col = 0,
            (_, _, Some('^')) => {
                self.cursor.col = row(self.cursor.row)?
                    .cells()
                    .iter()
                    .find(|(_, _, c)| !c.is_whitespace())
                    .map_or(0, |(col, _, _)| *col)
            }
            (_, _, Some('$')) => {
                self.cursor.col = row(self.cursor.row)?
                    .cells()
                    .last()
                    .map_or(0, |(col, _, _)| *col)
            }
            (_, _, Some('H')) => self.cursor.row = self.offset,
            (_, _, Some('M')) => {
                self.cursor.row = (self.offset + self.rows / 2).min(self.total.saturating_sub(1))
            }
            (_, _, Some('L')) => {
                self.cursor.row =
                    (self.offset + self.rows.saturating_sub(1)).min(self.total.saturating_sub(1))
            }
            (_, _, Some('g')) => self.cursor.row = 0,
            (_, _, Some('G')) => self.cursor.row = self.total.saturating_sub(1),
            (Some('b'), _, _) | (_, Name::PageUp, _) => {
                self.page(-i64::from(self.rows));
            }
            (Some('f'), _, _) | (_, Name::PageDown, _) => {
                self.page(i64::from(self.rows));
            }
            (Some('u'), _, _) => self.page(-i64::from((self.rows / 2).max(1))),
            (Some('d'), _, _) => self.page(i64::from((self.rows / 2).max(1))),
            (Some('y'), _, _) => self.scroll(-1),
            (Some('e'), _, _) => self.scroll(1),
            (_, _, Some('f' | 'F' | 't' | 'T')) => {
                self.pending = Some(match key {
                    Some('f') => Jump::Forward,
                    Some('F') => Jump::Backward,
                    Some('t') => Jump::Before,
                    _ => Jump::After,
                })
            }
            (_, _, Some(';' | ',')) => {
                if let Some((jump, needle)) = self.jump {
                    let jump = if key == Some(',') {
                        match jump {
                            Jump::Forward => Jump::Backward,
                            Jump::Backward => Jump::Forward,
                            Jump::Before => Jump::After,
                            Jump::After => Jump::Before,
                        }
                    } else {
                        jump
                    };
                    let before = self.cursor;
                    if matches!(jump, Jump::Before | Jump::After) {
                        self.horizontal(jump == Jump::Before, &row(self.cursor.row)?);
                    }
                    if !self.find(jump, needle, &row(self.cursor.row)?) {
                        self.cursor = before;
                    }
                }
            }
            _ => {}
        }
        if self.cursor != before.0 {
            self.normalize(&row(self.cursor.row)?);
        }
        self.visible();
        if (self.cursor, self.selection, self.offset) != before {
            self.update_lines(&mut wraps)?;
        }
        Ok(Outcome::Stay)
    }

    pub(crate) fn search_state(&self) -> &SearchState {
        &self.search
    }

    pub(crate) fn paste(&mut self, text: &str) {
        if self.search == SearchState::NoMatch {
            self.search = SearchState::Normal;
        }
        if let SearchState::Prompt(_, prompt) = &mut self.search {
            prompt.extend(text.chars().filter(|c| !c.is_control()));
        }
    }

    pub(crate) fn search_failed(&mut self) {
        self.search = SearchState::Normal;
    }

    pub(crate) fn search_done(
        &mut self,
        matches: Vec<Match>,
        mut wraps: impl FnMut(u32) -> Result<bool, String>,
    ) -> Result<(), String> {
        let SearchState::Searching(direction, text) =
            std::mem::replace(&mut self.search, SearchState::Normal)
        else {
            return Ok(());
        };
        self.last = Some(Found {
            direction,
            text,
            matches: matches.into(),
        });
        self.search_jump(direction == Direction::Forward);
        self.update_lines(&mut wraps)
    }

    fn search_jump(&mut self, forward: bool) {
        let Some(found) = &self.last else { return };
        let matches = &found.matches;
        if matches.is_empty() {
            if !matches!(self.search, SearchState::Searching(..)) {
                self.search = SearchState::NoMatch;
            }
            return;
        }
        let point = (self.cursor.row, self.cursor.col);
        let at = if forward {
            let at = matches.partition_point(|m| (m.start.row, m.start.col) <= point);
            if at == matches.len() { 0 } else { at }
        } else {
            let at = matches.partition_point(|m| (m.start.row, m.start.col) < point);
            if at == 0 { matches.len() - 1 } else { at - 1 }
        };
        if let Some(found) = matches.get(at) {
            self.cursor = found.start;
            self.visible();
        }
    }

    fn update_lines(
        &mut self,
        wraps: &mut impl FnMut(u32) -> Result<bool, String>,
    ) -> Result<(), String> {
        if let Some(Selection::Line { anchor, .. }) = self.selection {
            let mut first = anchor.row.min(self.cursor.row);
            let mut last = anchor.row.max(self.cursor.row);
            while first > 0 && wraps(first - 1)? {
                first -= 1;
            }
            while last + 1 < self.total && wraps(last)? {
                last += 1;
            }
            self.selection = Some(Selection::Line {
                anchor,
                first,
                last,
            });
        }
        Ok(())
    }

    pub(crate) fn mouse(
        &mut self,
        kind: MouseKind,
        position: Cell,
        clicks: u8,
        mut row: impl FnMut(u32) -> Result<Row, String>,
        mut wraps: impl FnMut(u32) -> Result<bool, String>,
    ) -> Result<(), String> {
        let Cell { col, row: y } = position;
        let before = (self.cursor, self.selection, self.offset);
        if matches!(kind, MouseKind::Up(_) | MouseKind::Move) {
            return Ok(());
        }
        if let MouseKind::Scroll { up } = kind {
            self.scroll(if up { -3 } else { 3 });
            if self.cursor != before.0 {
                self.normalize(&row(self.cursor.row)?);
            }
        } else {
            let old = self.cursor;
            self.cursor = Cell {
                col: col.min(self.cols.saturating_sub(1)),
                row: self
                    .offset
                    .saturating_add(y.min(self.rows.saturating_sub(1)))
                    .min(self.total.saturating_sub(1)),
            };
            let text = row(self.cursor.row)?;
            self.normalize(&text);
            match kind {
                MouseKind::Down(_) if clicks >= 3 => {
                    self.selection = Some(Selection::Line {
                        anchor: self.cursor,
                        first: self.cursor.row,
                        last: self.cursor.row,
                    })
                }
                MouseKind::Down(_) if clicks == 2 => {
                    let cells = text.cells();
                    let at = cells
                        .iter()
                        .position(|(col, _, _)| *col == self.cursor.col)
                        .unwrap_or(cells.len());
                    if cells.get(at).is_some() {
                        let first = run_start(&cells, at, false);
                        let last = run_end(&cells, at, false);
                        if let (Some((start, _, _)), Some((end, _, _))) =
                            (cells.get(first), cells.get(last))
                        {
                            self.selection = Some(Selection::Character(Cell {
                                col: *start,
                                row: self.cursor.row,
                            }));
                            self.cursor.col = *end;
                        }
                    } else {
                        self.selection = Some(Selection::Character(self.cursor));
                    }
                }
                MouseKind::Down(_) => self.selection = None,
                MouseKind::Drag(_) if self.selection.is_none() => {
                    self.selection = Some(Selection::Character(old))
                }
                _ => {}
            }
        }
        if (self.cursor, self.selection, self.offset) != before {
            self.update_lines(&mut wraps)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::{Event, Input};
    use std::time::Instant;

    fn mode(cols: u16, rows: u16, total: u32, offset: u32, cursor: Cell) -> Mode {
        Mode {
            cols,
            rows: u32::from(rows),
            total,
            offset,
            cursor,
            selection: None,
            pending: None,
            jump: None,
            search: SearchState::Normal,
            last: None,
        }
    }

    fn feed(copy: &mut Mode, text: &str, rows: &[Row]) {
        let mut events = Vec::new();
        Input::default().feed(text.as_bytes(), Instant::now(), &mut events);
        for event in events {
            if let Event::Key(key) = event {
                copy.feed(
                    &key,
                    |row| Ok(rows[row as usize].clone()),
                    |row| Ok(rows[row as usize].wraps),
                )
                .unwrap();
            }
        }
    }

    #[test]
    fn search_prompt_jumps_wrap_and_no_match() {
        let mut c = mode(20, 2, 10, 8, Cell { row: 9, col: 0 });
        let rows = vec![
            Row {
                text: "needle text".to_owned(),
                wraps: false
            };
            10
        ];
        feed(&mut c, "/éx\x7f", &rows);
        assert_eq!(
            c.search_state(),
            &SearchState::Prompt(Direction::Forward, "é".to_owned())
        );
        c.paste("a\nb\t\u{7f}");
        assert_eq!(
            c.search_state(),
            &SearchState::Prompt(Direction::Forward, "éab".to_owned())
        );
        feed(&mut c, "\x1b[27u", &rows);
        assert_eq!(c.search_state(), &SearchState::Normal);
        feed(&mut c, "/\x7f", &rows);
        assert_eq!(c.search_state(), &SearchState::Normal);
        feed(&mut c, "/\r", &rows);
        assert_eq!(c.search_state(), &SearchState::Normal);
        feed(&mut c, "/needle\r", &rows);
        assert_eq!(
            c.search_state(),
            &SearchState::Searching(Direction::Forward, "needle".to_owned())
        );
        let matches = vec![
            Match {
                start: Cell { row: 1, col: 2 },
                end: Cell { row: 1, col: 7 },
            },
            Match {
                start: Cell { row: 5, col: 0 },
                end: Cell { row: 5, col: 5 },
            },
        ];
        c.search_done(matches.clone(), |_| Ok(false)).unwrap();
        assert_eq!(c.cursor, matches[0].start);
        assert_eq!(c.offset(), 1);
        feed(&mut c, "vn", &rows);
        assert_eq!(c.cursor, matches[1].start);
        assert_eq!(c.range().unwrap().start, matches[0].start);
        assert_eq!(c.range().unwrap().end, matches[1].start);
        feed(&mut c, "n", &rows);
        assert_eq!(c.cursor, matches[0].start);
        feed(&mut c, "N", &rows);
        assert_eq!(c.cursor, matches[1].start);
        feed(&mut c, "?needle\r", &rows);
        c.search_done(matches.clone(), |_| Ok(false)).unwrap();
        assert_eq!(c.cursor, matches[0].start);
        feed(&mut c, "n", &rows);
        assert_eq!(c.cursor, matches[1].start);
        feed(&mut c, "N", &rows);
        assert_eq!(c.cursor, matches[0].start);
        feed(&mut c, "/\r", &rows);
        assert_eq!(
            c.search_state(),
            &SearchState::Searching(Direction::Forward, "needle".to_owned())
        );
        let before = c.cursor;
        c.search_done(Vec::new(), |_| Ok(false)).unwrap();
        assert_eq!(c.cursor, before);
        assert_eq!(c.search_state(), &SearchState::NoMatch);
        feed(&mut c, "v", &rows);
        assert_eq!(c.search_state(), &SearchState::Normal);
        assert_eq!(c.range().unwrap().start, before);
        let mut old = matches;
        old.push(Match {
            start: Cell { row: 8, col: 0 },
            end: Cell { row: 8, col: 2 },
        });
        feed(&mut c, "/old\r", &rows);
        c.search_done(old.clone(), |_| Ok(false)).unwrap();
        assert_eq!(c.cursor, old[1].start);
        feed(&mut c, "?new\r", &rows);
        feed(&mut c, "\x1b[27u", &rows);
        assert_eq!(c.search_state(), &SearchState::Normal);
        feed(&mut c, "n", &rows);
        assert_eq!(c.cursor, old[2].start);
        assert_eq!(c.last.as_ref().unwrap().text, "old");
    }

    #[test]
    fn double_click_after_the_text_selects_blank_and_idle_events_read_no_rows() {
        use ko_pane_wire::frame::MouseButton;
        let mut c = mode(20, 1, 1, 0, Cell { col: 0, row: 0 });
        c.mouse(
            MouseKind::Down(MouseButton::Left),
            Cell { col: 9, row: 0 },
            2,
            |_| {
                Ok(Row {
                    text: "first".to_owned(),
                    wraps: false,
                })
            },
            |_| Ok(false),
        )
        .unwrap();
        assert_eq!(
            c.range(),
            Some(Span {
                start: Cell { col: 9, row: 0 },
                end: Cell { col: 9, row: 0 },
                shape: Shape::Linear
            })
        );
        let before = c.clone();
        c.mouse(
            MouseKind::Up(MouseButton::Left),
            Cell { col: 0, row: 0 },
            1,
            |_| Err("must not read".to_owned()),
            |_| Err("must not read".to_owned()),
        )
        .unwrap();
        assert_eq!(c, before);
    }

    #[test]
    fn copy_find_repeat_screen_page_and_scroll() {
        let rows = vec![
            Row {
                text: "a x x x /".to_owned(),
                wraps: false
            };
            12
        ];
        let mut c = mode(20, 4, 12, 6, Cell { col: 0, row: 6 });
        for (keys, col) in [
            ("fx", 2),
            (";", 4),
            (",", 2),
            ("tx", 3),
            (";", 5),
            (",", 3),
            ("f/", 8),
        ] {
            feed(&mut c, keys, &rows);
            assert_eq!(c.cursor.col, col, "{keys}");
        }
        for (keys, expected) in [("H", 6), ("M", 8), ("L", 9)] {
            feed(&mut c, keys, &rows);
            assert_eq!(c.cursor.row, expected);
        }
        feed(&mut c, "\x15", &rows);
        assert_eq!((c.offset, c.cursor.row), (4, 7));
        feed(&mut c, "\x19", &rows);
        assert_eq!((c.offset, c.cursor.row), (3, 6));
        feed(&mut c, "\x05", &rows);
        assert_eq!((c.offset, c.cursor.row), (4, 6));
        feed(&mut c, "G\x1b[5~", &rows);
        assert_eq!((c.offset, c.cursor.row), (4, 7));
        feed(&mut c, "\x06", &rows);
        assert_eq!((c.offset, c.cursor.row), (8, 11));
    }

    #[test]
    fn copy_logical_lines_wide_cells_and_mouse() {
        use ko_pane_wire::frame::MouseButton;
        let rows = vec![
            Row {
                text: "a界b".to_owned(),
                wraps: true,
            },
            Row {
                text: "tail word".to_owned(),
                wraps: false,
            },
            Row {
                text: "final".to_owned(),
                wraps: false,
            },
        ];
        let mut c = mode(12, 2, 3, 0, Cell { col: 0, row: 0 });
        feed(&mut c, "ll", &rows);
        assert_eq!(c.cursor.col, 3);
        feed(&mut c, "h", &rows);
        assert_eq!(c.cursor.col, 1);
        feed(&mut c, "jV", &rows);
        assert_eq!(
            c.range(),
            Some(Span {
                start: Cell { col: 0, row: 0 },
                end: Cell { col: 11, row: 1 },
                shape: Shape::Linear
            })
        );
        feed(&mut c, "\x1b[27u$w", &rows);
        assert_eq!(c.cursor, Cell { col: 0, row: 2 });
        feed(&mut c, "b", &rows);
        assert_eq!(c.cursor, Cell { col: 5, row: 1 });
        feed(&mut c, "g", &rows);
        c.mouse(
            MouseKind::Down(MouseButton::Left),
            Cell { col: 6, row: 1 },
            2,
            |row| Ok(rows[row as usize].clone()),
            |row| Ok(rows[row as usize].wraps),
        )
        .unwrap();
        assert_eq!(
            c.range(),
            Some(Span {
                start: Cell { col: 5, row: 1 },
                end: Cell { col: 8, row: 1 },
                shape: Shape::Linear
            })
        );
        c.mouse(
            MouseKind::Down(MouseButton::Left),
            Cell { col: 1, row: 0 },
            1,
            |row| Ok(rows[row as usize].clone()),
            |row| Ok(rows[row as usize].wraps),
        )
        .unwrap();
        c.mouse(
            MouseKind::Drag(MouseButton::Left),
            Cell { col: 3, row: 1 },
            1,
            |row| Ok(rows[row as usize].clone()),
            |row| Ok(rows[row as usize].wraps),
        )
        .unwrap();
        assert_eq!(
            c.range(),
            Some(Span {
                start: Cell { col: 1, row: 0 },
                end: Cell { col: 3, row: 1 },
                shape: Shape::Linear
            })
        );
    }

    #[test]
    fn copy_words_lines_rectangles_and_other_end() {
        let mut c = mode(20, 4, 12, 8, Cell { col: 0, row: 9 });
        let rows = vec![
            Row {
                text: "one two three".to_owned(),
                wraps: false
            };
            12
        ];
        feed(&mut c, "wwb", &rows);
        assert_eq!(c.cursor.col, 4);
        feed(&mut c, "V", &rows);
        assert_eq!(
            c.range(),
            Some(Span {
                start: Cell { col: 0, row: 9 },
                end: Cell { col: 19, row: 9 },
                shape: Shape::Linear
            })
        );
        feed(&mut c, "\x16lj", &rows);
        assert_eq!(
            c.range(),
            Some(Span {
                start: Cell { col: 4, row: 9 },
                end: Cell { col: 5, row: 10 },
                shape: Shape::Rectangle
            })
        );
        feed(&mut c, "o", &rows);
        assert_eq!(c.cursor, Cell { col: 4, row: 9 });
        assert_eq!(
            c.range(),
            Some(Span {
                start: Cell { col: 4, row: 9 },
                end: Cell { col: 5, row: 10 },
                shape: Shape::Rectangle
            })
        );
        feed(&mut c, "g", &rows);
        assert_eq!((c.offset, c.history()), (0, 8));
        feed(&mut c, "G", &rows);
        assert_eq!((c.offset, c.history()), (8, 8));
    }
}

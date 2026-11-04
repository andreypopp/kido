use std::time::{Duration, Instant};

use ko_client::edit::Edge;
use ko_server::ids::PaneId;
use ko_server::protocol::{Axis, Direction, Over};

use crate::copy::Entry;
use crate::input::{KeyEvent, Kind, Name};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Rename {
    Session,
    Window,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kill {
    Window,
    Pane,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum State {
    Normal,
    Prefix,
    Repeat { until: Instant },
    Help,
    Resize,
    Rename { of: Rename, text: String },
    Confirm(Kill),
    Chooser(PaneId),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Action {
    Detach,
    Redraw,
    ToggleSidebar,
    Pager,
    EnterCopy(Entry),
    CopyKey(KeyEvent),
    LeaveCopy,
    PasteBuffer,
    NewWindow,
    Switch(Over, Direction),
    LastSession,
    LastWindow,
    Pane(PaneCommand),
    Window(u32),
    Chooser,
    Choose(Direction),
    Select(PaneId),
    Rename(Rename, String),
    Kill(Kill),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Step {
    Pane(KeyEvent),
    Act(Action),
    Swallow,
}

pub(crate) const HELP: [&str; 31] = [
    "C-a C-a  send C-a to the pane",
    "d        detach",
    "r        redraw",
    "?        this help",
    "( )      previous / next session",
    "L        last session",
    "Tab      last window",
    "n p      next / previous window",
    "% / \"    split left/right / top/bottom",
    "z        toggle zoom",
    "*        toggle float",
    "!        break pane into a new window",
    "R        resize mode",
    "o ;      next / last pane",
    "arrows   select neighbour (repeatable)",
    "hjkl C-hjkl select neighbour (repeatable)",
    "C-arrows resize by 1 (repeatable)",
    "M-arrows resize by 5 (repeatable)",
    "{ } E    swap previous / next; equalize",
    "0-9      window by number",
    "s w      choose from the sidebar list",
    "C-s      show or hide the sidebar",
    "e        scrollback in the pager",
    "c        new window",
    "$        rename session",
    ",        rename window",
    "&        kill window",
    "x        kill pane",
    "[        copy mode (vi keys; q leaves)",
    "PageUp   copy mode, one page up",
    "]        paste the copy buffer",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PaneSelect {
    Next,
    Last,
    Edge(Edge),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Amount {
    One,
    Five,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PaneEdit {
    Split(Axis),
    Zoom,
    Resize(Edge, Amount),
    Swap(Direction),
    Equalize,
    Float,
    Break,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PaneCommand {
    Select(PaneSelect),
    Edit(PaneEdit),
}

fn repeatable(event: &KeyEvent) -> Option<PaneCommand> {
    let arrow = match event.name {
        Name::Left => Some(Edge::Left),
        Name::Down => Some(Edge::Bottom),
        Name::Up => Some(Edge::Top),
        Name::Right => Some(Edge::Right),
        _ => None,
    };
    if let Some(edge) = arrow {
        return if event.mods.only_ctrl() {
            Some(PaneCommand::Edit(PaneEdit::Resize(edge, Amount::One)))
        } else if event.mods.only_alt() {
            Some(PaneCommand::Edit(PaneEdit::Resize(edge, Amount::Five)))
        } else if event.mods == Default::default() {
            Some(PaneCommand::Select(PaneSelect::Edge(edge)))
        } else {
            None
        };
    }
    let edge = match event.ctrl().or_else(|| event.character())? {
        'h' => Edge::Left,
        'j' => Edge::Bottom,
        'k' => Edge::Top,
        'l' => Edge::Right,
        _ => return None,
    };
    Some(PaneCommand::Select(PaneSelect::Edge(edge)))
}

fn pane_command(event: &KeyEvent) -> Option<PaneCommand> {
    Some(match event.character()? {
        '%' => PaneCommand::Edit(PaneEdit::Split(Axis::Horizontal)),
        '"' => PaneCommand::Edit(PaneEdit::Split(Axis::Vertical)),
        'z' => PaneCommand::Edit(PaneEdit::Zoom),
        '*' => PaneCommand::Edit(PaneEdit::Float),
        '!' => PaneCommand::Edit(PaneEdit::Break),
        'o' => PaneCommand::Select(PaneSelect::Next),
        ';' => PaneCommand::Select(PaneSelect::Last),
        '{' => PaneCommand::Edit(PaneEdit::Swap(Direction::Previous)),
        '}' => PaneCommand::Edit(PaneEdit::Swap(Direction::Next)),
        'E' => PaneCommand::Edit(PaneEdit::Equalize),
        _ => return None,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Context {
    Live,
    Dead,
    Copying,
}
#[derive(Debug)]
pub(crate) struct Keys {
    state: State,
    consumed: Vec<Name>,
}

impl Keys {
    pub(crate) fn new() -> Keys {
        Keys {
            state: State::Normal,
            consumed: Vec::new(),
        }
    }

    pub(crate) fn state(&self) -> &State {
        &self.state
    }

    pub(crate) fn end(&mut self) {
        self.state = State::Normal;
    }

    pub(crate) fn choose(&mut self, pane: PaneId) {
        self.state = State::Chooser(pane);
    }

    pub(crate) fn paste(&mut self, text: String) -> Option<String> {
        match &mut self.state {
            State::Normal => Some(text),
            State::Rename { text: typed, .. } => {
                typed.extend(text.chars().filter(|c| !c.is_control()));
                None
            }
            State::Resize => None,
            _ => {
                self.state = State::Normal;
                None
            }
        }
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        match self.state {
            State::Repeat { until } => Some(until),
            _ => None,
        }
    }

    pub(crate) fn expire(&mut self, now: Instant) {
        if self.deadline().is_some_and(|until| now >= until) {
            self.end();
        }
    }

    pub(crate) fn feed(&mut self, event: &KeyEvent, context: Context, now: Instant) -> Step {
        self.expire(now);
        let dead = context == Context::Dead;
        let consumed = self.consumed.iter().position(|name| *name == event.name);
        if event.kind == Kind::Release {
            return match consumed {
                Some(at) => {
                    self.consumed.remove(at);
                    Step::Swallow
                }
                None if self.state == State::Normal && context != Context::Copying => {
                    Step::Pane(event.clone())
                }
                None => Step::Swallow,
            };
        }
        let step = match std::mem::replace(&mut self.state, State::Normal) {
            State::Normal if context == Context::Copying => {
                if event.ctrl() == Some('a') {
                    self.state = State::Prefix;
                    Step::Act(Action::LeaveCopy)
                } else {
                    Step::Act(Action::CopyKey(event.clone()))
                }
            }
            State::Normal => self.normal(event, dead),
            State::Prefix => self.prefixed(event, now),
            State::Repeat { .. } => match repeatable(event) {
                Some(command) => self.repeat(command, now),
                None => self.normal(event, dead),
            },
            State::Help => Step::Swallow,
            State::Resize => self.resize(event),
            State::Rename { of, text } => self.renaming(of, text, event),
            State::Confirm(kill) => match event.character() {
                Some('y') => Step::Act(Action::Kill(kill)),
                _ => Step::Swallow,
            },
            State::Chooser(pane) => self.choosing(pane, event, dead),
        };
        match (&step, consumed) {
            (Step::Pane(_), Some(at)) => {
                self.consumed.remove(at);
            }
            (Step::Pane(_), None) | (_, Some(_)) => {}
            (_, None) => self.consumed.push(event.name),
        }
        step
    }

    fn normal(&mut self, event: &KeyEvent, dead: bool) -> Step {
        match event.ctrl() {
            Some('a') => {
                self.state = State::Prefix;
                Step::Swallow
            }
            Some('d') if dead => Step::Act(Action::Kill(Kill::Pane)),
            _ => Step::Pane(event.clone()),
        }
    }

    fn repeat(&mut self, command: PaneCommand, now: Instant) -> Step {
        self.state = State::Repeat {
            until: now + Duration::from_millis(500),
        };
        Step::Act(Action::Pane(command))
    }

    fn prefixed(&mut self, event: &KeyEvent, now: Instant) -> Step {
        if event.name == Name::Tab && event.mods == Default::default() {
            return Step::Act(Action::LastWindow);
        }
        let legacy = match event.name {
            Name::Backspace => Some(Edge::Left),
            Name::Enter => Some(Edge::Bottom),
            _ => None,
        };
        if let Some(edge) = legacy {
            return self.repeat(PaneCommand::Select(PaneSelect::Edge(edge)), now);
        }
        if let Some(command) = repeatable(event) {
            return self.repeat(command, now);
        }
        if let Some(command) = pane_command(event) {
            return Step::Act(Action::Pane(command));
        }
        match event.ctrl() {
            Some('a') => return Step::Pane(event.clone()),
            Some('s') => return Step::Act(Action::ToggleSidebar),
            _ => {}
        }
        if event.name == Name::PageUp {
            return Step::Act(Action::EnterCopy(Entry::PageUp));
        }
        let Some(key) = event.character() else {
            return Step::Swallow;
        };
        let act = Step::Act;
        if let Some(digit) = key.to_digit(10) {
            return act(Action::Window(digit));
        }
        match key {
            '[' => act(Action::EnterCopy(Entry::Here)),
            ']' => act(Action::PasteBuffer),
            'd' => act(Action::Detach),
            'r' => act(Action::Redraw),
            'e' => act(Action::Pager),
            'c' => act(Action::NewWindow),
            '(' => act(Action::Switch(Over::Session, Direction::Previous)),
            ')' => act(Action::Switch(Over::Session, Direction::Next)),
            'p' => act(Action::Switch(Over::Window, Direction::Previous)),
            'n' => act(Action::Switch(Over::Window, Direction::Next)),
            'L' => act(Action::LastSession),
            's' | 'w' => act(Action::Chooser),
            'R' => self.enter(State::Resize),
            '?' => self.enter(State::Help),
            '$' => self.enter(State::Rename {
                of: Rename::Session,
                text: String::new(),
            }),
            ',' => self.enter(State::Rename {
                of: Rename::Window,
                text: String::new(),
            }),
            '&' => self.enter(State::Confirm(Kill::Window)),
            'x' => self.enter(State::Confirm(Kill::Pane)),
            _ => Step::Swallow,
        }
    }

    fn enter(&mut self, state: State) -> Step {
        self.state = state;
        Step::Swallow
    }

    fn resize(&mut self, event: &KeyEvent) -> Step {
        if event.ctrl() == Some('a') {
            return self.enter(State::Prefix);
        }
        if matches!(event.name, Name::Enter | Name::Escape) || event.character() == Some('q') {
            return Step::Swallow;
        }
        self.state = State::Resize;
        let character = event.character();
        let command = match character {
            Some('=') => PaneEdit::Equalize,
            Some('z') => PaneEdit::Zoom,
            _ => {
                let edge = match (event.name, character) {
                    (Name::Left, _) | (_, Some('h' | 'H')) => Edge::Left,
                    (Name::Down, _) | (_, Some('j' | 'J')) => Edge::Bottom,
                    (Name::Up, _) | (_, Some('k' | 'K')) => Edge::Top,
                    (Name::Right, _) | (_, Some('l' | 'L')) => Edge::Right,
                    _ => return Step::Swallow,
                };
                if character.is_none() && !event.mods.plain() {
                    return Step::Swallow;
                }
                let amount = if event.mods.shift() || character.is_some_and(|c| c.is_uppercase()) {
                    Amount::Five
                } else {
                    Amount::One
                };
                PaneEdit::Resize(edge, amount)
            }
        };
        Step::Act(Action::Pane(PaneCommand::Edit(command)))
    }

    fn renaming(&mut self, of: Rename, mut text: String, event: &KeyEvent) -> Step {
        match (event.name, event.character()) {
            (Name::Enter, _) if text.is_empty() => return Step::Swallow,
            (Name::Enter, _) => return Step::Act(Action::Rename(of, text)),
            (Name::Escape, _) => return Step::Swallow,
            (Name::Backspace, _) => {
                text.pop();
            }
            (_, Some(typed)) => text.push(typed),
            _ => {}
        }
        self.enter(State::Rename { of, text })
    }

    fn choosing(&mut self, pane: PaneId, event: &KeyEvent, dead: bool) -> Step {
        match event.name {
            Name::Up | Name::Down => {
                self.state = State::Chooser(pane);
                let direction = if event.name == Name::Up {
                    Direction::Previous
                } else {
                    Direction::Next
                };
                Step::Act(Action::Choose(direction))
            }
            Name::Enter => Step::Act(Action::Select(pane)),
            Name::Escape => Step::Swallow,
            _ => self.normal(event, dead),
        }
    }
}
#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;
    use crate::input::{Event, Input};

    fn events(text: &str) -> Vec<KeyEvent> {
        let mut out = Vec::new();
        Input::default().feed(text.as_bytes(), Instant::now(), &mut out);
        out.into_iter()
            .filter_map(|event| match event {
                Event::Key(key) => Some(key),
                _ => None,
            })
            .collect()
    }

    fn steps(keys: &mut Keys, text: &str) -> Vec<Step> {
        events(text)
            .iter()
            .map(|event| keys.feed(event, Context::Live, Instant::now()))
            .collect()
    }

    fn act(action: Action) -> Step {
        Step::Act(action)
    }

    fn swallowed(count: usize) -> Vec<Step> {
        vec![Step::Swallow; count]
    }

    fn pane(number: u64) -> PaneId {
        format!("pane_{number}").parse().unwrap()
    }

    #[test]
    fn resize_mode_keeps_its_table_until_explicit_exit() {
        let mut keys = Keys::new();
        let resize = |edge, amount| {
            act(Action::Pane(PaneCommand::Edit(PaneEdit::Resize(
                edge, amount,
            ))))
        };
        assert_eq!(
            steps(&mut keys, "\x01Rhh\r"),
            [
                Step::Swallow,
                Step::Swallow,
                resize(Edge::Left, Amount::One),
                resize(Edge::Left, Amount::One),
                Step::Swallow
            ]
        );
        assert_eq!(keys.state(), &State::Normal);
        steps(&mut keys, "\x01R");
        for (text, expected) in [
            ("H", resize(Edge::Left, Amount::Five)),
            ("j", resize(Edge::Bottom, Amount::One)),
            ("K", resize(Edge::Top, Amount::Five)),
            ("l", resize(Edge::Right, Amount::One)),
            ("\x1b[A", resize(Edge::Top, Amount::One)),
            ("\x1b[1;65A", resize(Edge::Top, Amount::One)),
            ("\x1b[1;66A", resize(Edge::Top, Amount::Five)),
            ("\x1b[1;2C", resize(Edge::Right, Amount::Five)),
            (
                "=",
                act(Action::Pane(PaneCommand::Edit(PaneEdit::Equalize))),
            ),
            ("z", act(Action::Pane(PaneCommand::Edit(PaneEdit::Zoom)))),
            ("x", Step::Swallow),
            ("\x1b[1;5D", Step::Swallow),
            ("\x1b[1;7D", Step::Swallow),
        ] {
            assert_eq!(steps(&mut keys, text), [expected]);
            assert_eq!(keys.state(), &State::Resize);
        }
        let mut release = events("h").remove(0);
        release.kind = Kind::Release;
        assert_eq!(
            keys.feed(&release, Context::Live, Instant::now()),
            Step::Swallow
        );
        assert_eq!(keys.state(), &State::Resize);
        assert_eq!(steps(&mut keys, "\x01"), [Step::Swallow]);
        assert_eq!(keys.state(), &State::Prefix);
        assert_eq!(steps(&mut keys, "d"), [act(Action::Detach)]);
        for exit in ["q", "\x1b[27u"] {
            steps(&mut keys, "\x01R");
            assert_eq!(steps(&mut keys, exit), [Step::Swallow]);
            assert_eq!(keys.state(), &State::Normal);
        }
    }

    #[test]
    fn repeats_reset_the_deadline_and_other_keys_return_to_normal() {
        let now = Instant::now();
        let mut keys = Keys::new();
        let prefix = events("\x01").remove(0);
        let up = events("\x1b[A").remove(0);
        keys.feed(&prefix, Context::Live, now);
        for ms in [0, 400, 800] {
            let at = now + Duration::from_millis(ms);
            assert_eq!(
                keys.feed(&up, Context::Live, at),
                act(Action::Pane(PaneCommand::Select(PaneSelect::Edge(
                    Edge::Top
                ))))
            );
            assert_eq!(keys.deadline(), Some(at + Duration::from_millis(500)));
        }
        assert_eq!(
            keys.feed(&up, Context::Live, now + Duration::from_millis(1300)),
            Step::Pane(up.clone())
        );
        assert_eq!(keys.deadline(), None);
        keys.feed(&prefix, Context::Live, now);
        keys.feed(&up, Context::Live, now);
        let x = events("x").remove(0);
        assert_eq!(keys.feed(&x, Context::Live, now), Step::Pane(x));
        assert_eq!(keys.state(), &State::Normal);
        keys.feed(&prefix, Context::Live, now);
        keys.feed(&up, Context::Live, now);
        keys.feed(&prefix, Context::Live, now);
        assert_eq!(keys.state(), &State::Prefix);
        keys.feed(&up, Context::Live, now);
        keys.expire(now + Duration::from_millis(500));
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn legacy_movement_aliases_only_act_after_the_prefix() {
        for (text, edge) in [("\x08", Edge::Left), ("\r", Edge::Bottom)] {
            let mut keys = Keys::new();
            assert_eq!(
                steps(&mut keys, &format!("\x01{text}"))[1],
                act(Action::Pane(PaneCommand::Select(PaneSelect::Edge(edge))))
            );
            let event = events(text).remove(0);
            assert_eq!(
                keys.feed(&event, Context::Live, Instant::now()),
                Step::Pane(event)
            );
            assert_eq!(keys.state(), &State::Normal);
        }
    }

    #[test]
    fn pane_movement_and_resize_bindings_need_a_prefix() {
        for (text, command) in [
            ("h", PaneCommand::Select(PaneSelect::Edge(Edge::Left))),
            ("j", PaneCommand::Select(PaneSelect::Edge(Edge::Bottom))),
            ("k", PaneCommand::Select(PaneSelect::Edge(Edge::Top))),
            ("l", PaneCommand::Select(PaneSelect::Edge(Edge::Right))),
            ("\x08", PaneCommand::Select(PaneSelect::Edge(Edge::Left))),
            ("\x0a", PaneCommand::Select(PaneSelect::Edge(Edge::Bottom))),
            ("\x0b", PaneCommand::Select(PaneSelect::Edge(Edge::Top))),
            ("\x0c", PaneCommand::Select(PaneSelect::Edge(Edge::Right))),
            ("\x1b[D", PaneCommand::Select(PaneSelect::Edge(Edge::Left))),
            (
                "\x1b[B",
                PaneCommand::Select(PaneSelect::Edge(Edge::Bottom)),
            ),
            ("\x1b[A", PaneCommand::Select(PaneSelect::Edge(Edge::Top))),
            ("\x1b[C", PaneCommand::Select(PaneSelect::Edge(Edge::Right))),
            (
                "\x1b[1;5D",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Left, Amount::One)),
            ),
            (
                "\x1b[1;5B",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Bottom, Amount::One)),
            ),
            (
                "\x1b[1;5A",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Top, Amount::One)),
            ),
            (
                "\x1b[1;5C",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Right, Amount::One)),
            ),
            (
                "\x1b[1;3D",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Left, Amount::Five)),
            ),
            (
                "\x1b[1;3B",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Bottom, Amount::Five)),
            ),
            (
                "\x1b[1;3A",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Top, Amount::Five)),
            ),
            (
                "\x1b[1;3C",
                PaneCommand::Edit(PaneEdit::Resize(Edge::Right, Amount::Five)),
            ),
        ] {
            let mut keys = Keys::new();
            assert!(
                matches!(steps(&mut keys, text)[0], Step::Pane(_)),
                "{text:?}"
            );
            assert_eq!(
                steps(&mut keys, &format!("\x01{text}"))[1],
                act(Action::Pane(command)),
                "{text:?}"
            );
        }
    }

    #[test]
    fn copy_entry_clears_repeat_and_copy_and_resize_leave_through_prefix() {
        let mut keys = Keys::new();
        steps(&mut keys, "\x01h");
        assert!(keys.deadline().is_some());
        assert_eq!(
            steps(&mut keys, "\x01["),
            [Step::Swallow, act(Action::EnterCopy(Entry::Here))]
        );
        assert_eq!(keys.state(), &State::Normal);
        assert_eq!(keys.deadline(), None);
        let h = events("h").remove(0);
        let prefix = events("\x01").remove(0);
        assert_eq!(
            keys.feed(&h, Context::Copying, Instant::now()),
            act(Action::CopyKey(h.clone()))
        );
        assert_eq!(
            keys.feed(&prefix, Context::Copying, Instant::now()),
            act(Action::LeaveCopy)
        );
        assert_eq!(keys.state(), &State::Prefix);
        assert_eq!(steps(&mut keys, "R"), [Step::Swallow]);
        assert_eq!(keys.state(), &State::Resize);
        assert_eq!(
            steps(&mut keys, "\x01\x1b[5~"),
            [Step::Swallow, act(Action::EnterCopy(Entry::PageUp))]
        );
        assert_eq!(keys.state(), &State::Normal);
        assert_eq!(keys.deadline(), None);
        assert_eq!(
            keys.feed(&h, Context::Copying, Instant::now()),
            act(Action::CopyKey(h))
        );
    }

    #[test]
    fn ctrl_a_inside_copy_leaves_and_d_detaches() {
        let mut keys = Keys::new();
        assert_eq!(
            keys.feed(&events("\x01").remove(0), Context::Copying, Instant::now()),
            act(Action::LeaveCopy)
        );
        assert_eq!(steps(&mut keys, "d"), [act(Action::Detach)]);
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn a_plain_key_goes_to_the_pane_and_the_prefix_is_a_pending_mode() {
        let mut keys = Keys::new();
        let x = events("x").remove(0);
        assert_eq!(keys.feed(&x, Context::Live, Instant::now()), Step::Pane(x));
        assert_eq!(steps(&mut keys, "\x01"), [Step::Swallow]);
        assert_eq!(keys.state(), &State::Prefix);
    }

    #[test]
    fn the_prefix_twice_sends_it_to_the_pane_and_a_bound_key_acts() {
        for prefix in ["\x01", "\x1b[97;5u"] {
            let mut keys = Keys::new();
            let text = format!("{prefix}{prefix}{prefix}d");
            let shown = steps(&mut keys, &text);
            let sent = events(prefix).remove(0);
            assert_eq!(
                shown,
                [
                    Step::Swallow,
                    Step::Pane(sent),
                    Step::Swallow,
                    act(Action::Detach)
                ],
                "{prefix:?}"
            );
            assert_eq!(keys.state(), &State::Normal);
        }
    }

    #[test]
    fn legacy_and_csi_u_prefixes_give_the_same_actions() {
        let run = |prefix: &str| {
            let mut keys = Keys::new();
            steps(&mut keys, &format!("{prefix}c{prefix}\x13{prefix}("))
        };
        assert_eq!(
            run("\x01"),
            [
                Step::Swallow,
                act(Action::NewWindow),
                Step::Swallow,
                act(Action::ToggleSidebar),
                Step::Swallow,
                act(Action::Switch(Over::Session, Direction::Previous)),
            ]
        );
        assert_eq!(run("\x01"), run("\x1b[97;5u"));
    }

    #[test]
    fn an_unbound_key_after_the_prefix_is_swallowed_and_ends_it() {
        let mut keys = Keys::new();
        assert_eq!(steps(&mut keys, "\x01t\x01\x1b[H"), swallowed(4));
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn every_binding_of_the_prefix_table() {
        let table = [
            ("*", act(Action::Pane(PaneCommand::Edit(PaneEdit::Float)))),
            ("!", act(Action::Pane(PaneCommand::Edit(PaneEdit::Break)))),
            ("d", act(Action::Detach)),
            ("r", act(Action::Redraw)),
            ("e", act(Action::Pager)),
            ("c", act(Action::NewWindow)),
            (")", act(Action::Switch(Over::Session, Direction::Next))),
            ("n", act(Action::Switch(Over::Window, Direction::Next))),
            ("p", act(Action::Switch(Over::Window, Direction::Previous))),
            ("L", act(Action::LastSession)),
            ("\t", act(Action::LastWindow)),
            (
                "l",
                act(Action::Pane(PaneCommand::Select(PaneSelect::Edge(
                    Edge::Right,
                )))),
            ),
            (
                "%",
                act(Action::Pane(PaneCommand::Edit(PaneEdit::Split(
                    Axis::Horizontal,
                )))),
            ),
            (
                "\"",
                act(Action::Pane(PaneCommand::Edit(PaneEdit::Split(
                    Axis::Vertical,
                )))),
            ),
            ("z", act(Action::Pane(PaneCommand::Edit(PaneEdit::Zoom)))),
            (
                "o",
                act(Action::Pane(PaneCommand::Select(PaneSelect::Next))),
            ),
            (
                ";",
                act(Action::Pane(PaneCommand::Select(PaneSelect::Last))),
            ),
            (
                "{",
                act(Action::Pane(PaneCommand::Edit(PaneEdit::Swap(
                    Direction::Previous,
                )))),
            ),
            (
                "}",
                act(Action::Pane(PaneCommand::Edit(PaneEdit::Swap(
                    Direction::Next,
                )))),
            ),
            (
                "E",
                act(Action::Pane(PaneCommand::Edit(PaneEdit::Equalize))),
            ),
            ("0", act(Action::Window(0))),
            ("9", act(Action::Window(9))),
            ("s", act(Action::Chooser)),
            ("w", act(Action::Chooser)),
            ("\x13", act(Action::ToggleSidebar)),
        ];
        for (key, step) in table {
            let mut keys = Keys::new();
            assert_eq!(steps(&mut keys, &format!("\x01{key}"))[1], step, "{key:?}");
        }
    }

    #[test]
    fn a_release_of_a_consumed_press_is_swallowed_and_a_pane_release_is_not() {
        let mut keys = Keys::new();
        let shown = steps(
            &mut keys,
            "\x1b[97;5u\x1b[97;5:3u\x1b[100;1u\x1b[100;1:3u\x1b[120;1:3u",
        );
        assert_eq!(
            shown[..4],
            [
                Step::Swallow,
                Step::Swallow,
                act(Action::Detach),
                Step::Swallow
            ]
        );
        assert!(matches!(&shown[4], Step::Pane(event) if event.kind == Kind::Release));
    }

    #[test]
    fn overlapping_releases_of_two_consumed_presses_are_both_swallowed() {
        let mut keys = Keys::new();
        assert_eq!(
            steps(
                &mut keys,
                "\x1b[97;5:1u\x1b[99;1:1u\x1b[97;5:3u\x1b[99;1:3u"
            ),
            [
                Step::Swallow,
                act(Action::NewWindow),
                Step::Swallow,
                Step::Swallow
            ]
        );
    }

    #[test]
    fn the_release_of_a_forwarded_press_reaches_the_pane() {
        let mut keys = Keys::new();
        let shown = steps(&mut keys, "\x1b[120;1:1u\x1b[120;1:3u");
        assert!(matches!(&shown[0], Step::Pane(event) if event.kind == Kind::Press));
        assert!(matches!(&shown[1], Step::Pane(event) if event.kind == Kind::Release));
    }

    #[test]
    fn a_repeat_counts_as_a_press() {
        let mut keys = Keys::new();
        assert_eq!(
            steps(&mut keys, "\x01\x1b[100;1:2u"),
            [Step::Swallow, act(Action::Detach)]
        );
    }

    #[test]
    fn ctrl_d_kills_only_a_dead_pane() {
        let mut keys = Keys::new();
        let ctrl_d = events("\x04").remove(0);
        assert_eq!(
            keys.feed(&ctrl_d, Context::Dead, Instant::now()),
            act(Action::Kill(Kill::Pane))
        );
        assert!(matches!(steps(&mut keys, "\x1b[100;5u")[0], Step::Pane(_)));
    }

    #[test]
    fn a_rename_prompt_collects_text_deletes_and_acts_on_enter() {
        let mut keys = Keys::new();
        let shown = steps(&mut keys, "\x01$ab\x7fCd\r");
        assert_eq!(shown[..7], swallowed(7));
        assert_eq!(
            shown[7],
            act(Action::Rename(Rename::Session, "aCd".to_owned()))
        );
        assert_eq!(keys.state(), &State::Normal);
        assert_eq!(steps(&mut keys, "\x01$\r"), swallowed(3));
        steps(&mut keys, "\x01,x");
        assert_eq!(
            keys.state(),
            &State::Rename {
                of: Rename::Window,
                text: "x".to_owned()
            }
        );
    }

    #[test]
    fn escape_cancels_a_prompt_and_nothing_reaches_the_pane() {
        let mut keys = Keys::new();
        assert_eq!(steps(&mut keys, "\x01,ab\x1b[27u"), swallowed(5));
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn only_y_confirms_a_kill_and_any_other_key_cancels() {
        let mut keys = Keys::new();
        assert_eq!(
            steps(&mut keys, "\x01&y")[2],
            act(Action::Kill(Kill::Window))
        );
        assert_eq!(steps(&mut keys, "\x01xy")[2], act(Action::Kill(Kill::Pane)));
        assert_eq!(steps(&mut keys, "\x01&n")[2], Step::Swallow);
        assert_eq!(keys.state(), &State::Normal);
        assert_eq!(steps(&mut keys, "\x01x\x1b[27u")[2], Step::Swallow);
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn the_chooser_asks_for_steps_selects_the_chosen_pane_and_escape_leaves() {
        let mut keys = Keys::new();
        assert_eq!(steps(&mut keys, "\x01s")[1], act(Action::Chooser));
        keys.choose(pane(2));
        assert_eq!(
            steps(&mut keys, "\x1b[B\x1b[A"),
            [
                act(Action::Choose(Direction::Next)),
                act(Action::Choose(Direction::Previous))
            ]
        );
        assert_eq!(keys.state(), &State::Chooser(pane(2)));
        keys.choose(pane(3));
        assert_eq!(steps(&mut keys, "\r"), [act(Action::Select(pane(3)))]);
        assert_eq!(keys.state(), &State::Normal);
        keys.choose(pane(3));
        steps(&mut keys, "\x1b[27u");
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn another_key_leaves_the_chooser_and_is_handled_as_normal() {
        let mut keys = Keys::new();
        keys.choose(pane(1));
        let x = events("x").remove(0);
        assert_eq!(keys.feed(&x, Context::Live, Instant::now()), Step::Pane(x));
        assert_eq!(keys.state(), &State::Normal);
        keys.choose(pane(1));
        assert_eq!(steps(&mut keys, "\x01"), [Step::Swallow]);
        assert_eq!(keys.state(), &State::Prefix);
    }

    #[test]
    fn any_key_closes_the_help_and_an_outside_event_ends_a_mode() {
        let mut keys = Keys::new();
        assert_eq!(steps(&mut keys, "\x01?")[1], Step::Swallow);
        assert_eq!(keys.state(), &State::Help);
        assert_eq!(steps(&mut keys, "x"), [Step::Swallow]);
        assert_eq!(keys.state(), &State::Normal);
        steps(&mut keys, "\x01$");
        keys.end();
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn a_paste_goes_to_the_pane_or_the_prompt_and_is_dropped_in_any_other_state() {
        let mut keys = Keys::new();
        assert_eq!(keys.paste("a\nb".to_owned()), Some("a\nb".to_owned()));
        steps(&mut keys, "\x01,x");
        assert_eq!(keys.paste("y\nz\x1b".to_owned()), None);
        assert_eq!(
            keys.state(),
            &State::Rename {
                of: Rename::Window,
                text: "xyz".to_owned()
            }
        );
        for opener in ["\x01", "\x01?", "\x01x"] {
            keys.end();
            steps(&mut keys, opener);
            assert_eq!(keys.paste("p".to_owned()), None, "{opener:?}");
            assert_eq!(keys.state(), &State::Normal, "{opener:?}");
        }
        keys.choose(pane(1));
        assert_eq!(keys.paste("p".to_owned()), None);
        assert_eq!(keys.state(), &State::Normal);
    }
}

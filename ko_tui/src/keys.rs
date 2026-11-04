use ko_server::ids::PaneId;
use ko_server::protocol::{Direction, Over};

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
    Help,
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
    NewWindow,
    Switch(Over, Direction),
    LastSession,
    LastWindow,
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

pub(crate) const HELP: [&str; 17] = [
    "C-a C-a  send C-a to the pane",
    "d        detach",
    "r        redraw",
    "?        this help",
    "( )      previous / next session",
    "L        last session",
    "n p      next / previous window",
    "l        last window",
    "0-9      window by number",
    "s w      choose from the sidebar list",
    "C-s      show or hide the sidebar",
    "e        scrollback in the pager",
    "c        new window",
    "$        rename session",
    ",        rename window",
    "&        kill window",
    "x        kill pane",
];

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
        match std::mem::replace(&mut self.state, State::Normal) {
            State::Normal => Some(text),
            State::Rename {
                of,
                text: mut typed,
            } => {
                typed.extend(text.chars().filter(|c| !c.is_control()));
                self.state = State::Rename { of, text: typed };
                None
            }
            _ => None,
        }
    }

    pub(crate) fn feed(&mut self, event: &KeyEvent, dead: bool) -> Step {
        let consumed = self.consumed.iter().position(|name| *name == event.name);
        if event.kind == Kind::Release {
            return match consumed {
                Some(at) => {
                    self.consumed.remove(at);
                    Step::Swallow
                }
                None if self.state == State::Normal => Step::Pane(event.clone()),
                None => Step::Swallow,
            };
        }
        let step = match std::mem::replace(&mut self.state, State::Normal) {
            State::Normal => self.normal(event, dead),
            State::Prefix => self.prefixed(event),
            State::Help => Step::Swallow,
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

    fn prefixed(&mut self, event: &KeyEvent) -> Step {
        match event.ctrl() {
            Some('a') => return Step::Pane(event.clone()),
            Some('s') => return Step::Act(Action::ToggleSidebar),
            _ => {}
        }
        let Some(key) = event.character() else {
            return Step::Swallow;
        };
        let act = Step::Act;
        if let Some(digit) = key.to_digit(10) {
            return act(Action::Window(digit));
        }
        match key {
            'd' => act(Action::Detach),
            'r' => act(Action::Redraw),
            'e' => act(Action::Pager),
            'c' => act(Action::NewWindow),
            '(' => act(Action::Switch(Over::Session, Direction::Previous)),
            ')' => act(Action::Switch(Over::Session, Direction::Next)),
            'p' => act(Action::Switch(Over::Window, Direction::Previous)),
            'n' => act(Action::Switch(Over::Window, Direction::Next)),
            'L' => act(Action::LastSession),
            'l' => act(Action::LastWindow),
            's' | 'w' => act(Action::Chooser),
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
            .map(|event| keys.feed(event, false))
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
    fn a_plain_key_goes_to_the_pane_and_the_prefix_is_a_pending_mode() {
        let mut keys = Keys::new();
        let x = events("x").remove(0);
        assert_eq!(keys.feed(&x, false), Step::Pane(x));
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
        assert_eq!(steps(&mut keys, "\x01z\x01\x1b[A"), swallowed(4));
        assert_eq!(keys.state(), &State::Normal);
    }

    #[test]
    fn every_binding_of_the_prefix_table() {
        let table = [
            ("d", act(Action::Detach)),
            ("r", act(Action::Redraw)),
            ("e", act(Action::Pager)),
            ("c", act(Action::NewWindow)),
            (")", act(Action::Switch(Over::Session, Direction::Next))),
            ("n", act(Action::Switch(Over::Window, Direction::Next))),
            ("p", act(Action::Switch(Over::Window, Direction::Previous))),
            ("L", act(Action::LastSession)),
            ("l", act(Action::LastWindow)),
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
        assert_eq!(keys.feed(&ctrl_d, true), act(Action::Kill(Kill::Pane)));
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
        assert_eq!(keys.feed(&x, false), Step::Pane(x));
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

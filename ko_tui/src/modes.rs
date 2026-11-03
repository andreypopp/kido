use ko_vt::render::MouseTracking;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Mouse,
    ButtonMouse,
    AnyMouse,
    SgrMouse,
    Focus,
    Paste,
    Cursor,
}

const MODES: [Mode; 7] = [
    Mode::Mouse,
    Mode::ButtonMouse,
    Mode::AnyMouse,
    Mode::SgrMouse,
    Mode::Focus,
    Mode::Paste,
    Mode::Cursor,
];

impl Mode {
    fn code(self) -> u16 {
        match self {
            Mode::Mouse => 1000,
            Mode::ButtonMouse => 1002,
            Mode::AnyMouse => 1003,
            Mode::SgrMouse => 1006,
            Mode::Focus => 1004,
            Mode::Paste => 2004,
            Mode::Cursor => 25,
        }
    }

    fn of(code: u16) -> Option<Mode> {
        MODES.into_iter().find(|mode| mode.code() == code)
    }

    fn tracking(tracking: MouseTracking) -> Mode {
        match tracking {
            MouseTracking::Button => Mode::ButtonMouse,
            MouseTracking::Any => Mode::AnyMouse,
            MouseTracking::Off | MouseTracking::Press => Mode::Mouse,
        }
    }

    fn set(self, on: bool, out: &mut String) {
        out.push_str(&format!(
            "\x1b[?{}{}",
            self.code(),
            if on { 'h' } else { 'l' }
        ));
    }
}

pub(crate) fn query() -> String {
    MODES
        .iter()
        .map(|mode| format!("\x1b[?{}$p", mode.code()))
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Applied {
    mouse: MouseTracking,
    keyboard: u8,
}

#[derive(Debug, Default)]
pub(crate) struct Modes {
    saved: Vec<(Mode, bool)>,
    applied: Option<Applied>,
}

impl Modes {
    pub(crate) fn saved(reports: &[(u16, u16)]) -> Modes {
        let mut saved: Vec<(Mode, bool)> = Vec::new();
        for (code, value) in reports {
            if let (Some(mode), 1..=4) = (Mode::of(*code), value) {
                saved.retain(|(known, _)| *known != mode);
                saved.push((mode, matches!(value, 1 | 3)));
            }
        }
        Modes {
            saved,
            ..Modes::default()
        }
    }

    pub(crate) fn reset(&mut self, out: &mut String) {
        for mode in MODES.into_iter().filter(|mode| *mode != Mode::Cursor) {
            mode.set(false, out);
        }
        if self.applied.take().is_some() {
            out.push_str("\x1b[<u");
        }
        out.push_str("\x1b[0 q");
    }

    pub(crate) fn apply(&mut self, mouse: MouseTracking, keyboard: u8, out: &mut String) {
        let before = self.applied;
        if before.map(|applied| applied.mouse) != Some(mouse) {
            let wanted = Mode::tracking(mouse);
            let previous: Vec<Mode> = match before {
                Some(known) => vec![Mode::tracking(known.mouse)],
                None => [Mode::Mouse, Mode::ButtonMouse, Mode::AnyMouse]
                    .into_iter()
                    .filter(|mode| self.saved.contains(&(*mode, true)))
                    .collect(),
            };
            for mode in previous.into_iter().filter(|mode| *mode != wanted) {
                mode.set(false, out);
            }
            wanted.set(true, out);
            for mode in [Mode::SgrMouse, Mode::Focus, Mode::Paste] {
                mode.set(true, out);
            }
        }
        let keyboard = keyboard | 1;
        if before.map(|applied| applied.keyboard) != Some(keyboard) {
            if before.is_some() {
                out.push_str("\x1b[<u");
            }
            out.push_str(&format!("\x1b[>{keyboard}u"));
        }
        self.applied = Some(Applied { mouse, keyboard });
    }

    pub(crate) fn restore(&self, out: &mut String) {
        let on = |mode: Mode| {
            self.saved
                .iter()
                .find(|(known, _)| *known == mode)
                .map_or(mode == Mode::Cursor, |(_, on)| *on)
        };
        for wanted in [false, true] {
            for mode in MODES.into_iter().filter(|mode| on(*mode) == wanted) {
                mode.set(wanted, out);
            }
        }
        out.push_str("\x1b[0 q");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_are_saved_set_replaced_reset_and_restored_in_order() {
        let mut modes = Modes::saved(&[(1003, 1), (25, 0), (2004, 2), (9999, 1), (1003, 3)]);
        let (mut applied, mut again) = (String::new(), String::new());
        modes.apply(MouseTracking::Any, 0, &mut applied);
        modes.apply(MouseTracking::Button, 3, &mut again);
        let (mut reset, mut restored) = (String::new(), String::new());
        modes.restore(&mut restored);
        modes.reset(&mut reset);
        assert_eq!(
            [applied, again, restored, reset],
            [
                "\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[>1u",
                "\x1b[?1003l\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[<u\x1b[>3u",
                "\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?1004l\x1b[?2004l\x1b[?1003h\x1b[?25h\x1b[0 q",
                "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?2004l\x1b[<u\x1b[0 q",
            ]
        );
    }
}

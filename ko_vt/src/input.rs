use std::ffi::{c_char, c_void};
use std::ptr;

use ko_pane_wire::frame::{Key, KeyAction, Mouse, MouseAction, MouseButton};
use ko_vt_sys as sys;

use crate::{Error, Terminal, check};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pasted {
    pub written: bool,
    pub rejected: bool,
}

fn sized(
    mut call: impl FnMut(*mut c_char, usize, &mut usize) -> sys::GhosttyResult,
) -> Result<Vec<u8>, Error> {
    let mut written = 0;
    match call(ptr::null_mut(), 0, &mut written) {
        sys::GHOSTTY_SUCCESS => Ok(Vec::new()),
        sys::GHOSTTY_OUT_OF_SPACE => {
            let mut out = vec![0u8; written];
            check(call(out.as_mut_ptr().cast(), out.len(), &mut written))?;
            out.truncate(written);
            Ok(out)
        }
        code => Err(Error::Ghostty(code)),
    }
}

fn shift_made_text(mods: u16, unshifted: char, text: &str) -> bool {
    let shift = sys::GHOSTTY_MODS_SHIFT as u16;
    let others = (sys::GHOSTTY_MODS_CTRL | sys::GHOSTTY_MODS_ALT | sys::GHOSTTY_MODS_SUPER) as u16;
    let mut chars = text.chars();
    let (Some(typed), None) = (chars.next(), chars.next()) else {
        return false;
    };
    mods & shift != 0
        && mods & others == 0
        && typed != unshifted
        && typed >= ' '
        && typed != '\u{7f}'
}

#[derive(Debug)]
struct KeyEncoder {
    encoder: sys::GhosttyKeyEncoder,
    event: sys::GhosttyKeyEvent,
}

impl Drop for KeyEncoder {
    fn drop(&mut self) {
        // SAFETY: both handles were created by `new` (or are NULL, which the frees permit).
        unsafe {
            sys::ghostty_key_event_free(self.event);
            sys::ghostty_key_encoder_free(self.encoder);
        }
    }
}

#[derive(Debug)]
struct MouseEncoder {
    encoder: sys::GhosttyMouseEncoder,
    event: sys::GhosttyMouseEvent,
}

impl Drop for MouseEncoder {
    fn drop(&mut self) {
        // SAFETY: both handles were created by `new` (or are NULL, which the frees permit).
        unsafe {
            sys::ghostty_mouse_event_free(self.event);
            sys::ghostty_mouse_encoder_free(self.encoder);
        }
    }
}

unsafe extern "C" fn read_text(
    userdata: *mut c_void,
    _mime: sys::GhosttyString,
    writer: sys::GhosttyWriter,
) -> bool {
    // SAFETY: userdata is the `&str` that `paste` lends for one libghostty-vt call.
    let text = unsafe { *userdata.cast::<&str>() };
    match writer.write {
        // SAFETY: the writer is the one libghostty-vt passed, and text is readable.
        Some(write) => unsafe { write(writer.userdata, text.as_ptr(), text.len()) },
        None => false,
    }
}

impl Terminal {
    pub fn encode_key(&self, key: &Key) -> Result<Vec<u8>, Error> {
        let mut keys = KeyEncoder {
            encoder: ptr::null_mut(),
            event: ptr::null_mut(),
        };
        // SAFETY: each handle receives a new object that `KeyEncoder` frees.
        check(unsafe { sys::ghostty_key_encoder_new(ptr::null(), &mut keys.encoder) })?;
        // SAFETY: as above.
        check(unsafe { sys::ghostty_key_event_new(ptr::null(), &mut keys.event) })?;
        let action = match key.action {
            KeyAction::Release => sys::GHOSTTY_KEY_ACTION_RELEASE,
            KeyAction::Press => sys::GHOSTTY_KEY_ACTION_PRESS,
            KeyAction::Repeat => sys::GHOSTTY_KEY_ACTION_REPEAT,
        };
        let consumed = if shift_made_text(key.mods, key.unshifted, &key.text) {
            sys::GHOSTTY_MODS_SHIFT as u16
        } else {
            0
        };
        let option_as_alt = sys::GHOSTTY_OPTION_AS_ALT_TRUE;
        // SAFETY: the handles are live, the terminal is live, and MACOS_OPTION_AS_ALT takes the
        // option-as-alt enum; the text outlives the encode.
        unsafe {
            sys::ghostty_key_encoder_setopt_from_terminal(keys.encoder, self.vt.as_ptr());
            sys::ghostty_key_encoder_setopt(
                keys.encoder,
                sys::GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
                ptr::from_ref(&option_as_alt).cast(),
            );
            sys::ghostty_key_event_set_action(keys.event, action);
            sys::ghostty_key_event_set_key(keys.event, i32::from(key.key.get()));
            sys::ghostty_key_event_set_mods(keys.event, key.mods);
            sys::ghostty_key_event_set_consumed_mods(keys.event, consumed);
            sys::ghostty_key_event_set_unshifted_codepoint(keys.event, u32::from(key.unshifted));
            sys::ghostty_key_event_set_utf8(keys.event, key.text.as_ptr().cast(), key.text.len());
            sys::ghostty_key_event_set_composing(keys.event, key.composing);
        }
        sized(|out, capacity, written| {
            // SAFETY: the handles are live, and out holds capacity writable bytes.
            unsafe {
                sys::ghostty_key_encoder_encode(keys.encoder, keys.event, out, capacity, written)
            }
        })
    }

    pub fn encode_mouse(&self, mouse: &Mouse) -> Result<Vec<u8>, Error> {
        let mut mice = MouseEncoder {
            encoder: ptr::null_mut(),
            event: ptr::null_mut(),
        };
        // SAFETY: each handle receives a new object that `MouseEncoder` frees.
        check(unsafe { sys::ghostty_mouse_encoder_new(ptr::null(), &mut mice.encoder) })?;
        // SAFETY: as above.
        check(unsafe { sys::ghostty_mouse_event_new(ptr::null(), &mut mice.event) })?;
        let size = sys::GhosttyMouseEncoderSize {
            size: size_of::<sys::GhosttyMouseEncoderSize>(),
            screen_width: u32::from(self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_COLS, 0)?),
            screen_height: u32::from(self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_ROWS, 0)?),
            cell_width: 1,
            cell_height: 1,
            ..Default::default()
        };
        let button = match mouse.button {
            MouseButton::Unknown => sys::GHOSTTY_MOUSE_BUTTON_UNKNOWN,
            MouseButton::Left => sys::GHOSTTY_MOUSE_BUTTON_LEFT,
            MouseButton::Right => sys::GHOSTTY_MOUSE_BUTTON_RIGHT,
            MouseButton::Middle => sys::GHOSTTY_MOUSE_BUTTON_MIDDLE,
            MouseButton::Four => sys::GHOSTTY_MOUSE_BUTTON_FOUR,
            MouseButton::Five => sys::GHOSTTY_MOUSE_BUTTON_FIVE,
            MouseButton::Six => sys::GHOSTTY_MOUSE_BUTTON_SIX,
            MouseButton::Seven => sys::GHOSTTY_MOUSE_BUTTON_SEVEN,
            MouseButton::Eight => sys::GHOSTTY_MOUSE_BUTTON_EIGHT,
            MouseButton::Nine => sys::GHOSTTY_MOUSE_BUTTON_NINE,
            MouseButton::Ten => sys::GHOSTTY_MOUSE_BUTTON_TEN,
            MouseButton::Eleven => sys::GHOSTTY_MOUSE_BUTTON_ELEVEN,
        };
        let action = match mouse.action {
            MouseAction::Press => sys::GHOSTTY_MOUSE_ACTION_PRESS,
            MouseAction::Release => sys::GHOSTTY_MOUSE_ACTION_RELEASE,
            MouseAction::Motion => sys::GHOSTTY_MOUSE_ACTION_MOTION,
        };
        let pressed = mouse.button != MouseButton::Unknown && mouse.action != MouseAction::Release;
        // SAFETY: the handles are live, the terminal is live, and each option takes the type that
        // mouse.h documents for it.
        unsafe {
            sys::ghostty_mouse_encoder_setopt_from_terminal(mice.encoder, self.vt.as_ptr());
            sys::ghostty_mouse_encoder_setopt(
                mice.encoder,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                ptr::from_ref(&size).cast(),
            );
            sys::ghostty_mouse_encoder_setopt(
                mice.encoder,
                sys::GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                ptr::from_ref(&pressed).cast(),
            );
            sys::ghostty_mouse_event_set_action(mice.event, action);
            sys::ghostty_mouse_event_set_button(mice.event, button);
            sys::ghostty_mouse_event_set_mods(mice.event, mouse.mods);
            sys::ghostty_mouse_event_set_position(
                mice.event,
                sys::GhosttyMousePosition {
                    x: f32::from(mouse.col),
                    y: f32::from(mouse.row),
                },
            );
        }
        sized(|out, capacity, written| {
            // SAFETY: the handles are live, and out holds capacity writable bytes.
            unsafe {
                sys::ghostty_mouse_encoder_encode(mice.encoder, mice.event, out, capacity, written)
            }
        })
    }

    pub fn encode_focus(&self, gained: bool) -> Result<Vec<u8>, Error> {
        if !self.mode(1004)? {
            return Ok(Vec::new());
        }
        let event = if gained {
            sys::GHOSTTY_FOCUS_GAINED
        } else {
            sys::GHOSTTY_FOCUS_LOST
        };
        let mut out = [0u8; 3];
        let mut written = 0;
        // SAFETY: out holds out.len() writable bytes, and written is writable.
        check(unsafe {
            sys::ghostty_focus_encode(event, out.as_mut_ptr().cast(), out.len(), &mut written)
        })?;
        Ok(out.get(..written).unwrap_or_default().to_vec())
    }

    pub fn paste(&mut self, text: &str, check_safe: bool) -> Result<Pasted, Error> {
        let mut text = text;
        let mime = sys::GhosttyString {
            ptr: b"text/plain".as_ptr(),
            len: 10,
        };
        let paste = sys::GhosttyPaste {
            size: size_of::<sys::GhosttyPaste>(),
            location: sys::GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
            source: sys::GHOSTTY_PASTE_SOURCE_TEXT,
            mimes: &mime,
            mimes_len: 1,
            reader: sys::GhosttyMimeReader {
                read: Some(read_text),
                userdata: ptr::from_mut(&mut text).cast(),
            },
            allow_unsafe: !check_safe,
        };
        let mut written = false;
        // SAFETY: the handle is live, and the paste, its mime and the text outlive the call.
        let result = unsafe { sys::ghostty_terminal_paste(self.vt.as_ptr(), &paste, &mut written) };
        match result {
            sys::GHOSTTY_SUCCESS | sys::GHOSTTY_REJECTED => Ok(Pasted {
                written,
                rejected: result == sys::GHOSTTY_REJECTED,
            }),
            code => Err(Error::Ghostty(code)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shifted_text_counts_as_consumed_only_for_a_new_printable_character() {
        let shift = sys::GHOSTTY_MODS_SHIFT as u16;
        let ctrl = sys::GHOSTTY_MODS_CTRL as u16;
        let alt = sys::GHOSTTY_MODS_ALT as u16;
        let super_ = sys::GHOSTTY_MODS_SUPER as u16;
        let cases = [
            ("A over a", shift, 'a', "A", true),
            ("unshifted text", 0, 'a', "a", false),
            ("shift without a change", shift, 'a', "a", false),
            ("with ctrl", shift | ctrl, 'a', "A", false),
            ("with alt", shift | alt, 'a', "A", false),
            ("with super", shift | super_, 'a', "A", false),
            ("symbol", shift, '1', "!", true),
            ("two characters", shift, 'a', "AB", false),
            ("a multibyte character", shift, 'e', "\u{c9}", true),
            ("empty text", shift, 'a', "", false),
            ("a control character", shift, 'a', "\u{1}", false),
            ("delete", shift, 'a', "\u{7f}", false),
        ];
        for (label, mods, unshifted, text, expected) in cases {
            assert_eq!(shift_made_text(mods, unshifted, text), expected, "{label}");
        }
    }
}

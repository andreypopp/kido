use std::ffi::c_void;
use std::ptr;

use ko_pane_wire::frame::PixelFormat;
use ko_vt_sys as sys;

use crate::{Error, Terminal, check, present};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Primary,
    Alternate,
}

impl Screen {
    fn raw(self) -> sys::GhosttyTerminalScreen {
        match self {
            Screen::Primary => sys::GHOSTTY_TERMINAL_SCREEN_PRIMARY,
            Screen::Alternate => sys::GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Playback {
    None,
    Stopped,
    Loading,
    Running,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame<'a> {
    pub pixels: Option<&'a [u8]>,
    pub len: usize,
    pub format: PixelFormat,
    pub generation: u64,
    pub gap_ms: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Animation {
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub state: Playback,
    pub current: u32,
    pub max_loops: u32,
    pub current_loop: u32,
    pub pending: bool,
}

impl Terminal {
    /// The playback state of an image on a screen. `None` if the image does not exist.
    pub fn animation(&self, screen: Screen, image: u32) -> Result<Option<Animation>, Error> {
        // SAFETY: the handle is live.
        let handle = unsafe {
            sys::ghostty_kitty_graphics_screen_image(self.vt.as_ptr(), screen.raw(), image)
        };
        if handle.is_null() {
            return Ok(None);
        }
        let keys = [
            sys::GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
            sys::GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
            sys::GHOSTTY_KITTY_IMAGE_DATA_FRAME_COUNT,
            sys::GHOSTTY_KITTY_IMAGE_DATA_ANIMATION_STATE,
            sys::GHOSTTY_KITTY_IMAGE_DATA_CURRENT_FRAME,
            sys::GHOSTTY_KITTY_IMAGE_DATA_MAX_LOOPS,
            sys::GHOSTTY_KITTY_IMAGE_DATA_CURRENT_LOOP,
            sys::GHOSTTY_KITTY_IMAGE_DATA_PENDING_FRAMES,
        ];
        let (mut width, mut height) = (0u32, 0u32);
        let mut frames = 0u32;
        let mut state = sys::GHOSTTY_KITTY_ANIMATION_STATE_NONE;
        let mut current = 0u32;
        let mut max_loops = 0u32;
        let mut current_loop = 0u32;
        let mut pending = false;
        let mut values = [
            ptr::from_mut(&mut width).cast::<c_void>(),
            ptr::from_mut(&mut height).cast(),
            ptr::from_mut(&mut frames).cast(),
            ptr::from_mut(&mut state).cast(),
            ptr::from_mut(&mut current).cast(),
            ptr::from_mut(&mut max_loops).cast(),
            ptr::from_mut(&mut current_loop).cast(),
            ptr::from_mut(&mut pending).cast(),
        ];
        let mut written = 0usize;
        // SAFETY: the handle came from `ghostty_kitty_graphics_screen_image` and the terminal has
        // not changed since; each value points at the type kitty_graphics.h documents for its
        // key, and the arrays have `keys.len()` entries.
        check(unsafe {
            sys::ghostty_kitty_graphics_image_get_multi(
                handle,
                keys.len(),
                keys.as_ptr(),
                values.as_mut_ptr(),
                &raw mut written,
            )
        })?;
        Ok(Some(Animation {
            width,
            height,
            frames,
            state: match state {
                sys::GHOSTTY_KITTY_ANIMATION_STATE_NONE => Playback::None,
                sys::GHOSTTY_KITTY_ANIMATION_STATE_STOPPED => Playback::Stopped,
                sys::GHOSTTY_KITTY_ANIMATION_STATE_LOADING => Playback::Loading,
                sys::GHOSTTY_KITTY_ANIMATION_STATE_RUNNING => Playback::Running,
                _ => return Err(Error::Ghostty(sys::GHOSTTY_INVALID_VALUE)),
            },
            current,
            max_loops,
            current_loop,
            pending,
        }))
    }

    /// Frame `number` of an image, numbered as the protocol does: 1 is the image, 2 and up are
    /// its animation frames. `None` if the image or the frame does not exist.
    pub fn frame(
        &self,
        screen: Screen,
        image: u32,
        number: u32,
    ) -> Result<Option<Frame<'_>>, Error> {
        // DATA_PTR is last: the call answers NO_VALUE for a pending frame after it wrote the
        // values before it.
        let keys = [
            sys::GHOSTTY_KITTY_FRAME_DATA_DATA_LEN,
            sys::GHOSTTY_KITTY_FRAME_DATA_FORMAT,
            sys::GHOSTTY_KITTY_FRAME_DATA_GENERATION,
            sys::GHOSTTY_KITTY_FRAME_DATA_GAP_MS,
            sys::GHOSTTY_KITTY_FRAME_DATA_DATA_PTR,
        ];
        let mut len = 0usize;
        let mut format = sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGBA;
        let mut generation = 0u64;
        let mut gap_ms = 0u32;
        let mut data = ptr::null::<u8>();
        let mut values = [
            ptr::from_mut(&mut len).cast::<c_void>(),
            ptr::from_mut(&mut format).cast(),
            ptr::from_mut(&mut generation).cast(),
            ptr::from_mut(&mut gap_ms).cast(),
            ptr::from_mut(&mut data).cast(),
        ];
        let mut written = 0usize;
        // SAFETY: the handle is live; each value points at the type kitty_graphics.h documents
        // for its key, and the arrays have `keys.len()` entries.
        let result = unsafe {
            sys::ghostty_kitty_graphics_frame_get_multi(
                self.vt.as_ptr(),
                screen.raw(),
                image,
                number,
                keys.len(),
                keys.as_ptr(),
                values.as_mut_ptr(),
                &raw mut written,
            )
        };
        let pixels = match result {
            sys::GHOSTTY_SUCCESS => Some(()),
            sys::GHOSTTY_NO_VALUE if written == keys.len() - 1 => None,
            sys::GHOSTTY_NO_VALUE | sys::GHOSTTY_INVALID_VALUE => return Ok(None),
            code => return Err(Error::Ghostty(code)),
        };
        let format = match format {
            sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGB => PixelFormat::Rgb,
            sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => PixelFormat::Rgba,
            sys::GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => PixelFormat::GrayAlpha,
            sys::GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => PixelFormat::Gray,
            _ => return Err(Error::Ghostty(sys::GHOSTTY_INVALID_VALUE)),
        };
        Ok(Some(Frame {
            // SAFETY: the pointer holds `len` readable bytes until the terminal changes
            // (kitty_graphics.h), which the borrow of self excludes.
            pixels: pixels.map(|()| unsafe { std::slice::from_raw_parts(data, len) }),
            len,
            format,
            generation,
            gap_ms,
        }))
    }

    /// Complete a pending frame with pixels the terminal copies. `Ok(false)`: the image or
    /// frame is gone, the frame is not pending, or `generation` is not its generation any more.
    pub fn attach_frame(
        &mut self,
        screen: Screen,
        image: u32,
        number: u32,
        generation: u64,
        pixels: &[u8],
    ) -> Result<bool, Error> {
        // SAFETY: the handle is live and pixels is a valid slice for the call.
        present(unsafe {
            sys::ghostty_kitty_graphics_frame_attach(
                self.vt.as_ptr(),
                screen.raw(),
                image,
                number,
                generation,
                pixels.as_ptr(),
                pixels.len(),
            )
        })
    }

    pub fn storage_generation(&self) -> Result<u64, Error> {
        let graphics = self.get(
            sys::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
            ptr::null_mut::<c_void>() as sys::GhosttyKittyGraphics,
        )?;
        let mut generation = 0u64;
        // SAFETY: the graphics handle is live, and GENERATION takes a uint64_t.
        check(unsafe {
            sys::ghostty_kitty_graphics_get(
                graphics,
                sys::GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION,
                (&raw mut generation).cast(),
            )
        })?;
        Ok(generation)
    }

    pub fn placements(&self) -> Result<Vec<(u32, u32)>, Error> {
        let graphics = self.get(
            sys::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
            ptr::null_mut::<c_void>() as sys::GhosttyKittyGraphics,
        )?;
        let mut iterator = ptr::null_mut();
        // SAFETY: a NULL allocator selects the default one; iterator receives the new handle.
        check(unsafe {
            sys::ghostty_kitty_graphics_placement_iterator_new(ptr::null(), &mut iterator)
        })?;
        // SAFETY: the graphics handle is live, and the iterator takes this data kind.
        let filled = check(unsafe {
            sys::ghostty_kitty_graphics_get(
                graphics,
                sys::GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
                (&raw mut iterator).cast(),
            )
        });
        let mut found = Vec::new();
        let mut result = filled;
        // SAFETY: the iterator is live and filled when result is Ok.
        while result.is_ok() && unsafe { sys::ghostty_kitty_graphics_placement_next(iterator) } {
            let (mut image, mut placement) = (0u32, 0u32);
            let read = |data, out: *mut u32| {
                // SAFETY: the iterator points at a placement, and both data kinds are uint32_t.
                check(unsafe {
                    sys::ghostty_kitty_graphics_placement_get(iterator, data, out.cast())
                })
            };
            result = read(
                sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
                &mut image,
            )
            .and_then(|()| {
                read(
                    sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
                    &mut placement,
                )
            });
            found.push((image, placement));
        }
        // SAFETY: the iterator is freed once.
        unsafe { sys::ghostty_kitty_graphics_placement_iterator_free(iterator) };
        result.map(|()| found)
    }

    pub fn animation_tick(&mut self, now_ms: u64) -> Result<Option<u64>, Error> {
        let graphics = self.get(
            sys::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
            ptr::null_mut::<c_void>() as sys::GhosttyKittyGraphics,
        )?;
        let mut next = 0u64;
        // SAFETY: the handle came from the live terminal, and next is writable.
        present(unsafe {
            sys::ghostty_kitty_graphics_animation_tick(graphics, now_ms, &raw mut next)
        })
        .map(|playing| playing.then_some(next))
    }

    /// Grows each time a frame of either screen becomes pending or a pending frame's generation
    /// moves. Read it after a feed batch.
    pub fn pending_generation(&self) -> Result<u64, Error> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_PENDING_GENERATION, 0u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::make;

    const BLUE: [u8; 4] = [0, 0, 255, 255];

    fn two_frames() -> Terminal {
        let mut vt = make(80, 24);
        vt.write(
            b"\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\\
              \x1b_Ga=f,f=32,i=1,s=1,v=1,z=40;AAD//w==\x1b\\",
        );
        vt
    }

    // Frame 3 comes from a shared memory object that does not exist, so the terminal holds it
    // pending.
    fn pending_third_frame(vt: &mut Terminal) {
        vt.write(b"\x1b_Ga=f,i=1,t=s,f=32,s=1,v=1,z=20;L2tpZG8tbWlzc2luZw==\x1b\\");
    }

    #[test]
    fn frame_two_of_a_two_frame_upload() {
        let vt = two_frames();
        let frame = vt.frame(Screen::Primary, 1, 2).unwrap().unwrap();
        let animation = vt.animation(Screen::Primary, 1).unwrap().unwrap();
        assert_eq!(frame.pixels, Some(&BLUE[..]));
        assert_eq!(frame.len, 4);
        assert_eq!(frame.format, PixelFormat::Rgba);
        assert_eq!(frame.gap_ms, 40);
        let root = vt.frame(Screen::Primary, 1, 1).unwrap().unwrap();
        assert_eq!(root.pixels, Some(&[255, 0, 0, 255][..]));
        assert!(root.generation < frame.generation);
        assert_eq!(
            animation,
            Animation {
                width: 1,
                height: 1,
                frames: 2,
                state: Playback::Stopped,
                current: 1,
                max_loops: 0,
                current_loop: 0,
                pending: false,
            }
        );
        assert!(vt.frame(Screen::Primary, 1, 3).unwrap().is_none());
        assert!(vt.frame(Screen::Primary, 1, 0).unwrap().is_none());
        assert!(vt.frame(Screen::Primary, 2, 1).unwrap().is_none());
        assert!(vt.frame(Screen::Alternate, 1, 1).unwrap().is_none());
        assert!(vt.animation(Screen::Alternate, 1).unwrap().is_none());
        assert_eq!(vt.pending_generation().unwrap(), 0);
    }

    #[test]
    fn a_placement_is_listed_with_its_image() {
        let vt = two_frames();
        assert_eq!(vt.placements().unwrap(), [(1, 0)]);
        assert_eq!(make(80, 24).placements().unwrap(), []);
    }

    #[test]
    fn an_image_of_the_other_screen_is_readable() {
        let mut vt = two_frames();
        vt.write(b"\x1b[?1049h");
        assert!(vt.alternate().unwrap());
        let frame = vt.frame(Screen::Primary, 1, 2).unwrap().unwrap();
        let animation = vt.animation(Screen::Primary, 1).unwrap().unwrap();
        assert_eq!(frame.pixels, Some(&BLUE[..]));
        assert_eq!(animation.frames, 2);
    }

    #[test]
    fn an_attach_with_a_stale_generation_is_refused() {
        let mut vt = two_frames();
        assert_eq!(vt.pending_generation().unwrap(), 0);
        pending_third_frame(&mut vt);
        let marked = vt.pending_generation().unwrap();
        assert_ne!(marked, 0);
        let frame = vt.frame(Screen::Primary, 1, 3).unwrap().unwrap();
        let animation = vt.animation(Screen::Primary, 1).unwrap().unwrap();
        assert_eq!(frame.pixels, None);
        assert_eq!(frame.len, 4);
        assert_eq!(frame.gap_ms, 20);
        assert!(animation.pending);
        let generation = frame.generation;

        let pixels = [1, 2, 3, 255];
        assert!(
            !vt.attach_frame(Screen::Primary, 1, 3, generation - 1, &pixels)
                .unwrap()
        );
        assert!(
            !vt.attach_frame(Screen::Primary, 1, 4, generation, &pixels)
                .unwrap()
        );
        assert!(
            !vt.attach_frame(Screen::Primary, 1, 2, generation, &pixels)
                .unwrap()
        );
        assert!(matches!(
            vt.attach_frame(Screen::Primary, 1, 3, generation, &pixels[..3]),
            Err(Error::Ghostty(sys::GHOSTTY_INVALID_VALUE))
        ));
        assert_eq!(
            vt.frame(Screen::Primary, 1, 3).unwrap().unwrap().pixels,
            None
        );
    }

    #[test]
    fn an_attach_with_the_right_generation_lands() {
        let mut vt = two_frames();
        pending_third_frame(&mut vt);
        let generation = vt.frame(Screen::Primary, 1, 3).unwrap().unwrap().generation;
        let pixels = [1, 2, 3, 255];
        assert!(
            vt.attach_frame(Screen::Primary, 1, 3, generation, &pixels)
                .unwrap()
        );
        let landed = vt.frame(Screen::Primary, 1, 3).unwrap().unwrap();
        let animation = vt.animation(Screen::Primary, 1).unwrap().unwrap();
        assert_eq!(landed.pixels, Some(&pixels[..]));
        assert_eq!(landed.generation, generation);
        assert!(!animation.pending);
        assert!(
            !vt.attach_frame(Screen::Primary, 1, 3, generation, &pixels)
                .unwrap()
        );
    }
}

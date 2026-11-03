use ko_pane_wire::frame::{ImageKey, ImageObject, PixelFormat};
use ko_sys::mapping::{self, Name, Named};
use ko_vt::Terminal;
use ko_vt::frames::Screen;

#[derive(Debug)]
struct Made {
    key: ImageKey,
    name: Name,
}

#[derive(Debug)]
pub(crate) struct Answer {
    name: Name,
    len: u64,
    width: u32,
    height: u32,
    format: PixelFormat,
    generation: u64,
    gap_ms: u32,
    frames: u32,
}

impl Answer {
    pub(crate) fn object(&self) -> ImageObject<'_> {
        ImageObject {
            name: self.name.as_str().as_bytes(),
            len: self.len,
            width: self.width,
            height: self.height,
            format: self.format,
            generation: self.generation,
            gap_ms: self.gap_ms,
            frames: self.frames,
        }
    }
}

#[derive(Debug, Default)]
pub(crate) struct Objects {
    made: Vec<Made>,
    seen: Option<(u64, bool)>,
}

fn screens(vt: &Terminal) -> [Screen; 2] {
    if vt.alternate().unwrap_or(false) {
        [Screen::Alternate, Screen::Primary]
    } else {
        [Screen::Primary, Screen::Alternate]
    }
}

fn pixels_of(vt: &Terminal, key: ImageKey) -> Option<(Screen, ko_vt::frames::Frame<'_>)> {
    screens(vt).into_iter().find_map(|screen| {
        let frame = vt.frame(screen, key.image, key.frame).ok()??;
        (frame.pixels.is_some() && frame.len > 0 && frame.generation == key.generation)
            .then_some((screen, frame))
    })
}

impl Objects {
    pub(crate) fn answer(&mut self, vt: &Terminal, key: ImageKey, name: &Name) -> Option<Answer> {
        let (screen, frame) = pixels_of(vt, key)?;
        let animation = vt.animation(screen, key.image).ok()??;
        let name = match self.made.iter().find(|made| made.key == key) {
            Some(made) => made.name.clone(),
            None => {
                let mut object = Named::create(name, frame.len).ok()?;
                object.bytes_mut()?.copy_from_slice(frame.pixels?);
                self.made.push(Made {
                    key,
                    name: name.clone(),
                });
                name.clone()
            }
        };
        Some(Answer {
            name,
            len: u64::try_from(frame.len).ok()?,
            width: animation.width,
            height: animation.height,
            format: frame.format,
            generation: frame.generation,
            gap_ms: frame.gap_ms,
            frames: animation.frames,
        })
    }

    pub(crate) fn retire(&mut self, vt: &Terminal) -> Vec<Name> {
        let now = (
            vt.storage_generation().unwrap_or(0),
            vt.alternate().unwrap_or(false),
        );
        if self.seen.replace(now) == Some(now) {
            return Vec::new();
        }
        let mut gone = Vec::new();
        self.made.retain(|made| {
            let kept = pixels_of(vt, made.key).is_some();
            if !kept {
                let _ = mapping::unlink(&made.name);
                gone.push(made.name.clone());
            }
            kept
        });
        gone
    }
}

impl Drop for Objects {
    fn drop(&mut self) {
        for made in self.made.drain(..) {
            let _ = mapping::unlink(&made.name);
        }
    }
}

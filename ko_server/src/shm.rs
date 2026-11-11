use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use ko_pane_wire::frame::ImageKey;
use ko_sys::mapping::{self, Name};

use ko_wire::ids::PaneId;

// macOS cannot list POSIX shared memory objects.
#[derive(Debug)]
pub(crate) struct Leaks {
    path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    pane: PaneId,
    key: ImageKey,
    name: Name,
}

impl Entry {
    fn parse(line: &str) -> Option<Entry> {
        let mut fields = line.split(' ');
        let entry = Entry {
            pane: fields.next()?.parse().ok()?,
            key: ImageKey {
                image: fields.next()?.parse().ok()?,
                frame: fields.next()?.parse().ok()?,
                generation: fields.next()?.parse().ok()?,
            },
            name: Name::new(fields.next()?)?,
        };
        fields.next().is_none().then_some(entry)
    }

    fn line(&self) -> String {
        format!(
            "{} {} {} {} {}",
            self.pane,
            self.key.image,
            self.key.frame,
            self.key.generation,
            self.name.as_str()
        )
    }
}

impl Leaks {
    pub(crate) fn new(dir: &Path) -> Leaks {
        Leaks {
            path: dir.join("shm"),
        }
    }

    fn read(&self) -> Vec<Entry> {
        fs::read_to_string(&self.path)
            .unwrap_or_default()
            .lines()
            .filter_map(Entry::parse)
            .collect()
    }

    fn write(&self, entries: &[Entry]) -> io::Result<()> {
        if entries.is_empty() {
            return match fs::remove_file(&self.path) {
                Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
                _ => Ok(()),
            };
        }
        let text: String = entries
            .iter()
            .map(|entry| format!("{}\n", entry.line()))
            .collect();
        let scratch = self.path.with_extension("tmp");
        fs::write(&scratch, text)?;
        fs::rename(scratch, &self.path)
    }

    pub(crate) fn record(&self, pane: PaneId, key: ImageKey, name: &Name) -> io::Result<()> {
        let entry = Entry {
            pane,
            key,
            name: name.clone(),
        };
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(file, "{}", entry.line())
    }

    pub(crate) fn gone(&self, name: &Name) {
        self.release(|entry| entry.name == *name);
    }

    pub(crate) fn release_pane(&self, pane: PaneId) {
        self.release(|entry| entry.pane == pane);
    }

    pub(crate) fn release_all(&self) {
        self.release(|_| true);
    }

    fn release(&self, matching: impl Fn(&Entry) -> bool) {
        let (released, kept): (Vec<Entry>, Vec<Entry>) =
            self.read().into_iter().partition(matching);
        for entry in &released {
            let _ = mapping::unlink(&entry.name);
        }
        if !released.is_empty() {
            let _ = self.write(&kept);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ko_sys::mapping::Named;

    fn scratch() -> (PathBuf, Leaks) {
        let dir = PathBuf::from(format!("/tmp/ko-leaks-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        (dir.clone(), Leaks::new(&dir))
    }

    fn object(suffix: &str) -> (Name, Named) {
        let name = Name::new(&format!("/ko-l-{}-{suffix}", std::process::id())).unwrap();
        let object = Named::create(&name, 16).unwrap();
        (name, object)
    }

    fn key(frame: u32) -> ImageKey {
        ImageKey {
            image: 7,
            frame,
            generation: 99,
        }
    }

    #[test]
    fn a_recorded_object_is_unlinked_by_its_pane_by_its_name_or_by_the_sweep() {
        let (dir, leaks) = scratch();
        let (first, _a) = object("a");
        let (second, _b) = object("b");
        let (third, _c) = object("c");
        let pane = PaneId::new(1);
        leaks.record(pane, key(1), &first).unwrap();
        leaks.record(pane, key(2), &second).unwrap();
        leaks.record(PaneId::new(2), key(1), &third).unwrap();
        assert_eq!(leaks.read().len(), 3);
        let exists = |name: &Name| Named::open(name, 16).is_ok();

        leaks.gone(&first);
        assert!(!exists(&first) && exists(&second) && exists(&third));
        assert_eq!(leaks.read().len(), 2);

        leaks.release_pane(pane);
        assert!(!exists(&second) && exists(&third));

        let fresh = Leaks::new(&dir);
        fresh.release_all();
        assert!(!exists(&third));
        assert!(!dir.join("shm").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_line_that_is_not_an_entry_is_dropped() {
        for bad in [
            "",
            "pane_1 7 1 99",
            "pane_1 7 1 99 /a/b",
            "x 7 1 99 /ko-1-1",
            "pane_1 7 1 99 /ko-1-1 extra",
        ] {
            assert_eq!(Entry::parse(bad), None, "{bad}");
        }
        assert!(Entry::parse("pane_1 7 1 99 /ko-1-1").is_some());
    }
}

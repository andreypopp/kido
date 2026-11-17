use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use ko_wire::api::DropName;
use ko_wire::protocol::Dropped;

const MAX_BYTES: u64 = 2 << 30;
const MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const PARTIAL_AGE: Duration = Duration::from_secs(10 * 60);

#[derive(Debug)]
struct Partial(PathBuf);

impl Drop for Partial {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn sweep(root: &Path, now: SystemTime, mut before: impl FnMut(&Path)) -> io::Result<u64> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    };
    let mut kept = 0u64;
    for entry in entries {
        let scanned = (|| -> io::Result<u64> {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                return Ok(0);
            };
            let (id, partial) = name
                .strip_prefix('.')
                .map_or((name, false), |id| (id, true));
            if id.len() != 32
                || !id
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                || !entry.file_type()?.is_dir()
            {
                return Ok(0);
            }
            before(&entry.path());
            let mut files = fs::read_dir(entry.path())?;
            let file = files.next().transpose()?;
            if files.next().transpose()?.is_some() {
                return Ok(0);
            }
            let metadata = match file {
                Some(file) => {
                    let metadata = fs::symlink_metadata(file.path())?;
                    if !metadata.is_file() {
                        return Ok(0);
                    }
                    metadata
                }
                None if partial => entry.metadata()?,
                None => return Ok(0),
            };
            let age = now.duration_since(metadata.modified()?).unwrap_or_default();
            if age > if partial { PARTIAL_AGE } else { MAX_AGE } {
                fs::remove_dir_all(entry.path())?;
                Ok(0)
            } else {
                Ok(if metadata.is_file() {
                    metadata.len()
                } else {
                    0
                })
            }
        })();
        match scanned {
            Ok(bytes) => kept = kept.checked_add(bytes).ok_or(io::ErrorKind::InvalidData)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(kept)
}

pub fn receive(
    base: &Path,
    name: DropName,
    size: u64,
    mut read: impl FnMut(&mut [u8]) -> io::Result<usize>,
) -> io::Result<Dropped> {
    if !base.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "base must be absolute",
        ));
    }
    let root = base.join("drops");
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&root)?;
    if !fs::symlink_metadata(&root)?.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "drops is not a directory",
        ));
    }
    let kept = sweep(&root, SystemTime::now(), |_| {})?;
    if kept.checked_add(size).is_none_or(|total| total > MAX_BYTES) {
        return Err(io::Error::new(
            io::ErrorKind::StorageFull,
            "drops exceed 2 GiB",
        ));
    }
    let id = ko_sys::entropy::hex(16)?;
    let partial = Partial(root.join(format!(".{id}")));
    DirBuilder::new().mode(0o700).create(&partial.0)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(partial.0.join(name.as_str()))?;
    let mut remaining = size;
    let mut buffer = [0u8; 65536];
    while remaining > 0 {
        let wanted = usize::try_from(remaining)
            .unwrap_or(usize::MAX)
            .min(buffer.len());
        let count = read(
            buffer
                .get_mut(..wanted)
                .ok_or(io::ErrorKind::InvalidInput)?,
        )?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "input is shorter than size",
            ));
        }
        file.write_all(buffer.get(..count).ok_or(io::ErrorKind::InvalidData)?)?;
        remaining = remaining
            .checked_sub(count as u64)
            .ok_or(io::ErrorKind::InvalidData)?;
    }
    if read(&mut buffer[..1])? != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "input is longer than size",
        ));
    }
    let complete = root.join(id);
    let path = complete
        .join(name.as_str())
        .to_str()
        .ok_or(io::ErrorKind::InvalidData)?
        .to_owned()
        .try_into()
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
    fs::rename(&partial.0, complete)?;
    Ok(Dropped { path })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Read};
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn concurrent_sweep_tolerates_an_entry_removed_after_listing() {
        let base =
            std::env::temp_dir().join(format!("ko-drop-race-{}", ko_sys::entropy::hex(8).unwrap()));
        fs::create_dir_all(base.join(".0123456789abcdef0123456789abcdef")).unwrap();
        assert_eq!(
            sweep(&base, SystemTime::now(), |path| fs::remove_dir_all(path)
                .unwrap())
            .unwrap(),
            0
        );
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn foreign_entries_do_not_block_or_change_during_an_upload() {
        let base = std::env::temp_dir().join(format!(
            "ko-drop-foreign-{}",
            ko_sys::entropy::hex(8).unwrap()
        ));
        let root = base.join("drops");
        fs::create_dir_all(root.join("odd")).unwrap();
        fs::write(root.join("unrelated"), b"keep").unwrap();
        symlink("/dev/null", root.join("link")).unwrap();
        let name = DropName::try_from("file".to_owned()).unwrap();
        let result = receive(&base, name, 0, |_| Ok(0)).unwrap();
        assert!(Path::new(result.path.as_str()).exists());
        assert_eq!(fs::read(root.join("unrelated")).unwrap(), b"keep");
        assert!(
            fs::symlink_metadata(root.join("link"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(root.join("odd").is_dir());
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn drops_require_exact_input_and_private_regular_files_and_enforce_quota() {
        let base =
            std::env::temp_dir().join(format!("ko-drop-{}", ko_sys::entropy::hex(8).unwrap()));
        let name = || DropName::try_from("file".to_owned()).unwrap();
        for (size, bytes) in [(3, b"ab".as_slice()), (1, b"ab".as_slice())] {
            let mut reader = Cursor::new(bytes);
            let failure = receive(&base, name(), size, |buffer| reader.read(buffer)).unwrap_err();
            assert_eq!(
                failure.kind(),
                if size == 3 {
                    io::ErrorKind::UnexpectedEof
                } else {
                    io::ErrorKind::InvalidData
                }
            );
            assert_eq!(fs::read_dir(base.join("drops")).unwrap().count(), 0);
        }
        for bytes in [b"".as_slice(), b"abcdef".as_slice()] {
            let mut reader = Cursor::new(bytes);
            let result = receive(&base, name(), bytes.len() as u64, |buffer| {
                reader.read(buffer)
            })
            .unwrap();
            let path = Path::new(result.path.as_str());
            assert_eq!(fs::read(path).unwrap(), bytes);
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(path.parent().unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
        }
        assert!(receive(&base, name(), MAX_BYTES - 5, |_| Ok(0)).is_err());
        let stale = base.join("drops/.0123456789abcdef0123456789abcdef");
        fs::create_dir(&stale).unwrap();
        fs::write(stale.join("file"), b"stale").unwrap();
        let now = SystemTime::now();
        assert_eq!(
            sweep(
                &base.join("drops"),
                now + PARTIAL_AGE + Duration::from_secs(1),
                |_| {},
            )
            .unwrap(),
            6
        );
        assert!(!stale.exists());
        assert_eq!(
            sweep(
                &base.join("drops"),
                now + MAX_AGE + Duration::from_secs(1),
                |_| {}
            )
            .unwrap(),
            0
        );
        let bad = base.join("drops/0123456789abcdef0123456789abcdef");
        fs::create_dir(&bad).unwrap();
        symlink("/dev/null", bad.join("file")).unwrap();
        assert!(receive(&base, name(), 0, |_| Ok(0)).is_ok());
        assert!(
            fs::symlink_metadata(bad.join("file"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        fs::remove_dir_all(&base).unwrap();
        fs::create_dir(&base).unwrap();
        symlink(&base, base.join("drops")).unwrap();
        assert!(receive(&base, name(), 0, |_| Ok(0)).is_err());
        fs::remove_dir_all(base).unwrap();
    }
}

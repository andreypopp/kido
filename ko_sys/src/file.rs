use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

pub fn unlinked(dir: &Path, prefix: &str) -> io::Result<File> {
    let path = dir.join(format!(".{prefix}-{}", crate::entropy::hex(8)?));
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)?;
    std::fs::remove_file(&path)?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{FileExt, MetadataExt};

    use super::*;

    #[test]
    fn an_unlinked_file_is_private_and_leaves_no_name_behind() {
        let dir = std::env::temp_dir().join(format!("ko-file-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = unlinked(&dir, "test").unwrap();
        file.write_all_at(b"spilled", 3).unwrap();
        let mut back = [0; 7];
        file.read_exact_at(&mut back, 3).unwrap();
        assert_eq!(&back, b"spilled");
        assert_eq!(file.metadata().unwrap().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        std::fs::remove_dir(&dir).unwrap();
    }
}

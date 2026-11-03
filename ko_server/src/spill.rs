use std::collections::VecDeque;
use std::fs::File;
use std::io;
use std::os::unix::fs::FileExt;
use std::path::Path;

#[derive(Debug)]
pub(crate) struct Spill {
    file: File,
    limit: u64,
    end: u64,
    read: u64,
    lens: VecDeque<usize>,
}

impl Spill {
    pub(crate) fn create(dir: &Path, limit: u64) -> io::Result<Spill> {
        Ok(Spill {
            file: ko_sys::file::unlinked(dir, "ko-spill")?,
            limit,
            end: 0,
            read: 0,
            lens: VecDeque::new(),
        })
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.lens.is_empty()
    }

    pub(crate) fn push(&mut self, parts: &[&[u8]]) -> io::Result<()> {
        let len: usize = parts.iter().map(|part| part.len()).sum();
        let total = self.end.saturating_add(len as u64);
        if total > self.limit {
            return Err(io::Error::other("spill limit"));
        }
        let mut at = self.end;
        for part in parts {
            self.file.write_all_at(part, at)?;
            at = at.saturating_add(part.len() as u64);
        }
        self.end = total;
        self.lens.push_back(len);
        Ok(())
    }

    // The messages in order, at least one, and no more bytes than the budget unless the first
    // message alone is larger.
    pub(crate) fn take(&mut self, budget: usize) -> io::Result<Vec<Vec<u8>>> {
        let mut messages = Vec::new();
        let mut taken = 0;
        while let Some(&len) = self.lens.front() {
            if taken > 0 && taken + len > budget {
                break;
            }
            let mut bytes = vec![0; len];
            self.file.read_exact_at(&mut bytes, self.read)?;
            self.read = self.read.saturating_add(len as u64);
            self.lens.pop_front();
            taken += len;
            messages.push(bytes);
        }
        Ok(messages)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_come_back_whole_in_order_within_a_budget_and_a_limit_refuses_the_rest() {
        let dir = crate::server::tests::scratch("spill");
        let mut spill = Spill::create(&dir, 20).unwrap();
        spill.push(&[b"one", b"-1"]).unwrap();
        spill.push(&[b"two"]).unwrap();
        spill.push(&[b"three"]).unwrap();
        assert!(spill.push(&[&[0; 8]]).is_err());
        assert_eq!(spill.take(9).unwrap(), [b"one-1".to_vec(), b"two".to_vec()]);
        assert_eq!(spill.take(1).unwrap(), [b"three".to_vec()]);
        assert!(spill.is_empty());
        std::fs::remove_dir(&dir).unwrap();
    }
}

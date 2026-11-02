use super::{Identity, Pid};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Stat {
    pub(super) zombie: bool,
    pub(super) identity: Identity,
}

// comm, the second field, is in parentheses and may hold spaces, parentheses and bytes that are
// not UTF-8: the fields that follow start after the last ')'. They start with field 3 of
// proc_pid_stat(5), the state.
fn parse(text: &[u8]) -> Option<Stat> {
    let close = text.iter().rposition(|&byte| byte == b')')?;
    let mut fields = std::str::from_utf8(text.get(close + 1..)?)
        .ok()?
        .split_whitespace();
    let state = fields.next()?;
    let ppid = fields.next()?.parse().ok()?;
    let pgid = fields.next()?.parse().ok()?;
    let sid = fields.next()?.parse().ok()?;
    Some(Stat {
        zombie: state == "Z" || state == "X",
        identity: Identity {
            ppid,
            pgid,
            sid,
            // field 22, after tty_nr to itrealvalue
            start: fields.nth(15)?.parse().ok()?,
        },
    })
}

pub(super) fn read(pid: Pid) -> Option<Stat> {
    parse(&std::fs::read(format!("/proc/{pid}/stat")).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TAIL: &str =
        "S 4242 900 901 34816 900 4194304 100 0 0 0 1 2 0 0 20 0 1 0 987654 1000 100";

    #[test]
    fn the_fields_follow_the_last_parenthesis_of_a_comm_with_spaces_and_parentheses() {
        for comm in [
            &b"sleep"[..],
            b"a b",
            b"x) 1 2 3 (y",
            b"(",
            b"))",
            b"\xff\xfe",
            b"caf\xc3",
        ] {
            let text = [b"777 (", comm, b") ", TAIL.as_bytes(), b"\n"].concat();
            let stat = parse(&text).unwrap();
            assert_eq!(
                stat.identity,
                Identity {
                    ppid: 4242,
                    pgid: 900,
                    sid: 901,
                    start: 987_654
                },
                "{comm:?}"
            );
            assert!(!stat.zombie);
        }
        assert!(
            parse(format!("777 (z) Z{}", &TAIL[1..]).as_bytes())
                .unwrap()
                .zombie
        );
        assert_eq!(parse(b"777 (short) S 1 2"), None);
        assert_eq!(parse(b"no parenthesis"), None);
    }

    #[test]
    fn this_process_reads_back_its_own_identity() {
        let own = Pid(libc::pid_t::try_from(std::process::id()).unwrap());
        let stat = read(own).unwrap();
        // SAFETY: getppid and getpgrp have no preconditions.
        let (parent, group) = unsafe { (libc::getppid(), libc::getpgrp()) };
        assert_eq!(stat.identity.ppid, parent);
        assert_eq!(stat.identity.pgid, group);
        assert!(!stat.zombie);
    }
}

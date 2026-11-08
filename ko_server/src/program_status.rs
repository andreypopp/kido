use ko_sys::clock::Mono;

use crate::protocol::{ProgramRecord, ProgramState, ProgramStatus, StatusReport};

const MAX_RECORDS: usize = 64;

#[derive(Debug, Default)]
pub(crate) struct Set {
    serial: u64,
    records: Vec<ProgramRecord>,
}

fn final_state(record: &ProgramRecord) -> bool {
    matches!(record.state, ProgramState::Done | ProgramState::Error)
}

impl Set {
    fn changed(&mut self) -> bool {
        self.serial = self.serial.saturating_add(1);
        true
    }

    fn remove(&mut self, keep: impl Fn(&ProgramRecord) -> bool) -> bool {
        let before = self.records.len();
        self.records.retain(keep);
        self.records.len() != before && self.changed()
    }

    pub(crate) fn apply(&mut self, report: StatusReport, now: Mono) -> bool {
        let report = match report {
            StatusReport::Clear { id } => {
                return self.remove(|record| !record.id.is_within(&id));
            }
            StatusReport::Set { record } => record,
        };
        let id = report.id;
        let stored = self.records.iter().position(|record| record.id == id);
        let started = if id.is_root() {
            None
        } else {
            stored
                .and_then(|index| self.records.get(index).and_then(|record| record.started))
                .or(Some(now.nanos()))
        };
        let record = ProgramRecord {
            id,
            state: report.state,
            app: report.app.map(String::from),
            title: report.title.map(String::from),
            msg: report.msg.map(String::from),
            started,
        };
        if let Some(index) = stored {
            if self.records.get(index) == Some(&record) {
                return false;
            }
            self.records.remove(index);
        }
        if self.records.len() >= MAX_RECORDS {
            self.records.remove(0);
        }
        self.records.push(record);
        self.changed()
    }

    pub(crate) fn prompt_start(&mut self) -> bool {
        self.remove(final_state)
    }

    pub(crate) fn clear(&mut self) -> bool {
        self.remove(|_| false)
    }

    pub(crate) fn published(&self) -> ProgramStatus {
        let mut records: Vec<ProgramRecord> = self
            .records
            .iter()
            .filter(|record| {
                !matches!(
                    record,
                    ProgramRecord {
                        state: ProgramState::Working { progress: Some(progress) },
                        app: None,
                        title: None,
                        msg: None,
                        ..
                    } if u8::from(*progress) == 0
                )
            })
            .cloned()
            .collect();
        records.sort_by(|a, b| a.id.cmp(&b.id));
        ProgramStatus {
            serial: self.serial,
            records,
        }
    }
}

pub(crate) fn root(records: &[ProgramRecord]) -> Option<&ProgramRecord> {
    records.iter().find(|record| record.id.is_root())
}

pub(crate) fn app<'a>(records: &'a [ProgramRecord], record: &ProgramRecord) -> Option<&'a str> {
    let mut id = record.id.as_str();
    loop {
        if let Some(app) = records
            .iter()
            .find(|found| found.id.as_str() == id)
            .and_then(|found| found.app.as_deref())
        {
            return Some(app);
        }
        if id.is_empty() {
            return None;
        }
        id = id.rfind('/').map_or("", |at| id.get(..at).unwrap_or(""));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(id: &str, state: ProgramState, app: &str) -> StatusReport {
        StatusReport::Set {
            record: crate::protocol::StatusRecord {
                id: id.to_owned().try_into().unwrap(),
                state,
                app: (!app.is_empty()).then(|| app.to_owned().try_into().unwrap()),
                title: None,
                msg: None,
            },
        }
    }

    #[test]
    fn record_start_is_owned_by_the_set() {
        let mut found = Set::default();
        found.apply(set("", ProgramState::Idle, "pi"), Mono::from_nanos(1));
        assert_eq!(found.published().records[0].started, None);
        found.apply(working("job/1", 1), Mono::from_nanos(2));
        assert_eq!(found.published().records[1].started, Some(2));
        assert!(!found.apply(working("job/1", 1), Mono::from_nanos(3)));
        found.apply(working("job/1", 2), Mono::from_nanos(4));
        assert_eq!(found.published().records[1].started, Some(2));
        found.apply(clear("job/1"), Mono::from_nanos(5));
        found.apply(working("job/1", 3), Mono::from_nanos(6));
        assert_eq!(found.published().records[1].started, Some(6));
        found.clear();
        found.apply(working("job/1", 4), Mono::from_nanos(7));
        assert_eq!(found.published().records[0].started, Some(7));
    }

    fn clear(id: &str) -> StatusReport {
        StatusReport::Clear {
            id: id.to_owned().try_into().unwrap(),
        }
    }

    fn working(id: &str, progress: u8) -> StatusReport {
        set(
            id,
            ProgramState::Working {
                progress: Some(progress.try_into().unwrap()),
            },
            "",
        )
    }

    fn ids(set: &Set) -> Vec<String> {
        set.published()
            .records
            .into_iter()
            .map(|record| String::from(record.id))
            .collect()
    }

    fn set_of(records: &[(&str, &str)]) -> Set {
        let mut found = Set::default();
        for (id, app) in records {
            found.apply(set(id, ProgramState::Idle, app), Mono::from_nanos(1));
        }
        found
    }

    #[test]
    fn sixty_five_records_evict_the_oldest_updated_and_an_identical_report_moves_nothing() {
        let mut found = Set::default();
        for index in 0..64 {
            assert!(found.apply(working(&format!("r{index:02}"), 1), Mono::from_nanos(1)));
        }
        assert!(!found.apply(working("r00", 1), Mono::from_nanos(1)));
        assert_eq!(found.published().serial, 64);
        assert!(found.apply(working("r01", 2), Mono::from_nanos(1)));
        assert!(found.apply(working("new", 1), Mono::from_nanos(1)));
        let published = ids(&found);
        assert_eq!(published.len(), 64);
        assert!(!published.contains(&"r00".to_owned()));
        assert!(published.contains(&"r01".to_owned()));
        assert!(found.apply(working("another", 1), Mono::from_nanos(1)));
        assert!(!ids(&found).contains(&"r02".to_owned()));
        assert!(ids(&found).contains(&"r01".to_owned()));
    }

    #[test]
    fn a_clear_removes_the_record_and_its_children_and_not_a_sibling_with_the_same_prefix() {
        let mut found = set_of(&[("x", ""), ("x/y", ""), ("xy", ""), ("", "")]);
        let serial = found.published().serial;
        assert!(!found.apply(clear("none"), Mono::from_nanos(1)));
        assert_eq!(found.published().serial, serial);
        assert!(found.apply(clear("x"), Mono::from_nanos(1)));
        assert_eq!(ids(&found), ["", "xy"]);
        assert!(found.apply(clear(""), Mono::from_nanos(1)));
        assert!(ids(&found).is_empty());
        assert!(!found.clear());
    }

    #[test]
    fn a_prompt_start_keeps_only_the_final_records() {
        let mut found = Set::default();
        found.apply(working("a", 3), Mono::from_nanos(1));
        found.apply(set("b", ProgramState::Done, ""), Mono::from_nanos(1));
        found.apply(set("c", ProgramState::Error, ""), Mono::from_nanos(1));
        found.apply(set("d", ProgramState::Idle, ""), Mono::from_nanos(1));
        assert!(found.prompt_start());
        assert_eq!(ids(&found), ["b", "c"]);
        assert!(!found.prompt_start());
    }

    #[test]
    fn bare_zero_progress_sets_no_status() {
        let mut found = Set::default();
        found.apply(working("bare", 0), Mono::from_nanos(1));
        found.apply(
            StatusReport::Set {
                record: crate::protocol::StatusRecord {
                    msg: Some("A".to_owned().try_into().unwrap()),
                    ..match working("msg", 0) {
                        StatusReport::Set { record } => record,
                        StatusReport::Clear { .. } => unreachable!(),
                    }
                },
            },
            Mono::from_nanos(1),
        );
        found.apply(
            set(
                "app",
                ProgramState::Working {
                    progress: Some(0.try_into().unwrap()),
                },
                "tool",
            ),
            Mono::from_nanos(1),
        );
        found.apply(working("one", 1), Mono::from_nanos(1));
        found.apply(set("idle", ProgramState::Idle, ""), Mono::from_nanos(1));
        assert_eq!(ids(&found), ["app", "idle", "msg", "one"]);
    }

    #[test]
    fn the_app_comes_from_the_nearest_ancestor_that_has_one() {
        let found = set_of(&[("", "root"), ("a", "nearest"), ("a/b/c", ""), ("z", "")]);
        let published = found.published();
        let apps: Vec<(&str, Option<&str>)> = published
            .records
            .iter()
            .map(|record| (record.id.as_str(), app(&published.records, record)))
            .collect();
        assert_eq!(
            apps,
            [
                ("", Some("root")),
                ("a", Some("nearest")),
                ("a/b/c", Some("nearest")),
                ("z", Some("root")),
            ]
        );
    }
}

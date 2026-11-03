use crate::protocol::{ProgramRecord, ProgramState, ProgramStatus};

const MAX_RECORDS: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Report {
    Clear { id: String },
    Set(ProgramRecord),
}

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

    pub(crate) fn apply(&mut self, report: Report) -> bool {
        let record = match report {
            Report::Clear { id } if id.is_empty() => return self.clear(),
            Report::Clear { id } => {
                let child = format!("{id}/");
                return self.remove(|record| record.id != id && !record.id.starts_with(&child));
            }
            Report::Set(record) => record,
        };
        if self.records.contains(&record) {
            return false;
        }
        self.records.retain(|stored| stored.id != record.id);
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
                        state: ProgramState::Working { progress: Some(0) },
                        app: None,
                        title: None,
                        msg: None,
                        ..
                    }
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
    records.iter().find(|record| record.id.is_empty())
}

pub(crate) fn app<'a>(records: &'a [ProgramRecord], record: &ProgramRecord) -> Option<&'a str> {
    let mut id = record.id.as_str();
    loop {
        if let Some(app) = records
            .iter()
            .find(|found| found.id == id)
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

    fn set(id: &str, state: ProgramState, app: &str) -> Report {
        Report::Set(ProgramRecord {
            id: id.to_owned(),
            state,
            app: (!app.is_empty()).then(|| app.to_owned()),
            title: None,
            msg: None,
        })
    }

    fn clear(id: &str) -> Report {
        Report::Clear { id: id.to_owned() }
    }

    fn working(id: &str, progress: u8) -> Report {
        set(
            id,
            ProgramState::Working {
                progress: Some(progress),
            },
            "",
        )
    }

    fn ids(set: &Set) -> Vec<String> {
        set.published()
            .records
            .into_iter()
            .map(|record| record.id)
            .collect()
    }

    fn set_of(records: &[(&str, &str)]) -> Set {
        let mut found = Set::default();
        for (id, app) in records {
            found.apply(set(id, ProgramState::Idle, app));
        }
        found
    }

    #[test]
    fn sixty_five_records_evict_the_oldest_updated_and_an_identical_report_moves_nothing() {
        let mut found = Set::default();
        for index in 0..64 {
            assert!(found.apply(working(&format!("r{index:02}"), 1)));
        }
        assert!(!found.apply(working("r00", 1)));
        assert_eq!(found.published().serial, 64);
        assert!(found.apply(working("r01", 2)));
        assert!(found.apply(working("new", 1)));
        let published = ids(&found);
        assert_eq!(published.len(), 64);
        assert!(!published.contains(&"r00".to_owned()));
        assert!(published.contains(&"r01".to_owned()));
        assert!(found.apply(working("another", 1)));
        assert!(!ids(&found).contains(&"r02".to_owned()));
        assert!(ids(&found).contains(&"r01".to_owned()));
    }

    #[test]
    fn a_clear_removes_the_record_and_its_children_and_not_a_sibling_with_the_same_prefix() {
        let mut found = set_of(&[("x", ""), ("x/y", ""), ("xy", ""), ("", "")]);
        let serial = found.published().serial;
        assert!(!found.apply(clear("none")));
        assert_eq!(found.published().serial, serial);
        assert!(found.apply(clear("x")));
        assert_eq!(ids(&found), ["", "xy"]);
        assert!(found.apply(clear("")));
        assert!(ids(&found).is_empty());
        assert!(!found.clear());
    }

    #[test]
    fn a_prompt_start_keeps_only_the_final_records() {
        let mut found = Set::default();
        found.apply(working("a", 3));
        found.apply(set("b", ProgramState::Done, ""));
        found.apply(set("c", ProgramState::Error, ""));
        found.apply(set("d", ProgramState::Idle, ""));
        assert!(found.prompt_start());
        assert_eq!(ids(&found), ["b", "c"]);
        assert!(!found.prompt_start());
    }

    #[test]
    fn bare_zero_progress_sets_no_status() {
        let mut found = Set::default();
        found.apply(working("bare", 0));
        found.apply(Report::Set(ProgramRecord {
            msg: Some("A".to_owned()),
            ..match working("msg", 0) {
                Report::Set(record) => record,
                Report::Clear { .. } => unreachable!(),
            }
        }));
        found.apply(set(
            "app",
            ProgramState::Working { progress: Some(0) },
            "tool",
        ));
        found.apply(working("one", 1));
        found.apply(set("idle", ProgramState::Idle, ""));
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

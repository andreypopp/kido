use ko_sys::clock::Mono;

use ko_wire::ids::StatusId;
use ko_wire::protocol::{
    Foreground, MAX_STATUS_RECORDS, ProgramRecord, ProgramState, ProgramStatus, StatusRecord,
    StatusReport,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CapacityExceeded;

fn convert(report: StatusRecord, started: Option<u64>) -> ProgramRecord {
    ProgramRecord {
        id: report.id,
        state: report.state,
        app: report.app.map(String::from),
        title: report.title.map(String::from),
        msg: report.msg.map(String::from),
        started,
        selection: report.selection,
        closeable: report.closeable,
        promptable: report.promptable,
    }
}

#[derive(Debug, Default)]
pub(crate) struct Set {
    serial: u64,
    records: Vec<ProgramRecord>,
    owner: Option<Foreground>,
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
        let removed = self.records.len() != before;
        self.unbind_without_root();
        removed && self.changed()
    }

    fn unbind_without_root(&mut self) {
        if root(&self.records).is_none() {
            self.owner = None;
        }
    }

    pub(crate) fn apply(
        &mut self,
        report: StatusReport,
        now: Mono,
        foreground: Option<&Foreground>,
    ) -> Result<bool, CapacityExceeded> {
        let report = match report {
            StatusReport::Clear { id } => {
                return Ok(self.remove(|record| !record.id.is_within(&id)));
            }
            StatusReport::ReplaceSubtrees { replacement } => {
                let owned = |record: &ProgramRecord| {
                    replacement
                        .roots()
                        .iter()
                        .any(|root| record.id.is_within(root))
                };
                let preserved = self.records.iter().filter(|record| !owned(record)).count();
                if preserved + replacement.records().len() > MAX_STATUS_RECORDS {
                    return Err(CapacityExceeded);
                }
                let mut updates: Vec<_> = replacement
                    .records()
                    .iter()
                    .map(|report| {
                        let started = self
                            .records
                            .iter()
                            .find(|old| old.id == report.id)
                            .and_then(|old| old.started)
                            .or(Some(now.nanos()));
                        convert(report.clone(), started)
                    })
                    .collect();
                let mut candidate = Vec::with_capacity(preserved + updates.len());
                for old in &self.records {
                    if !owned(old) {
                        candidate.push(old.clone());
                    } else if let Some(index) = updates.iter().position(|new| new == old) {
                        candidate.push(updates.remove(index));
                    }
                }
                updates.sort_by(|a, b| a.id.cmp(&b.id));
                candidate.extend(updates);
                if candidate == self.records {
                    return Ok(false);
                }
                self.records = candidate;
                return Ok(self.changed());
            }
            StatusReport::Set { record } => record,
        };
        let id = &report.id;
        let rebound = id.is_root() && self.owner.as_ref() != foreground;
        if id.is_root() {
            self.owner = foreground.cloned();
        }
        let stored = self.records.iter().position(|record| &record.id == id);
        let started = if id.is_root() {
            None
        } else {
            stored
                .and_then(|index| self.records.get(index).and_then(|record| record.started))
                .or(Some(now.nanos()))
        };
        let record = convert(report, started);
        if let Some(index) = stored {
            if self.records.get(index) == Some(&record) {
                return Ok(rebound && self.changed());
            }
            self.records.remove(index);
        }
        if self.records.len() >= MAX_STATUS_RECORDS {
            self.records.remove(0);
        }
        self.records.push(record);
        self.unbind_without_root();
        Ok(self.changed())
    }

    pub(crate) fn prompt_start(&mut self) -> bool {
        let unbound = self.owner.take().is_some();
        self.remove(final_state) || (unbound && self.changed())
    }

    pub(crate) fn owned_app(&self, foreground: Option<&Foreground>) -> Option<&str> {
        self.owner
            .as_ref()
            .filter(|owner| Some(*owner) == foreground)?;
        root(&self.records).and_then(|record| app(&self.records, record))
    }

    pub(crate) fn clear(&mut self) -> bool {
        self.remove(|_| false)
    }

    pub(crate) fn promptable(&self, id: &StatusId) -> bool {
        self.records
            .iter()
            .any(|record| &record.id == id && record.promptable)
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
                        selection: None,
                        closeable: false,
                        promptable: false,
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

    fn fg(pid: u32, name: &str) -> Foreground {
        Foreground {
            pid,
            name: name.to_owned(),
        }
    }

    fn set(id: &str, state: ProgramState, app: &str) -> StatusReport {
        StatusReport::Set {
            record: ko_wire::protocol::StatusRecord {
                id: id.to_owned().try_into().unwrap(),
                state,
                app: (!app.is_empty()).then(|| app.to_owned().try_into().unwrap()),
                title: None,
                msg: None,
                selection: None,
                closeable: false,
                promptable: false,
            },
        }
    }

    #[test]
    fn replacements_are_atomic_and_keep_starts() {
        let mut found = set_of(&[("", "koa"), ("outside", ""), ("agents/a", "")]);
        let foreground = fg(2, "koa");
        found
            .apply(
                set("", ProgramState::Idle, "koa"),
                Mono::from_nanos(1),
                Some(&foreground),
            )
            .unwrap();
        let replace = |records: serde_json::Value| {
            ko_wire::protocol::decode::<StatusReport>(&serde_json::to_vec(&serde_json::json!({"type":"replace_subtrees","roots":["agents","jobs"],"records":records})).unwrap()).unwrap()
        };
        let body = serde_json::json!([
            {"id":"agents/a", "state":"working", "title":"new"},
            {"id":"agents/a/jobs/b", "state":"idle"}
        ]);
        let serial = found.serial;
        assert_eq!(
            found.apply(replace(body.clone()), Mono::from_nanos(3), None),
            Ok(true)
        );
        assert_eq!(found.serial, serial + 1);
        assert_eq!(found.owned_app(Some(&foreground)), Some("koa"));
        assert_eq!(
            found
                .published()
                .records
                .iter()
                .find(|r| r.id.as_str() == "agents/a")
                .unwrap()
                .started,
            Some(1)
        );
        assert_eq!(
            found
                .published()
                .records
                .iter()
                .find(|r| r.id.as_str() == "agents/a/jobs/b")
                .unwrap()
                .started,
            Some(3)
        );
        let before = found.records.clone();
        let mut reordered = body.as_array().unwrap().clone();
        reordered.reverse();
        assert_eq!(
            found.apply(
                replace(serde_json::json!(reordered)),
                Mono::from_nanos(4),
                None
            ),
            Ok(false)
        );
        assert_eq!(found.records, before);
        assert_eq!(found.serial, serial + 1);
        let full: Vec<_> = (0..64)
            .map(|i| serde_json::json!({"id":format!("jobs/j{i}"),"state":"idle"}))
            .collect();
        assert_eq!(
            found.apply(replace(serde_json::json!(full)), Mono::from_nanos(5), None),
            Err(CapacityExceeded)
        );
        assert_eq!(found.records, before);
        assert_eq!(found.serial, serial + 1);
        assert_eq!(found.owned_app(Some(&foreground)), Some("koa"));
        assert_eq!(
            found.apply(replace(serde_json::json!([])), Mono::from_nanos(6), None),
            Ok(true)
        );
        assert_eq!(ids(&found), ["", "outside"]);
        found
            .apply(replace(body), Mono::from_nanos(7), None)
            .unwrap();
        assert_eq!(
            found
                .published()
                .records
                .iter()
                .find(|r| r.id.as_str() == "agents/a")
                .unwrap()
                .started,
            Some(7)
        );
    }

    #[test]
    fn record_start_is_owned_by_the_set() {
        let mut found = Set::default();
        found
            .apply(set("", ProgramState::Idle, "pi"), Mono::from_nanos(1), None)
            .unwrap();
        assert_eq!(found.published().records[0].started, None);
        found
            .apply(working("job/1", 1), Mono::from_nanos(2), None)
            .unwrap();
        assert_eq!(found.published().records[1].started, Some(2));
        assert!(
            !found
                .apply(working("job/1", 1), Mono::from_nanos(3), None)
                .unwrap()
        );
        found
            .apply(working("job/1", 2), Mono::from_nanos(4), None)
            .unwrap();
        assert_eq!(found.published().records[1].started, Some(2));
        found
            .apply(clear("job/1"), Mono::from_nanos(5), None)
            .unwrap();
        found
            .apply(working("job/1", 3), Mono::from_nanos(6), None)
            .unwrap();
        assert_eq!(found.published().records[1].started, Some(6));
        found.clear();
        found
            .apply(working("job/1", 4), Mono::from_nanos(7), None)
            .unwrap();
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
            found
                .apply(set(id, ProgramState::Idle, app), Mono::from_nanos(1), None)
                .unwrap();
        }
        found
    }

    #[test]
    fn sixty_five_records_evict_the_oldest_updated_and_an_identical_report_moves_nothing() {
        let mut found = Set::default();
        for index in 0..64 {
            assert!(
                found
                    .apply(
                        working(&format!("r{index:02}"), 1),
                        Mono::from_nanos(1),
                        None
                    )
                    .unwrap()
            );
        }
        assert!(
            !found
                .apply(working("r00", 1), Mono::from_nanos(1), None)
                .unwrap()
        );
        assert_eq!(found.published().serial, 64);
        assert!(
            found
                .apply(working("r01", 2), Mono::from_nanos(1), None)
                .unwrap()
        );
        assert!(
            found
                .apply(working("new", 1), Mono::from_nanos(1), None)
                .unwrap()
        );
        let published = ids(&found);
        assert_eq!(published.len(), 64);
        assert!(!published.contains(&"r00".to_owned()));
        assert!(published.contains(&"r01".to_owned()));
        assert!(
            found
                .apply(working("another", 1), Mono::from_nanos(1), None)
                .unwrap()
        );
        assert!(!ids(&found).contains(&"r02".to_owned()));
        assert!(ids(&found).contains(&"r01".to_owned()));
    }

    #[test]
    fn a_clear_removes_the_record_and_its_children_and_not_a_sibling_with_the_same_prefix() {
        let mut found = set_of(&[("x", ""), ("x/y", ""), ("xy", ""), ("", "")]);
        let serial = found.published().serial;
        assert!(
            !found
                .apply(clear("none"), Mono::from_nanos(1), None)
                .unwrap()
        );
        assert_eq!(found.published().serial, serial);
        assert!(found.apply(clear("x"), Mono::from_nanos(1), None).unwrap());
        assert_eq!(ids(&found), ["", "xy"]);
        assert!(found.apply(clear(""), Mono::from_nanos(1), None).unwrap());
        assert!(ids(&found).is_empty());
        assert!(!found.clear());
    }

    #[test]
    fn a_prompt_start_keeps_only_the_final_records() {
        let mut found = Set::default();
        found
            .apply(working("a", 3), Mono::from_nanos(1), None)
            .unwrap();
        found
            .apply(set("b", ProgramState::Done, ""), Mono::from_nanos(1), None)
            .unwrap();
        found
            .apply(set("c", ProgramState::Error, ""), Mono::from_nanos(1), None)
            .unwrap();
        found
            .apply(set("d", ProgramState::Idle, ""), Mono::from_nanos(1), None)
            .unwrap();
        assert!(found.prompt_start());
        assert_eq!(ids(&found), ["b", "c"]);
        assert!(!found.prompt_start());
    }

    #[test]
    fn bare_zero_progress_sets_no_status() {
        let mut found = Set::default();
        found
            .apply(working("bare", 0), Mono::from_nanos(1), None)
            .unwrap();
        found
            .apply(
                StatusReport::Set {
                    record: ko_wire::protocol::StatusRecord {
                        msg: Some("A".to_owned().try_into().unwrap()),
                        ..match working("msg", 0) {
                            StatusReport::Set { record } => record,
                            StatusReport::Clear { .. } | StatusReport::ReplaceSubtrees { .. } => {
                                unreachable!()
                            }
                        }
                    },
                },
                Mono::from_nanos(1),
                None,
            )
            .unwrap();
        found
            .apply(
                set(
                    "app",
                    ProgramState::Working {
                        progress: Some(0.try_into().unwrap()),
                    },
                    "tool",
                ),
                Mono::from_nanos(1),
                None,
            )
            .unwrap();
        found
            .apply(
                StatusReport::Set {
                    record: ko_wire::protocol::StatusRecord {
                        selection: Some(ko_wire::protocol::RecordSelection::Offered),
                        ..match working("sel", 0) {
                            StatusReport::Set { record } => record,
                            StatusReport::Clear { .. } | StatusReport::ReplaceSubtrees { .. } => {
                                unreachable!()
                            }
                        }
                    },
                },
                Mono::from_nanos(1),
                None,
            )
            .unwrap();
        found
            .apply(working("one", 1), Mono::from_nanos(1), None)
            .unwrap();
        found
            .apply(
                set("idle", ProgramState::Idle, ""),
                Mono::from_nanos(1),
                None,
            )
            .unwrap();
        assert_eq!(ids(&found), ["app", "idle", "msg", "one", "sel"]);
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

    #[test]
    fn a_root_belongs_to_the_foreground_that_reported_it_until_a_prompt_or_a_clear() {
        let (shell, editor) = (fg(1, "zsh"), fg(2, "nvim"));
        let mut found = Set::default();
        let root = || set("", ProgramState::Idle, "pi");
        assert!(
            found
                .apply(root(), Mono::from_nanos(1), Some(&shell))
                .unwrap()
        );
        assert_eq!(found.owned_app(Some(&shell)), Some("pi"));
        assert_eq!(found.owned_app(Some(&editor)), None);
        assert_eq!(found.owned_app(None), None);
        assert!(
            found
                .apply(root(), Mono::from_nanos(2), Some(&editor))
                .unwrap()
        );
        assert_eq!(found.owned_app(Some(&editor)), Some("pi"));
        assert!(
            !found
                .apply(root(), Mono::from_nanos(3), Some(&editor))
                .unwrap()
        );
        assert!(found.prompt_start());
        assert_eq!(found.owned_app(Some(&editor)), None);
        assert!(!found.prompt_start());
        found
            .apply(root(), Mono::from_nanos(4), Some(&shell))
            .unwrap();
        found
            .apply(clear(""), Mono::from_nanos(5), Some(&shell))
            .unwrap();
        assert_eq!(found.owned_app(Some(&shell)), None);
        found
            .apply(root(), Mono::from_nanos(6), Some(&shell))
            .unwrap();
        assert!(found.clear());
        assert_eq!(found.owned_app(Some(&shell)), None);
        found.apply(root(), Mono::from_nanos(7), None).unwrap();
        assert_eq!(found.owned_app(None), None);
        assert_eq!(found.owned_app(Some(&shell)), None);
    }
}

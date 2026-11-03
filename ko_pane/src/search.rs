use ko_pane_wire::frame::{FromPane, Match, MatchesBuf, Req};
use ko_vt::Terminal;
use ko_vt::search::{Progress, Search};

use crate::io::Out;

const TICKS: usize = 256;
const BATCH: usize = 512;

#[derive(Debug)]
enum Stage {
    Scanning(Search),
    Sending { matches: Vec<Match>, sent: usize },
}

#[derive(Debug)]
pub(crate) struct Searching {
    pub(crate) req: Req,
    stage: Stage,
    batch: MatchesBuf,
}

impl Searching {
    pub(crate) fn start(vt: &mut Terminal, req: Req, needle: &[u8]) -> Option<Searching> {
        let stage = if needle.is_empty() {
            Stage::Sending {
                matches: Vec::new(),
                sent: 0,
            }
        } else {
            Stage::Scanning(vt.search(needle).ok()?)
        };
        Some(Searching {
            req,
            stage,
            batch: MatchesBuf::default(),
        })
    }

    pub(crate) fn step(&mut self, vt: &Terminal, out: &mut Out) -> bool {
        match &mut self.stage {
            Stage::Scanning(search) => {
                match search.step(TICKS) {
                    Ok(Progress::Complete) => match search.matches(vt) {
                        Ok(matches) => self.stage = Stage::Sending { matches, sent: 0 },
                        Err(_) => return self.finish(out),
                    },
                    Ok(Progress::Running | Progress::FeedRequired) => {}
                    Err(_) => return self.finish(out),
                }
                false
            }
            Stage::Sending { matches, sent } => {
                let rest = matches.get(*sent..).unwrap_or_default();
                let batch = rest.get(..BATCH).unwrap_or(rest);
                if batch.is_empty() {
                    return self.finish(out);
                }
                self.batch.set(batch);
                out.frame(&FromPane::Matches {
                    req: self.req,
                    matches: self.batch.view(),
                });
                *sent = sent.saturating_add(batch.len());
                false
            }
        }
    }

    fn finish(&self, out: &mut Out) -> bool {
        out.frame(&FromPane::SearchDone(self.req));
        true
    }
}

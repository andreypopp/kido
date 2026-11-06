use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use ko_server::diagnostics::{Cause, Event, InputSource};

#[derive(Debug)]
pub(crate) struct Log {
    path: PathBuf,
    cap: u64,
}

impl Log {
    pub(crate) fn open(dir: &Path, cap: u64) -> io::Result<Log> {
        let log = Log {
            path: dir.join("log"),
            cap,
        };
        log.redirect()?;
        Ok(log)
    }

    fn redirect(&self) -> io::Result<()> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&self.path)?;
        ko_sys::fd::onto_stderr(file.as_fd())
    }

    pub(crate) fn between_turns(&self, events: Vec<Event>) -> io::Result<()> {
        if events.is_empty() {
            return Ok(());
        }
        let at = timestamp(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(io::Error::other)?,
        );
        for event in events {
            let detail = match event {
                Event::Hello { client } => format!("client {client} hello"),
                Event::ClientClosed { client, cause } => {
                    format!("client {client} closed: {}", cause_name(cause))
                }
                Event::ViewOpened { pane, client } => {
                    format!("view of {pane} client={} opened", id(client))
                }
                Event::ViewClosed {
                    pane,
                    client,
                    cause,
                } => format!(
                    "view of {pane} client={} closed: {}",
                    id(client),
                    cause_name(cause)
                ),
                Event::Selected { client, selection } => format!(
                    "client {client} selected session={} window={} pane={}",
                    id(selection.session),
                    id(selection.window),
                    id(selection.pane)
                ),
                Event::Input {
                    pane,
                    source,
                    bytes,
                } => format!(
                    "input to {pane} source={} bytes={bytes}",
                    match source {
                        InputSource::View => "view",
                        InputSource::Http => "http",
                    }
                ),
            };
            let line = format!("{at} {detail}\n");
            let size = match fs::metadata(&self.path) {
                Ok(metadata) => metadata.len(),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    self.redirect()?;
                    0
                }
                Err(error) => return Err(error),
            };
            if size.saturating_add(line.len() as u64) > self.cap {
                fs::rename(&self.path, self.path.with_file_name("log.1"))?;
                self.redirect()?;
            }
            io::stderr().lock().write_all(line.as_bytes())?;
        }
        Ok(())
    }
}

fn id(value: Option<impl std::fmt::Display>) -> String {
    value.map_or_else(|| "none".to_owned(), |id| id.to_string())
}

fn cause_name(cause: Option<Cause>) -> &'static str {
    let Some(cause) = cause else {
        return "unknown";
    };
    match cause {
        Cause::Eof => "eof",
        Cause::Io => "io",
        Cause::PeerClosed => "peer closed",
        Cause::PingTimeout => "ping timeout",
        Cause::Stalled => "output stalled",
        Cause::Cap => "output cap",
        Cause::Overflow => "1013 overflow",
        Cause::Refused => "refused",
        Cause::Gone => "gone",
        Cause::ClientClosed => "client closed",
        Cause::Finished => "finished",
        Cause::MessageTooLarge => "message too large",
    }
}

fn timestamp(at: Duration) -> String {
    let seconds = at.as_secs();
    let days = seconds / 86400 + 719468;
    let era = days / 146097;
    let day_of_era = days % 146097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let march_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * march_month + 2) / 5 + 1;
    let month = if march_month < 10 {
        march_month + 3
    } else {
        march_month - 9
    };
    year += u64::from(month <= 2);
    let hour = seconds % 86400 / 3600;
    let minute = seconds % 3600 / 60;
    let second = seconds % 60;
    format!(
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{:03}Z",
        at.subsec_millis()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_are_utc_with_milliseconds_across_calendar_boundaries() {
        for (seconds, expected) in [
            (0, "1970-01-01T00:00:00.123Z"),
            (951782400, "2000-02-29T00:00:00.123Z"),
            (1709251199, "2024-02-29T23:59:59.123Z"),
            (1709251200, "2024-03-01T00:00:00.123Z"),
            (4107542400, "2100-03-01T00:00:00.123Z"),
        ] {
            assert_eq!(timestamp(Duration::new(seconds, 123_000_000)), expected);
        }
    }
}

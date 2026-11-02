use std::fmt;
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

const MICROS: i64 = 1_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Timestamp(i64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidTimestamp(String);

impl fmt::Display for InvalidTimestamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid timestamp {:?}", self.0)
    }
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let of_era = year.rem_euclid(400);
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let of_day = of_era * 365 + of_era / 4 - of_era / 100 + day_of_year;
    era * 146_097 + of_day - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let days = days + 719_468;
    let era = days.div_euclid(146_097);
    let of_era = days.rem_euclid(146_097);
    let of_year = (of_era - of_era / 1460 + of_era / 36_524 - of_era / 146_096) / 365;
    let day_of_year = of_era - (365 * of_year + of_year / 4 - of_year / 100);
    let shifted = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted + 2) / 5 + 1;
    let month = if shifted < 10 {
        shifted + 3
    } else {
        shifted - 9
    };
    let year = of_year + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

impl Timestamp {
    pub fn now() -> Timestamp {
        let since = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_micros());
        Timestamp(i64::try_from(since).unwrap_or(i64::MAX))
    }

    pub fn from_micros(micros: i64) -> Timestamp {
        Timestamp(micros)
    }

    pub fn unix_seconds(self) -> i64 {
        self.0.div_euclid(MICROS)
    }

    pub fn micros_since(self, earlier: Timestamp) -> i64 {
        self.0.saturating_sub(earlier.0)
    }
}

impl fmt::Display for Timestamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let seconds = self.0.div_euclid(MICROS);
        let fraction = self.0.rem_euclid(MICROS);
        let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
        let of_day = seconds.rem_euclid(86_400);
        write!(
            f,
            "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}",
            of_day / 3600,
            of_day % 3600 / 60,
            of_day % 60
        )?;
        if fraction != 0 {
            write!(f, ".{}", format!("{fraction:06}").trim_end_matches('0'))?;
        }
        f.write_str("Z")
    }
}

fn leap(year: i64) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

fn month_days(year: i64, month: i64) -> i64 {
    match month {
        2 if leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn digits(text: &str, from: usize, count: usize) -> Option<i64> {
    let part = text.get(from..from.checked_add(count)?)?;
    part.bytes()
        .all(|byte| byte.is_ascii_digit())
        .then(|| part.parse().ok())?
}

fn parse(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    let separators = [(4, b'-'), (7, b'-'), (10, b'T'), (13, b':'), (16, b':')];
    if separators
        .iter()
        .any(|(at, byte)| bytes.get(*at) != Some(byte))
    {
        return None;
    }
    let (year, month, day) = (
        digits(text, 0, 4)?,
        digits(text, 5, 2)?,
        digits(text, 8, 2)?,
    );
    let (hour, minute, second) = (
        digits(text, 11, 2)?,
        digits(text, 14, 2)?,
        digits(text, 17, 2)?,
    );
    if !(1..=12).contains(&month)
        || !(1..=month_days(year, month)).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let mut at = 19;
    let mut micros = 0;
    if bytes.get(at) == Some(&b'.') {
        let fraction = text.get(at + 1..)?;
        let count = fraction.bytes().take_while(u8::is_ascii_digit).count();
        if count == 0 {
            return None;
        }
        let kept = fraction.get(..count.min(6))?;
        micros = format!("{kept:0<6}").parse().ok()?;
        at = at.checked_add(1)?.checked_add(count)?;
    }
    let zone = text.get(at..)?;
    let offset = if zone == "Z" {
        0
    } else {
        let sign = match zone.as_bytes().first()? {
            b'+' => 1,
            b'-' => -1,
            _ => return None,
        };
        if zone.len() != 6 || zone.as_bytes().get(3) != Some(&b':') {
            return None;
        }
        let (hours, minutes) = (digits(zone, 1, 2)?, digits(zone, 4, 2)?);
        if hours > 23 || minutes > 59 {
            return None;
        }
        sign * (hours * 60 + minutes)
    };
    let seconds = days_from_civil(year, month, day)
        .checked_mul(86_400)?
        .checked_add(hour * 3600 + minute * 60 + second)?
        .checked_sub(offset * 60)?;
    seconds.checked_mul(MICROS)?.checked_add(micros)
}

impl FromStr for Timestamp {
    type Err = InvalidTimestamp;

    fn from_str(text: &str) -> Result<Timestamp, InvalidTimestamp> {
        parse(text)
            .map(Timestamp)
            .ok_or_else(|| InvalidTimestamp(text.to_owned()))
    }
}

impl TryFrom<String> for Timestamp {
    type Error = InvalidTimestamp;

    fn try_from(text: String) -> Result<Timestamp, InvalidTimestamp> {
        text.parse()
    }
}

impl From<Timestamp> for String {
    fn from(timestamp: Timestamp) -> String {
        timestamp.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timestamp_prints_rfc_3339_in_utc_without_trailing_zeros() {
        assert_eq!(
            Timestamp(1_700_000_000 * MICROS).to_string(),
            "2023-11-14T22:13:20Z"
        );
        assert_eq!(
            Timestamp(1_700_000_000 * MICROS + 120_000).to_string(),
            "2023-11-14T22:13:20.12Z"
        );
        assert_eq!(Timestamp(0).to_string(), "1970-01-01T00:00:00Z");
        assert_eq!(Timestamp(-1).to_string(), "1969-12-31T23:59:59.999999Z");
    }

    #[test]
    fn a_timestamp_parses_a_zone_and_a_fraction() {
        let parse = |text: &str| text.parse::<Timestamp>().map(|stamp| stamp.0);
        assert_eq!(parse("2023-11-14T22:13:20Z"), Ok(1_700_000_000 * MICROS));
        assert!(parse("2024-02-29T00:00:00Z").is_ok());
        assert_eq!(
            parse("2023-11-15T00:13:20.5+02:00"),
            Ok(1_700_000_000 * MICROS + 500_000)
        );
        assert_eq!(
            parse("2023-11-14T20:43:20-01:30"),
            Ok(1_700_000_000 * MICROS)
        );
        for text in [
            "",
            "2023-11-14",
            "2023-13-14T22:13:20Z",
            "2023-11-14T22:13:20",
            "2023-11-14T22:13:20.Z",
            "2023-11-14 22:13:20Z",
        ] {
            assert_eq!(
                parse(text),
                Err(InvalidTimestamp(text.to_owned())),
                "{text}"
            );
        }
    }

    #[test]
    fn printing_and_parsing_agree_over_the_calendar() {
        for micros in (-5_000_000_000_000_000i64..8_000_000_000_000_000).step_by(98_765_432_123_457)
        {
            let stamp = Timestamp(micros);
            assert_eq!(stamp.to_string().parse(), Ok(stamp), "{micros}");
        }
    }
}

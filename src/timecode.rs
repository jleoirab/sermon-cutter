//! Timecodes as people type them: "1:23:05", "1:23:05.5", "83:05" or "4985".

use anyhow::{bail, Context, Result};

/// Parses a timecode into seconds.
///
/// Accepts `h:mm:ss`, `m:ss` (minutes may exceed 59 when there is no hour part)
/// and plain seconds, each with an optional fraction on the last part.
pub fn parse(s: &str) -> Result<f64> {
    let t = s.trim();
    if t.is_empty() {
        bail!("empty timecode");
    }
    let parts: Vec<&str> = t.split(':').collect();
    if parts.len() > 3 {
        bail!("timecode {t:?} has too many parts; use h:mm:ss");
    }
    let last = parts[parts.len() - 1];
    let secs: f64 = last
        .parse()
        .with_context(|| format!("bad seconds in timecode {t:?}"))?;
    if !(secs.is_finite() && secs >= 0.0) {
        bail!("bad seconds in timecode {t:?}");
    }
    let mut whole = Vec::new();
    for p in &parts[..parts.len() - 1] {
        if p.is_empty() || !p.chars().all(|c| c.is_ascii_digit()) {
            bail!("bad timecode {t:?}; use h:mm:ss");
        }
        whole.push(p.parse::<u64>()?);
    }
    if !whole.is_empty() && secs >= 60.0 {
        bail!("seconds must be under 60 in {t:?}");
    }
    let total = match whole.as_slice() {
        [] => secs,
        [m] => *m as f64 * 60.0 + secs,
        [h, m] => {
            if *m >= 60 {
                bail!("minutes must be under 60 in {t:?}");
            }
            *h as f64 * 3600.0 + *m as f64 * 60.0 + secs
        }
        _ => unreachable!(),
    };
    Ok(total)
}

/// Formats seconds as `h:mm:ss.mmm`.
pub fn format(secs: f64) -> String {
    let ms_total = (secs.max(0.0) * 1000.0).round() as u64;
    let (h, rem) = (ms_total / 3_600_000, ms_total % 3_600_000);
    let (m, rem) = (rem / 60_000, rem % 60_000);
    let (s, ms) = (rem / 1000, rem % 1000);
    format!("{h}:{m:02}:{s:02}.{ms:03}")
}

/// clap value parser.
pub fn parse_arg(s: &str) -> Result<f64, String> {
    parse(s).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_forms() {
        assert_eq!(parse("1:23:05").unwrap(), 4985.0);
        assert_eq!(parse("1:23:05.5").unwrap(), 4985.5);
        assert_eq!(parse("83:05").unwrap(), 4985.0);
        assert_eq!(parse("4985").unwrap(), 4985.0);
        assert_eq!(parse(" 2:35:00 ").unwrap(), 9300.0);
        assert_eq!(parse("0:00:00").unwrap(), 0.0);
    }

    #[test]
    fn rejects_nonsense() {
        for bad in [
            "", "1:2:3:4", "1:61:00", "1:00:60", "a:00", "-5", "1::00", "1:-2:00",
        ] {
            assert!(parse(bad).is_err(), "{bad:?} should fail");
        }
    }

    #[test]
    fn formats() {
        assert_eq!(format(4985.0), "1:23:05.000");
        assert_eq!(format(39.5), "0:00:39.500");
        assert_eq!(format(9300.0004), "2:35:00.000");
    }
}

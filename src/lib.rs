//! Sermon Cutter engine.
//!
//! The engine does all the processing for the Sermon Cutter apps: it fetches a
//! stream with yt-dlp, renders the cut with ffmpeg (banner overlay, dissolves,
//! audio fades) and checks the exported file. It only shells out to tools that
//! run on macOS and Windows alike, so a Windows app can drive the same engine.
//!
//! Apps run the `sermoncut` command-line tool and read one JSON object per line
//! from its standard output (see [`events`]).

pub mod encoders;
pub mod events;
pub mod fetch;
pub mod probe;
pub mod render;
pub mod run;
pub mod timecode;
pub mod timings;
pub mod tools;
pub mod verify;

/// Formats seconds for an ffmpeg option or filter argument: up to three decimals,
/// trailing zeros trimmed ("8", "8.5", "33.125").
pub fn num(x: f64) -> String {
    let s = format!("{:.3}", x);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "-0" {
        "0".to_string()
    } else {
        s.to_string()
    }
}

/// Parses a bitrate such as "6M", "6000k", "192k" or "6000000" into bits per second.
pub fn parse_bitrate(s: &str) -> Result<u64, String> {
    let t = s.trim();
    let (digits, mult) = match t.chars().last() {
        Some('M') | Some('m') => (&t[..t.len() - 1], 1_000_000.0),
        Some('K') | Some('k') => (&t[..t.len() - 1], 1_000.0),
        _ => (t, 1.0),
    };
    let v: f64 = digits
        .trim()
        .parse()
        .map_err(|_| format!("not a bitrate: {s:?} (try 6M or 6000k)"))?;
    if !(v.is_finite() && v > 0.0) {
        return Err(format!("bitrate must be positive: {s:?}"));
    }
    Ok((v * mult).round() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn num_trims_zeros() {
        assert_eq!(num(8.0), "8");
        assert_eq!(num(8.5), "8.5");
        assert_eq!(num(33.125), "33.125");
        assert_eq!(num(0.0), "0");
        assert_eq!(num(4985.0004), "4985");
    }

    #[test]
    fn bitrates() {
        assert_eq!(parse_bitrate("6M"), Ok(6_000_000));
        assert_eq!(parse_bitrate("6000k"), Ok(6_000_000));
        assert_eq!(parse_bitrate("192k"), Ok(192_000));
        assert_eq!(parse_bitrate("2.5M"), Ok(2_500_000));
        assert_eq!(parse_bitrate("800000"), Ok(800_000));
        assert!(parse_bitrate("fast").is_err());
        assert!(parse_bitrate("0").is_err());
    }
}

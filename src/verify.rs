//! Checking an exported sermon file before anyone uploads it.
//!
//! These are the same measurements used on the Oct 4 and Oct 11 reference
//! cuts: the file's length and format, the banner on the first and last frame,
//! footage in the middle, and near-silence in the first and last 100 ms.

use crate::render::banner_fit_chain;
use crate::tools::Tools;
use crate::{num, probe, run};
use anyhow::{bail, Result};
use serde::Serialize;
use std::ffi::OsString;
use std::path::Path;

pub const STEP: &str = "verify";

/// Banner frames must look at least this much like the banner (SSIM, 0 to 1).
pub const BANNER_MIN_SSIM: f64 = 0.90;
/// A mid-cut frame must look less like the banner than this.
pub const FOOTAGE_MAX_SSIM: f64 = 0.80;
/// The first and last 100 ms must be at or below this level.
pub const QUIET_MAX_DB: f64 = -40.0;

#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: String,
    pub passed: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub passed: bool,
    pub checks: Vec<Check>,
}

/// What the file should look like.
#[derive(Debug, Clone)]
pub struct Expect {
    pub duration: Option<f64>,
    pub width: u32,
    pub height: u32,
    pub banner_at_start: bool,
    pub banner_at_end: bool,
    pub quiet_start: bool,
    pub quiet_end: bool,
}

fn check(name: &str, passed: bool, detail: String) -> Check {
    Check {
        name: name.to_string(),
        passed,
        detail,
    }
}

pub fn verify(
    tools: &Tools,
    file: &Path,
    banner: Option<&Path>,
    expect: &Expect,
) -> Result<Report> {
    let ffmpeg = tools.ffmpeg()?;
    let info = probe::probe(tools.ffprobe()?, file)?;
    let mut checks = Vec::new();

    let (vcodec, w, h, fps) = info
        .video
        .as_ref()
        .map(|v| (v.codec.clone(), v.width, v.height, v.fps))
        .unwrap_or_else(|| ("none".into(), 0, 0, 30.0));
    let acodec = info
        .audio
        .as_ref()
        .map(|a| a.codec.clone())
        .unwrap_or_else(|| "none".into());
    checks.push(check(
        "format",
        vcodec == "h264" && acodec == "aac" && w == expect.width && h == expect.height,
        format!(
            "{vcodec} {w}x{h}, {acodec}; want h264 {}x{}, aac",
            expect.width, expect.height
        ),
    ));

    if let Some(want) = expect.duration {
        let tolerance = (2.0 / fps).max(0.1);
        let off = (info.duration - want).abs();
        checks.push(check(
            "length",
            off <= tolerance,
            format!(
                "{:.3} s; want {:.3} s within {:.2} s",
                info.duration, want, tolerance
            ),
        ));
    }

    if let Some(banner) = banner {
        if expect.banner_at_start {
            let s = ssim_at(ffmpeg, file, 0.0, banner, expect.width, expect.height)?;
            checks.push(check(
                "banner at start",
                s >= BANNER_MIN_SSIM,
                format!(
                    "first frame matches the banner at SSIM {s:.3}; want {BANNER_MIN_SSIM} or more"
                ),
            ));
        }
        if expect.banner_at_end {
            let at = (info.duration - 0.2).max(0.0);
            let s = ssim_at(ffmpeg, file, at, banner, expect.width, expect.height)?;
            checks.push(check(
                "banner at end",
                s >= BANNER_MIN_SSIM,
                format!("frame at {at:.1} s matches the banner at SSIM {s:.3}; want {BANNER_MIN_SSIM} or more"),
            ));
        }
        let mid = info.duration / 2.0;
        let s = ssim_at(ffmpeg, file, mid, banner, expect.width, expect.height)?;
        checks.push(check(
            "footage in the middle",
            s < FOOTAGE_MAX_SSIM,
            format!("frame at {mid:.1} s matches the banner at SSIM {s:.3}; want under {FOOTAGE_MAX_SSIM}"),
        ));
    }

    if expect.quiet_start {
        let db = rms_db(ffmpeg, file, Edge::Start, 0.1)?;
        checks.push(check(
            "quiet start",
            db <= QUIET_MAX_DB,
            format!(
                "first 100 ms at {} dBFS; want {QUIET_MAX_DB} or quieter",
                fmt_db(db)
            ),
        ));
    }
    if expect.quiet_end {
        let db = rms_db(ffmpeg, file, Edge::End, 0.1)?;
        checks.push(check(
            "quiet end",
            db <= QUIET_MAX_DB,
            format!(
                "last 100 ms at {} dBFS; want {QUIET_MAX_DB} or quieter",
                fmt_db(db)
            ),
        ));
    }

    Ok(Report {
        passed: checks.iter().all(|c| c.passed),
        checks,
    })
}

fn fmt_db(db: f64) -> String {
    if db.is_infinite() {
        "-inf".into()
    } else {
        format!("{db:.1}")
    }
}

/// How much the frame at `at` seconds looks like the banner (luma SSIM at 320x180).
pub fn ssim_at(ffmpeg: &Path, file: &Path, at: f64, banner: &Path, w: u32, h: u32) -> Result<f64> {
    let fit = banner_fit_chain("1:v", "b", "bfitted", w, h, "1", Some(1.0));
    let graph = format!(
        "[0:v]scale=320:180,format=gray[a];{fit};[bfitted]scale=320:180,format=gray[b];[a][b]ssim"
    );
    let mut args: Vec<OsString> = [
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "info",
        "-ss",
        &num(at),
        "-i",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    args.push(file.as_os_str().to_owned());
    args.push("-i".into());
    args.push(banner.as_os_str().to_owned());
    args.extend(
        [
            "-filter_complex",
            &graph,
            "-frames:v",
            "1",
            "-f",
            "null",
            "-",
        ]
        .iter()
        .map(OsString::from),
    );
    let out = run::capture(ffmpeg, &args)?;
    if !out.ok {
        bail!(
            "ffmpeg could not compare a frame with the banner: {}",
            run::tail(&out.stderr, 4)
        );
    }
    parse_ssim(&out.stderr)
        .ok_or_else(|| anyhow::anyhow!("no SSIM in ffmpeg output: {}", run::tail(&out.stderr, 3)))
}

/// Pulls the overall score out of ffmpeg's "SSIM Y:0.98 (17.1) All:0.98 (17.1)" line.
pub fn parse_ssim(stderr: &str) -> Option<f64> {
    stderr
        .lines()
        .filter(|l| l.contains("SSIM"))
        .filter_map(|l| l.split("All:").nth(1))
        .filter_map(|rest| rest.split_whitespace().next())
        .filter_map(|v| v.parse::<f64>().ok())
        .next_back()
}

#[derive(Clone, Copy)]
pub enum Edge {
    Start,
    End,
}

/// Overall RMS level, in dBFS, of the first or last `seconds` of audio.
pub fn rms_db(ffmpeg: &Path, file: &Path, edge: Edge, seconds: f64) -> Result<f64> {
    let mut args: Vec<OsString> = ["-hide_banner", "-nostdin", "-loglevel", "info"]
        .iter()
        .map(OsString::from)
        .collect();
    match edge {
        Edge::Start => args.extend(["-t", &num(seconds)].iter().map(OsString::from)),
        Edge::End => args.extend(
            ["-sseof", &format!("-{}", num(seconds))]
                .iter()
                .map(OsString::from),
        ),
    }
    args.push("-i".into());
    args.push(file.as_os_str().to_owned());
    args.extend(
        ["-vn", "-af", "astats", "-f", "null", "-"]
            .iter()
            .map(OsString::from),
    );
    let out = run::capture(ffmpeg, &args)?;
    if !out.ok {
        bail!(
            "ffmpeg could not measure the audio: {}",
            run::tail(&out.stderr, 4)
        );
    }
    parse_rms(&out.stderr).ok_or_else(|| anyhow::anyhow!("no RMS level in ffmpeg output"))
}

/// The last "RMS level dB:" value astats prints, which is the overall one.
pub fn parse_rms(stderr: &str) -> Option<f64> {
    stderr
        .lines()
        .filter_map(|l| l.split("RMS level dB:").nth(1))
        .filter_map(|v| v.trim().parse::<f64>().ok())
        .next_back()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssim_line() {
        let s = "[Parsed_ssim_9 @ 0x55] SSIM Y:0.991234 (20.57) All:0.991234 (20.57)\n";
        assert_eq!(parse_ssim(s), Some(0.991234));
        assert_eq!(parse_ssim("nothing here"), None);
    }

    #[test]
    fn rms_takes_the_overall_value() {
        let s = "[Parsed_astats_0 @ 0x1] Channel: 1\n[Parsed_astats_0 @ 0x1] RMS level dB: -50.0\n\
                 [Parsed_astats_0 @ 0x1] Overall\n[Parsed_astats_0 @ 0x1] RMS level dB: -52.5\n";
        assert_eq!(parse_rms(s), Some(-52.5));
        let silent =
            "[Parsed_astats_0 @ 0x1] Overall\n[Parsed_astats_0 @ 0x1] RMS level dB: -inf\n";
        assert_eq!(parse_rms(silent), Some(f64::NEG_INFINITY));
    }
}

//! Choosing an H.264 encoder that works on this computer.
//!
//! Hardware encoders come first: VideoToolbox on the Mac; NVENC, QuickSync or
//! AMF on Windows. x264 (software) is the fallback everywhere.

use crate::run;
use anyhow::{bail, Result};
use std::path::Path;

/// Encoders to try, best first, for this operating system.
pub fn candidates() -> &'static [&'static str] {
    if cfg!(target_os = "macos") {
        &["h264_videotoolbox", "libx264", "libopenh264"]
    } else if cfg!(windows) {
        &[
            "h264_nvenc",
            "h264_qsv",
            "h264_amf",
            "libx264",
            "libopenh264",
        ]
    } else {
        &["h264_nvenc", "h264_qsv", "libx264", "libopenh264"]
    }
}

/// Parses `ffmpeg -encoders` output into encoder names.
pub fn parse_listing(text: &str) -> Vec<String> {
    text.lines()
        .skip_while(|l| !l.trim_start().starts_with("------"))
        .skip(1)
        .filter_map(|l| {
            let mut parts = l.split_whitespace();
            let flags = parts.next()?;
            let name = parts.next()?;
            flags.starts_with('V').then(|| name.to_string())
        })
        .collect()
}

/// Names ffmpeg was built with.
pub fn listed(ffmpeg: &Path) -> Result<Vec<String>> {
    let out = run::capture(ffmpeg, ["-hide_banner", "-encoders"])?;
    if !out.ok {
        bail!(
            "ffmpeg could not list encoders: {}",
            run::tail(&out.stderr, 3)
        );
    }
    Ok(parse_listing(&out.stdout))
}

/// True when a tiny trial encode succeeds. Being built in is not enough: NVENC,
/// for example, is listed on machines without an NVIDIA card.
pub fn works(ffmpeg: &Path, name: &str) -> bool {
    let args = [
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=black:s=640x360:r=30:d=0.2",
        "-frames:v",
        "3",
        "-c:v",
        name,
        "-pix_fmt",
        "yuv420p",
        "-f",
        "null",
        "-",
    ];
    run::capture(ffmpeg, args).map(|o| o.ok).unwrap_or(false)
}

/// Working H.264 encoders on this computer, best first.
pub fn available(ffmpeg: &Path) -> Result<Vec<String>> {
    let built = listed(ffmpeg)?;
    Ok(candidates()
        .iter()
        .filter(|c| built.iter().any(|b| b == *c))
        .filter(|c| works(ffmpeg, c))
        .map(|c| c.to_string())
        .collect())
}

/// Picks `requested`, or the best working encoder when it is "auto".
pub fn pick(ffmpeg: &Path, requested: &str) -> Result<String> {
    if requested != "auto" {
        if !listed(ffmpeg)?.iter().any(|b| b == requested) {
            bail!("this ffmpeg has no {requested} encoder");
        }
        if !works(ffmpeg, requested) {
            bail!("the {requested} encoder is built in but does not work on this computer");
        }
        return Ok(requested.to_string());
    }
    match available(ffmpeg)?.into_iter().next() {
        Some(e) => Ok(e),
        None => {
            bail!("no working H.264 encoder found; this ffmpeg needs libx264 or a hardware encoder")
        }
    }
}

/// ffmpeg output options for `name` at `bitrate` bits per second, with a
/// keyframe every two seconds.
pub fn video_args(name: &str, bitrate: u64, fps: f64) -> Vec<String> {
    let b = bitrate.to_string();
    let max = (bitrate * 3 / 2).to_string();
    let buf = (bitrate * 2).to_string();
    let gop = ((fps * 2.0).round() as u64).max(1).to_string();
    let mut a: Vec<String> = vec!["-c:v".into(), name.into(), "-b:v".into(), b];
    let extra: Vec<&str> = match name {
        "h264_videotoolbox" => vec!["-profile:v", "high", "-allow_sw", "1"],
        "h264_nvenc" => vec![
            "-preset",
            "p5",
            "-profile:v",
            "high",
            "-maxrate",
            &max,
            "-bufsize",
            &buf,
        ],
        "h264_qsv" => vec![
            "-preset",
            "medium",
            "-profile:v",
            "high",
            "-maxrate",
            &max,
            "-bufsize",
            &buf,
        ],
        "h264_amf" => vec![
            "-quality",
            "balanced",
            "-profile:v",
            "high",
            "-maxrate",
            &max,
            "-bufsize",
            &buf,
        ],
        "libx264" => vec![
            "-preset",
            "medium",
            "-profile:v",
            "high",
            "-maxrate",
            &max,
            "-bufsize",
            &buf,
        ],
        _ => vec![],
    };
    a.extend(extra.into_iter().map(String::from));
    a.extend([
        "-g".to_string(),
        gop,
        "-pix_fmt".to_string(),
        "yuv420p".to_string(),
    ]);
    a
}

#[cfg(test)]
mod tests {
    use super::*;

    const LISTING: &str = "Encoders:\n V..... = Video\n A..... = Audio\n ------\n V....D libx264              libx264 H.264 / AVC (codec h264)\n V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)\n A....D aac                  AAC (Advanced Audio Coding)\n";

    #[test]
    fn listing_keeps_video_encoders_only() {
        assert_eq!(parse_listing(LISTING), vec!["libx264", "h264_videotoolbox"]);
    }

    #[test]
    fn args_for_videotoolbox_skip_rate_caps() {
        let a = video_args("h264_videotoolbox", 6_000_000, 30.0);
        assert!(a.windows(2).any(|w| w == ["-b:v", "6000000"]));
        assert!(!a.iter().any(|x| x == "-maxrate"));
        assert!(a.windows(2).any(|w| w == ["-g", "60"]));
    }

    #[test]
    fn args_for_x264_cap_the_rate() {
        let a = video_args("libx264", 6_000_000, 29.97);
        assert!(a.windows(2).any(|w| w == ["-maxrate", "9000000"]));
        assert!(a.windows(2).any(|w| w == ["-bufsize", "12000000"]));
    }
}

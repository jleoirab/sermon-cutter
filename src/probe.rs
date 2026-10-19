//! Reading a media file's length, size, frame rate and codecs with ffprobe.

use crate::run;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::Value;
use std::path::Path;

#[derive(Debug, Clone, Serialize)]
pub struct MediaInfo {
    /// Seconds; 0 for a still image.
    pub duration: f64,
    pub video: Option<VideoInfo>,
    pub audio: Option<AudioInfo>,
}

#[derive(Debug, Clone, Serialize)]
pub struct VideoInfo {
    pub codec: String,
    pub width: u32,
    pub height: u32,
    /// Frames per second, e.g. 29.97.
    pub fps: f64,
    /// The same rate as ffmpeg writes it, e.g. "30000/1001", for filter arguments.
    pub fps_expr: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AudioInfo {
    pub codec: String,
    pub sample_rate: u32,
    pub channels: u32,
}

pub fn probe(ffprobe: &Path, file: &Path) -> Result<MediaInfo> {
    if !file.exists() {
        bail!("{} does not exist", file.display());
    }
    let args: Vec<&std::ffi::OsStr> = [
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
    ]
    .iter()
    .map(std::ffi::OsStr::new)
    .chain(std::iter::once(file.as_os_str()))
    .collect();
    let out = run::capture(ffprobe, args)?;
    if !out.ok {
        bail!(
            "ffprobe could not read {}: {}",
            file.display(),
            run::tail(&out.stderr, 3)
        );
    }
    parse(&out.stdout).with_context(|| format!("unexpected ffprobe output for {}", file.display()))
}

/// Parses `ffprobe -print_format json -show_format -show_streams` output.
pub fn parse(json: &str) -> Result<MediaInfo> {
    let v: Value = serde_json::from_str(json)?;
    let duration = v["format"]["duration"]
        .as_str()
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(0.0);
    let streams = v["streams"].as_array().cloned().unwrap_or_default();

    let video = streams
        .iter()
        .filter(|s| {
            s["codec_type"] == "video"
                && s["disposition"]["attached_pic"].as_i64().unwrap_or(0) == 0
        })
        .map(|s| {
            let (fps, fps_expr) = ["avg_frame_rate", "r_frame_rate"]
                .iter()
                .filter_map(|k| s[*k].as_str())
                .find_map(|r| parse_rate(r).map(|f| (f, r.to_string())))
                .unwrap_or((30.0, "30".to_string()));
            VideoInfo {
                codec: s["codec_name"].as_str().unwrap_or("").to_string(),
                width: s["width"].as_u64().unwrap_or(0) as u32,
                height: s["height"].as_u64().unwrap_or(0) as u32,
                fps,
                fps_expr,
            }
        })
        .next();

    let audio = streams
        .iter()
        .filter(|s| s["codec_type"] == "audio")
        .map(|s| AudioInfo {
            codec: s["codec_name"].as_str().unwrap_or("").to_string(),
            sample_rate: s["sample_rate"]
                .as_str()
                .and_then(|r| r.parse().ok())
                .unwrap_or(0),
            channels: s["channels"].as_u64().unwrap_or(0) as u32,
        });

    Ok(MediaInfo {
        duration,
        video,
        audio: audio.into_iter().next(),
    })
}

/// "30000/1001" -> 29.97; "0/0" and nonsense -> None.
pub fn parse_rate(s: &str) -> Option<f64> {
    let (n, d) = s.split_once('/').unwrap_or((s, "1"));
    let (n, d): (f64, f64) = (n.trim().parse().ok()?, d.trim().parse().ok()?);
    let r = n / d;
    (r.is_finite() && r > 0.0 && r <= 240.0).then_some(r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rates() {
        assert_eq!(parse_rate("30/1"), Some(30.0));
        assert!((parse_rate("30000/1001").unwrap() - 29.97).abs() < 0.001);
        assert_eq!(parse_rate("0/0"), None);
        assert_eq!(parse_rate("25"), Some(25.0));
    }

    #[test]
    fn parses_a_sermon_file() {
        // Trimmed from ffprobe on "Sun Oct 11th Sermon.mp4".
        let json = r#"{"streams":[
            {"codec_name":"h264","codec_type":"video","width":1920,"height":1080,"r_frame_rate":"30/1","avg_frame_rate":"30/1","disposition":{"attached_pic":0}},
            {"codec_name":"aac","codec_type":"audio","sample_rate":"44100","channels":2,"disposition":{"attached_pic":0}}],
            "format":{"duration":"4682.072000"}}"#;
        let m = parse(json).unwrap();
        assert_eq!(m.duration, 4682.072);
        let v = m.video.unwrap();
        assert_eq!(
            (v.codec.as_str(), v.width, v.height, v.fps),
            ("h264", 1920, 1080, 30.0)
        );
        let a = m.audio.unwrap();
        assert_eq!(
            (a.codec.as_str(), a.sample_rate, a.channels),
            ("aac", 44100, 2)
        );
    }

    #[test]
    fn still_image_has_no_duration() {
        let json = r#"{"streams":[{"codec_name":"png","codec_type":"video","width":1600,"height":900,"r_frame_rate":"25/1","avg_frame_rate":"0/0"}],"format":{}}"#;
        let m = parse(json).unwrap();
        assert_eq!(m.duration, 0.0);
        assert_eq!(m.video.unwrap().width, 1600);
        assert!(m.audio.is_none());
    }
}

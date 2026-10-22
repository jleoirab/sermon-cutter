//! Getting the stream from YouTube with yt-dlp.
//!
//! The audio comes down first, because the sermon search and the audio
//! quality check only need sound; the H.264 video follows.

use crate::events::{Event, Sink};
use crate::run;
use crate::tools::Tools;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::Value;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// AAC audio only, as YouTube serves it.
pub const AUDIO_FORMAT: &str = "ba[acodec^=mp4a]/ba[ext=m4a]";
/// H.264 video up to 1080p with AAC audio, so the Mac can play and scrub it natively.
pub const VIDEO_FORMAT: &str =
    "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/b[vcodec^=avc1][height<=1080]";

const PROGRESS_TAG: &str = "[sermoncut-progress]";
const FILE_TAG: &str = "[sermoncut-file]";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Part {
    Audio,
    Video,
}

impl Part {
    pub fn step(self) -> &'static str {
        match self {
            Part::Audio => "fetch_audio",
            Part::Video => "fetch_video",
        }
    }
    fn format(self) -> &'static str {
        match self {
            Part::Audio => AUDIO_FORMAT,
            Part::Video => VIDEO_FORMAT,
        }
    }
    fn template(self) -> &'static str {
        match self {
            Part::Audio => "%(id)s.audio.%(ext)s",
            Part::Video => "%(id)s.video.%(ext)s",
        }
    }
}

/// What the app shows before downloading anything.
#[derive(Debug, Clone, Serialize)]
pub struct StreamInfo {
    pub id: String,
    pub title: String,
    pub channel: Option<String>,
    pub duration: Option<f64>,
    /// "was_live", "is_live", "not_live", ...
    pub live_status: Option<String>,
    pub upload_date: Option<String>,
    pub description: String,
    /// Tallest H.264 rendition on offer, if any.
    pub best_h264_height: Option<u64>,
}

/// Options every yt-dlp call gets.
fn common_args(tools: &Tools) -> Vec<OsString> {
    let mut a: Vec<OsString> = vec!["--no-playlist".into()];
    if let Some(deno) = &tools.deno {
        // YouTube's JavaScript challenges need a runtime; Deno is yt-dlp's recommended one.
        a.push("--js-runtimes".into());
        let mut v = OsString::from("deno:");
        v.push(deno.as_os_str());
        a.push(v);
    }
    if let Some(ffmpeg) = &tools.ffmpeg {
        a.push("--ffmpeg-location".into());
        a.push(ffmpeg.as_os_str().to_owned());
    }
    a
}

/// Reads the stream's metadata without downloading it.
pub fn info(tools: &Tools, url: &str) -> Result<StreamInfo> {
    let mut args = common_args(tools);
    args.extend(
        ["-J", "--skip-download", "--no-warnings", url]
            .iter()
            .map(OsString::from),
    );
    let out = run::capture(tools.ytdlp()?, &args)?;
    if !out.ok {
        bail!("yt-dlp could not read {url}: {}", run::tail(&out.stderr, 4));
    }
    parse_info(&out.stdout)
}

/// Parses `yt-dlp -J` output.
pub fn parse_info(json: &str) -> Result<StreamInfo> {
    let v: Value = serde_json::from_str(json).context("yt-dlp did not print JSON")?;
    let s = |k: &str| v[k].as_str().map(str::to_string);
    let best_h264_height = v["formats"]
        .as_array()
        .map(|fs| {
            fs.iter()
                .filter(|f| f["vcodec"].as_str().is_some_and(|c| c.starts_with("avc1")))
                .filter_map(|f| f["height"].as_u64())
                .max()
        })
        .unwrap_or(None);
    Ok(StreamInfo {
        id: s("id").context("no id in yt-dlp output")?,
        title: s("title").unwrap_or_default(),
        channel: s("channel").or_else(|| s("uploader")),
        duration: v["duration"].as_f64(),
        live_status: s("live_status"),
        upload_date: s("upload_date"),
        description: s("description").unwrap_or_default(),
        best_h264_height,
    })
}

/// One update from yt-dlp's progress template.
#[derive(Debug, Clone, PartialEq)]
pub struct Progress {
    pub fraction: Option<f64>,
    pub eta_s: Option<f64>,
    pub finished: bool,
    pub filename: Option<String>,
}

/// Parses a `[sermoncut-progress] {...}` line.
pub fn parse_progress(line: &str) -> Option<Progress> {
    let json = line.strip_prefix(PROGRESS_TAG)?.trim();
    let v: Value = serde_json::from_str(json).ok()?;
    let done = v["downloaded_bytes"].as_f64();
    let total = v["total_bytes"]
        .as_f64()
        .or_else(|| v["total_bytes_estimate"].as_f64());
    let mut fraction = match (done, total) {
        (Some(d), Some(t)) if t > 0.0 => Some((d / t).clamp(0.0, 1.0)),
        _ => None,
    };
    // Fragmented (DASH) downloads may only report fragment counts.
    if fraction.is_none() {
        if let (Some(i), Some(n)) = (v["fragment_index"].as_f64(), v["fragment_count"].as_f64()) {
            if n > 0.0 {
                fraction = Some((i / n).clamp(0.0, 1.0));
            }
        }
    }
    let finished = v["status"].as_str() == Some("finished");
    Some(Progress {
        fraction: if finished { Some(1.0) } else { fraction },
        eta_s: v["eta"].as_f64(),
        finished,
        filename: v["filename"].as_str().map(|f| {
            Path::new(f)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| f.to_string())
        }),
    })
}

/// The yt-dlp arguments for downloading `part` of `url` into `dir`.
pub fn download_args(
    tools: &Tools,
    url: &str,
    dir: &Path,
    part: Part,
    format: Option<&str>,
) -> Vec<OsString> {
    let mut a = common_args(tools);
    let progress = format!("download:{PROGRESS_TAG} %(progress)j");
    let print = format!("after_move:{FILE_TAG} %(filepath)s");
    a.extend(
        [
            "-f",
            format.unwrap_or(part.format()),
            "-N",
            "4",
            "--newline",
            "--progress",
            "--progress-template",
            &progress,
            "--print",
            &print,
            "-o",
            part.template(),
            "--paths",
        ]
        .iter()
        .map(OsString::from),
    );
    a.push(dir.as_os_str().to_owned());
    if part == Part::Video {
        a.extend(["--merge-output-format", "mp4"].iter().map(OsString::from));
    }
    a.push(url.into());
    a
}

/// Downloads `part` of the stream into `dir` and returns the file's path.
/// `format` overrides the yt-dlp format selection (used by tests).
pub fn download(
    tools: &Tools,
    url: &str,
    dir: &Path,
    part: Part,
    format: Option<&str>,
    sink: &dyn Sink,
) -> Result<PathBuf> {
    std::fs::create_dir_all(dir).with_context(|| format!("could not create {}", dir.display()))?;
    let step = part.step();
    let args = download_args(tools, url, dir, part, format);
    sink.emit(Event::progress(step, 0.0, None, None));

    let mut file: Option<PathBuf> = None;
    let mut last = Instant::now()
        .checked_sub(Duration::from_secs(5))
        .unwrap_or_else(Instant::now);
    let (ok, stderr) = run::stream(tools.ytdlp()?, &args, |line| {
        if let Some(p) = parse_progress(line) {
            if p.finished || last.elapsed() >= Duration::from_millis(500) {
                if let Some(f) = p.fraction {
                    sink.emit(Event::progress(step, f, p.eta_s, p.filename.clone()));
                    last = Instant::now();
                }
            }
        } else if let Some(path) = line.strip_prefix(FILE_TAG) {
            file = Some(PathBuf::from(path.trim()));
        }
    })?;
    if !ok {
        bail!(
            "yt-dlp could not download the {}: {}",
            if part == Part::Audio {
                "audio"
            } else {
                "video"
            },
            run::tail(&stderr, 4)
        );
    }
    let file = file.context("yt-dlp finished without saying where it saved the file")?;
    if !file.exists() {
        bail!("yt-dlp reported {} but it is not there", file.display());
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bare_tools() -> Tools {
        Tools {
            tools_dir: None,
            ffmpeg: Some("/opt/ff/ffmpeg".into()),
            ffprobe: None,
            ytdlp: None,
            deno: Some("/opt/d/deno".into()),
            whisper: None,
            whisper_model: None,
        }
    }

    #[test]
    fn video_args_ask_for_h264_and_mp4() {
        let a: Vec<String> = download_args(
            &bare_tools(),
            "https://youtu.be/x",
            Path::new("/tmp/s"),
            Part::Video,
            None,
        )
        .iter()
        .map(|s| s.to_string_lossy().into())
        .collect();
        let j = a.join(" ");
        assert!(j.contains(&format!("-f {VIDEO_FORMAT}")), "{j}");
        assert!(j.contains("--js-runtimes deno:/opt/d/deno"), "{j}");
        assert!(j.contains("--ffmpeg-location /opt/ff/ffmpeg"), "{j}");
        assert!(j.contains("--merge-output-format mp4"), "{j}");
        assert!(j.contains("-o %(id)s.video.%(ext)s --paths /tmp/s"), "{j}");
        assert!(j.ends_with("https://youtu.be/x"));
    }

    #[test]
    fn audio_args_skip_the_merge() {
        let a: Vec<String> = download_args(&bare_tools(), "u", Path::new("d"), Part::Audio, None)
            .iter()
            .map(|s| s.to_string_lossy().into())
            .collect();
        assert!(a.iter().any(|x| x == AUDIO_FORMAT));
        assert!(!a.iter().any(|x| x == "--merge-output-format"));
    }

    #[test]
    fn progress_with_totals() {
        let p = parse_progress(r#"[sermoncut-progress] {"status":"downloading","downloaded_bytes":2500,"total_bytes":10000,"eta":12,"filename":"/d/iz0PPVUleUw.audio.m4a"}"#).unwrap();
        assert_eq!(p.fraction, Some(0.25));
        assert_eq!(p.eta_s, Some(12.0));
        assert_eq!(p.filename.as_deref(), Some("iz0PPVUleUw.audio.m4a"));
        assert!(!p.finished);
    }

    #[test]
    fn progress_from_fragments_and_finish() {
        let p = parse_progress(r#"[sermoncut-progress] {"status":"downloading","fragment_index":30,"fragment_count":120}"#).unwrap();
        assert_eq!(p.fraction, Some(0.25));
        let p =
            parse_progress(r#"[sermoncut-progress] {"status":"finished","downloaded_bytes":10}"#)
                .unwrap();
        assert!(p.finished);
        assert_eq!(p.fraction, Some(1.0));
        assert!(parse_progress("[download] 10%").is_none());
    }

    #[test]
    fn info_finds_the_best_h264() {
        let json = r#"{"id":"iz0PPVUleUw","title":"YOUR MOUNTAIN | 1ST SERVICE","channel":"Celebration Church TV",
            "duration":10391,"live_status":"was_live","upload_date":"20261011","description":"",
            "formats":[{"vcodec":"avc1.640028","height":1080},{"vcodec":"vp9","height":1440},{"vcodec":"avc1.4d401f","height":720},{"vcodec":"none","acodec":"mp4a.40.2"}]}"#;
        let i = parse_info(json).unwrap();
        assert_eq!(i.id, "iz0PPVUleUw");
        assert_eq!(i.best_h264_height, Some(1080));
        assert_eq!(i.duration, Some(10391.0));
        assert_eq!(i.live_status.as_deref(), Some("was_live"));
    }
}

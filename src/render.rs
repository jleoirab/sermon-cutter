//! Rendering the cut: trim the stream, lay the Sunday banner over both ends with
//! dissolves, fade the audio in and out, and encode H.264 + AAC.
//!
//! The banner sits on top of the footage, so the sermon audio plays under it
//! from the first frame to the last, as in the reference cuts.

use crate::events::{Event, Sink};
use crate::timings::Timings;
use crate::tools::Tools;
use crate::{encoders, num, probe, run, timecode};
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const STEP: &str = "render";

/// What the person asked for.
#[derive(Debug, Clone)]
pub struct RenderRequest {
    pub source: PathBuf,
    pub banner: PathBuf,
    /// Seconds into the source where the cut starts.
    pub cut_in: f64,
    /// Seconds into the source where the cut ends.
    pub cut_out: f64,
    pub timings: Timings,
    pub output: PathBuf,
    /// "auto" or an ffmpeg encoder name such as "h264_videotoolbox".
    pub encoder: String,
    pub video_bitrate: u64,
    pub audio_bitrate: u64,
    pub width: u32,
    pub height: u32,
}

/// Everything ffmpeg needs, after probing the inputs and choosing an encoder.
#[derive(Debug, Clone)]
pub struct Plan {
    pub source: PathBuf,
    pub banner: PathBuf,
    pub cut_in: f64,
    pub cut_len: f64,
    pub timings: Timings,
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub fps_expr: String,
    /// True when the source is not already width x height.
    pub scale_source: bool,
    pub encoder: String,
    pub video_bitrate: u64,
    pub audio_bitrate: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct RenderOutcome {
    pub output: PathBuf,
    pub encoder: String,
    pub cut_len: f64,
    pub elapsed_s: f64,
    /// Seconds of sermon encoded per second of wall time.
    pub speed: f64,
}

/// Fits the banner inside the frame, letterboxes it and flattens any
/// transparency onto black, converting with BT.709 like the footage.
/// Reads `[input]`, writes `[output]`; `prefix` names the links in between.
/// `bg_seconds` limits the black background (needed when the banner input is
/// a single frame rather than a loop).
pub fn banner_fit_chain(
    input: &str,
    prefix: &str,
    output: &str,
    w: u32,
    h: u32,
    rate: &str,
    bg_seconds: Option<f64>,
) -> String {
    let dur = bg_seconds
        .map(|s| format!(":d={}", num(s)))
        .unwrap_or_default();
    format!(
        "[{input}]scale={w}:{h}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos:\
out_color_matrix=bt709:out_range=tv,format=yuva420p[{prefix}fit];\
color=c=black:s={w}x{h}:r={rate}{dur}[{prefix}bg];\
[{prefix}bg][{prefix}fit]overlay=(W-w)/2:(H-h)/2:shortest=1:format=yuv420,format=yuva420p[{output}]"
    )
}

impl Plan {
    fn uses_banner(&self) -> bool {
        self.timings.has_opening() || self.timings.has_closing()
    }

    /// The ffmpeg filter graph for the whole edit.
    pub fn filtergraph(&self) -> String {
        let (w, h) = (self.width, self.height);
        let t = &self.timings;
        let mut g: Vec<String> = Vec::new();

        // Main footage. Seeking with -ss before -i already starts both streams at
        // time zero; resetting each stream's timestamps on its own here could
        // shift sound against picture when one starts a little later.
        let fit = if self.scale_source {
            format!("scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1")
        } else {
            "null".to_string()
        };
        g.push(format!("[0:v]{fit}[v0]"));

        let mut current = "v0".to_string();
        if self.uses_banner() {
            let both = t.has_opening() && t.has_closing();
            let prepared = banner_fit_chain("1:v", "b", "banner", w, h, &self.fps_expr, None);
            g.push(prepared);
            let (open_src, close_src) = if both {
                g.push("[banner]split=2[bopen][bclose]".to_string());
                ("bopen", "bclose")
            } else {
                ("banner", "banner")
            };

            if t.has_opening() {
                let fade = if t.dissolve > 0.0 {
                    format!(
                        ",fade=t=out:st={}:d={}:alpha=1",
                        num(t.open_hold),
                        num(t.dissolve)
                    )
                } else {
                    String::new()
                };
                g.push(format!(
                    "[{open_src}]trim=duration={}{fade},setpts=PTS-STARTPTS[open]",
                    num(t.open_hold + t.dissolve)
                ));
                g.push(format!("[{current}][open]overlay=eof_action=pass[v1]"));
                current = "v1".to_string();
            }

            if t.has_closing() {
                let fade = if t.dissolve > 0.0 {
                    format!(",fade=t=in:st=0:d={}:alpha=1", num(t.dissolve))
                } else {
                    String::new()
                };
                let starts_at = self.cut_len - t.close_hold - t.dissolve;
                g.push(format!(
                    "[{close_src}]trim=duration={}{fade},setpts=PTS-STARTPTS+{}/TB[close]",
                    num(t.close_hold + t.dissolve),
                    num(starts_at)
                ));
                g.push(format!("[{current}][close]overlay=eof_action=pass[v2]"));
                current = "v2".to_string();
            }
        }
        g.push(format!("[{current}]format=yuv420p[v]"));

        let mut audio: Vec<String> = Vec::new();
        if t.fade_in > 0.0 {
            audio.push(format!("afade=t=in:st=0:d={}", num(t.fade_in)));
        }
        if t.fade_out > 0.0 {
            audio.push(format!(
                "afade=t=out:st={}:d={}",
                num(self.cut_len - t.fade_out),
                num(t.fade_out)
            ));
        }
        if audio.is_empty() {
            audio.push("anull".to_string());
        }
        g.push(format!("[0:a]{}[a]", audio.join(",")));

        g.join(";")
    }

    /// The full ffmpeg argument list, writing to `out`.
    pub fn ffmpeg_args(&self, out: &Path) -> Vec<OsString> {
        let mut a: Vec<OsString> = Vec::new();
        let mut push = |items: &[&str]| a.extend(items.iter().map(OsString::from));
        push(&[
            "-hide_banner",
            "-nostdin",
            "-y",
            "-loglevel",
            "error",
            "-nostats",
            "-progress",
            "pipe:1",
        ]);
        push(&["-ss", &num(self.cut_in), "-t", &num(self.cut_len), "-i"]);
        a.push(self.source.clone().into_os_string());
        if self.uses_banner() {
            a.extend(
                ["-loop", "1", "-framerate", &self.fps_expr, "-i"]
                    .iter()
                    .map(OsString::from),
            );
            a.push(self.banner.clone().into_os_string());
        }
        a.extend(
            [
                "-filter_complex",
                &self.filtergraph(),
                "-map",
                "[v]",
                "-map",
                "[a]",
            ]
            .iter()
            .map(OsString::from),
        );
        a.extend(
            encoders::video_args(&self.encoder, self.video_bitrate, self.fps)
                .into_iter()
                .map(OsString::from),
        );
        let ab = self.audio_bitrate.to_string();
        a.extend(
            [
                "-colorspace",
                "bt709",
                "-color_primaries",
                "bt709",
                "-color_trc",
                "bt709",
                "-color_range",
                "tv",
                "-c:a",
                "aac",
                "-b:a",
                &ab,
                "-ar",
                "44100",
                "-ac",
                "2",
                "-movflags",
                "+faststart",
                "-f",
                "mp4",
            ]
            .iter()
            .map(OsString::from),
        );
        a.push(out.as_os_str().to_owned());
        a
    }
}

/// Checks the request against the actual files and picks an encoder.
pub fn plan(tools: &Tools, req: &RenderRequest) -> Result<Plan> {
    if !(req.cut_in.is_finite() && req.cut_in >= 0.0) {
        bail!("In must be zero or later");
    }
    if req.cut_out <= req.cut_in {
        bail!(
            "Out ({}) must come after In ({})",
            timecode::format(req.cut_out),
            timecode::format(req.cut_in)
        );
    }
    if req.width == 0 || req.height == 0 || req.width % 2 == 1 || req.height % 2 == 1 {
        bail!("output size must be even, e.g. 1920x1080");
    }
    let ffprobe = tools.ffprobe()?;
    let src = probe::probe(ffprobe, &req.source)?;
    let video = src.video.as_ref().context("the source has no video")?;
    if src.audio.is_none() {
        bail!("the source has no audio");
    }
    if src.duration > 0.0 && req.cut_out > src.duration + 0.05 {
        bail!(
            "Out ({}) is past the end of the source ({})",
            timecode::format(req.cut_out),
            timecode::format(src.duration)
        );
    }
    let cut_len = req.cut_out - req.cut_in;
    req.timings.validate(cut_len)?;

    if req.timings.has_opening() || req.timings.has_closing() {
        let banner = probe::probe(ffprobe, &req.banner)?;
        if banner.video.is_none() {
            bail!("the banner {} is not an image", req.banner.display());
        }
    }

    let encoder = encoders::pick(tools.ffmpeg()?, &req.encoder)?;
    Ok(Plan {
        source: req.source.clone(),
        banner: req.banner.clone(),
        cut_in: req.cut_in,
        cut_len,
        timings: req.timings,
        width: req.width,
        height: req.height,
        fps: video.fps,
        fps_expr: video.fps_expr.clone(),
        scale_source: video.width != req.width || video.height != req.height,
        encoder,
        video_bitrate: req.video_bitrate,
        audio_bitrate: req.audio_bitrate,
    })
}

/// Reads ffmpeg's `-progress` output and reports how far the encode has got.
#[derive(Default)]
pub struct ProgressParser;

impl ProgressParser {
    /// Seconds of output written so far, when `line` says so.
    pub fn feed(&mut self, line: &str) -> Option<f64> {
        let value = line.strip_prefix("out_time=")?;
        timecode::parse(value.trim()).ok()
    }
}

/// Where ffmpeg writes before the finished file is moved into place, so a
/// crash never leaves a half-written file under the real name.
pub fn partial_path(output: &Path) -> PathBuf {
    let name = output
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "sermon".into());
    output.with_file_name(format!(".{name}.partial"))
}

/// Runs the render and reports progress to `sink`.
pub fn render(tools: &Tools, req: &RenderRequest, sink: &dyn Sink) -> Result<RenderOutcome> {
    sink.emit(Event::progress(
        STEP,
        0.0,
        None,
        Some("checking inputs".into()),
    ));
    let plan = plan(tools, req)?;
    sink.emit(Event::log(
        "info",
        format!(
            "encoding {} of sermon with {}",
            timecode::format(plan.cut_len),
            plan.encoder
        ),
    ));

    if let Some(parent) = req.output.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("could not create {}", parent.display()))?;
    }
    let partial = partial_path(&req.output);
    let args = plan.ffmpeg_args(&partial);

    let start = Instant::now();
    let mut last = Instant::now()
        .checked_sub(Duration::from_secs(5))
        .unwrap_or_else(Instant::now);
    let mut parser = ProgressParser;
    let (ok, stderr) = run::stream(tools.ffmpeg()?, &args, |line| {
        if let Some(done) = parser.feed(line) {
            if last.elapsed() >= Duration::from_millis(500) {
                let fraction = (done / plan.cut_len).clamp(0.0, 1.0);
                let elapsed = start.elapsed().as_secs_f64();
                let eta = (fraction > 0.01).then(|| elapsed / fraction - elapsed);
                sink.emit(Event::progress(STEP, fraction, eta, None));
                last = Instant::now();
            }
        }
    })?;
    if !ok {
        let _ = std::fs::remove_file(&partial);
        bail!("ffmpeg failed: {}", run::tail(&stderr, 6));
    }
    #[cfg(windows)]
    {
        let _ = std::fs::remove_file(&req.output);
    }
    std::fs::rename(&partial, &req.output).with_context(|| {
        format!(
            "could not move the finished file to {}",
            req.output.display()
        )
    })?;

    let elapsed = start.elapsed().as_secs_f64();
    sink.emit(Event::progress(STEP, 1.0, Some(0.0), None));
    Ok(RenderOutcome {
        output: req.output.clone(),
        encoder: plan.encoder,
        cut_len: plan.cut_len,
        elapsed_s: (elapsed * 10.0).round() / 10.0,
        speed: ((plan.cut_len / elapsed.max(0.001)) * 10.0).round() / 10.0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan_with(t: Timings) -> Plan {
        Plan {
            source: "service.mp4".into(),
            banner: "banner.png".into(),
            cut_in: 4865.0,
            cut_len: 4435.0,
            timings: t,
            width: 1920,
            height: 1080,
            fps: 30.0,
            fps_expr: "30/1".into(),
            scale_source: false,
            encoder: "libx264".into(),
            video_bitrate: 6_000_000,
            audio_bitrate: 192_000,
        }
    }

    #[test]
    fn default_graph_has_both_banners_and_fades() {
        let g = plan_with(Timings::default()).filtergraph();
        assert!(g.contains("[banner]split=2[bopen][bclose]"), "{g}");
        assert!(
            g.contains(
                "[bopen]trim=duration=8.5,fade=t=out:st=8:d=0.5:alpha=1,setpts=PTS-STARTPTS[open]"
            ),
            "{g}"
        );
        // Closing dissolve starts at 4435 - 6 - 0.5 = 4428.5.
        assert!(
            g.contains("[bclose]trim=duration=6.5,fade=t=in:st=0:d=0.5:alpha=1,setpts=PTS-STARTPTS+4428.5/TB[close]"),
            "{g}"
        );
        assert!(
            g.contains("afade=t=in:st=0:d=4,afade=t=out:st=4432:d=3[a]"),
            "{g}"
        );
        assert!(g.ends_with("[a]"));
    }

    #[test]
    fn no_banner_means_no_banner_input() {
        let t = Timings {
            open_hold: 0.0,
            dissolve: 0.0,
            close_hold: 0.0,
            ..Default::default()
        };
        let p = plan_with(t);
        let g = p.filtergraph();
        assert!(!g.contains("1:v"), "{g}");
        assert!(g.starts_with("[0:v]null[v0];[v0]format=yuv420p[v]"), "{g}");
        let args: Vec<String> = p
            .ffmpeg_args(Path::new("out.mp4"))
            .iter()
            .map(|a| a.to_string_lossy().into())
            .collect();
        assert!(!args.iter().any(|a| a == "banner.png"));
    }

    #[test]
    fn closing_only_skips_the_split() {
        let t = Timings {
            open_hold: 0.0,
            dissolve: 0.0,
            ..Default::default()
        };
        let g = plan_with(t).filtergraph();
        assert!(!g.contains("split"), "{g}");
        assert!(
            g.contains("[banner]trim=duration=6,setpts=PTS-STARTPTS+4429/TB[close]"),
            "{g}"
        );
        assert!(g.contains("[v0][close]overlay"), "{g}");
    }

    #[test]
    fn odd_sources_are_scaled_and_padded() {
        let mut p = plan_with(Timings::default());
        p.scale_source = true;
        let g = p.filtergraph();
        assert!(
            g.starts_with(
                "[0:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080"
            ),
            "{g}"
        );
    }

    #[test]
    fn args_seek_the_source_and_write_mp4() {
        let p = plan_with(Timings::default());
        let args: Vec<String> = p
            .ffmpeg_args(Path::new("out.mp4"))
            .iter()
            .map(|a| a.to_string_lossy().into())
            .collect();
        let joined = args.join(" ");
        assert!(
            joined.contains("-ss 4865 -t 4435 -i service.mp4"),
            "{joined}"
        );
        assert!(
            joined.contains("-loop 1 -framerate 30/1 -i banner.png"),
            "{joined}"
        );
        assert!(
            joined.contains("-movflags +faststart -f mp4 out.mp4"),
            "{joined}"
        );
    }

    #[test]
    fn progress_lines() {
        let mut p = ProgressParser;
        assert_eq!(p.feed("out_time=00:01:02.500000"), Some(62.5));
        assert_eq!(p.feed("out_time=N/A"), None);
        assert_eq!(p.feed("frame=12"), None);
    }

    #[test]
    fn partial_files_are_hidden_beside_the_output() {
        assert_eq!(
            partial_path(Path::new("/x/Oct 11 Sermon.mp4")),
            PathBuf::from("/x/.Oct 11 Sermon.mp4.partial")
        );
    }
}

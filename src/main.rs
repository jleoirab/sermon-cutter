//! `sermoncut`: the Sermon Cutter engine as a command-line tool.
//!
//! Every command prints one JSON object per line on standard output (progress,
//! logs, a result or an error), so the Mac app, a later Windows app or a person
//! in a terminal can all drive it. It exits with status 1 on failure.

use anyhow::Result;
use clap::{Parser, Subcommand, ValueEnum};
use serde_json::json;
use sermoncut::events::{Event, Sink, StdoutSink};
use sermoncut::fetch::{self, Part};
use sermoncut::render::{self, RenderRequest};
use sermoncut::timings::Timings;
use sermoncut::tools::Tools;
use sermoncut::verify::{self, Expect};
use sermoncut::{encoders, parse_bitrate, timecode};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "sermoncut",
    version,
    about = "Sermon Cutter engine: fetch a stream, cut the sermon with the Sunday banner and fades, and check the result. Prints JSON lines."
)]
struct Cli {
    /// Folder holding ffmpeg, ffprobe, yt-dlp and deno (default: the app's tools folder).
    #[arg(long, global = true)]
    tools_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Clone, Copy, ValueEnum)]
enum FetchPart {
    Audio,
    Video,
    Both,
}

#[derive(Subcommand)]
enum Command {
    /// Show which ffmpeg, ffprobe, yt-dlp and Deno will be used.
    Tools,

    /// List the H.264 encoders that work on this computer, best first.
    Encoders,

    /// Read a stream's title, length and formats without downloading it.
    Info { url: String },

    /// Download a stream: audio first (for analysis), then H.264 video.
    Fetch {
        url: String,
        /// Folder to save into.
        #[arg(long, default_value = ".")]
        dir: PathBuf,
        #[arg(long, value_enum, default_value_t = FetchPart::Both)]
        part: FetchPart,
        /// Override yt-dlp's format selection (testing only).
        #[arg(long, hide = true)]
        format: Option<String>,
    },

    /// Cut the sermon, lay the banner over both ends, fade the audio, and export an MP4.
    Render {
        /// The downloaded stream.
        #[arg(long)]
        source: PathBuf,
        /// The Sunday banner (PNG, JPG or WebP).
        #[arg(long)]
        banner: PathBuf,
        /// Where the cut starts in the stream, e.g. 1:21:05.
        #[arg(long = "in", value_parser = timecode::parse_arg)]
        cut_in: f64,
        /// Where the cut ends in the stream, e.g. 2:35:00.
        #[arg(long = "out", value_parser = timecode::parse_arg)]
        cut_out: f64,
        /// The MP4 to write.
        #[arg(short = 'o', long)]
        output: PathBuf,
        /// Seconds the banner holds at the start.
        #[arg(long, default_value_t = Timings::default().open_hold)]
        open_hold: f64,
        /// Seconds each banner dissolve takes.
        #[arg(long, default_value_t = Timings::default().dissolve)]
        dissolve: f64,
        /// Seconds the banner holds at the end.
        #[arg(long, default_value_t = Timings::default().close_hold)]
        close_hold: f64,
        /// Seconds the audio fades in from silence.
        #[arg(long, default_value_t = Timings::default().fade_in)]
        fade_in: f64,
        /// Seconds the audio fades out to silence.
        #[arg(long, default_value_t = Timings::default().fade_out)]
        fade_out: f64,
        /// "auto" or an ffmpeg encoder name (see `sermoncut encoders`).
        #[arg(long, default_value = "auto")]
        encoder: String,
        #[arg(long, default_value = "6M", value_parser = parse_bitrate)]
        video_bitrate: u64,
        #[arg(long, default_value = "192k", value_parser = parse_bitrate)]
        audio_bitrate: u64,
        /// Output size; the app always uses 1920x1080.
        #[arg(long, default_value = "1920x1080", value_parser = parse_size)]
        size: (u32, u32),
        /// Skip the self-check after exporting.
        #[arg(long)]
        no_verify: bool,
        /// Replace the output file if it already exists.
        #[arg(long)]
        overwrite: bool,
    },

    /// Check an exported file: format, length, banner at both ends, quiet first and last moments.
    Verify {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        banner: Option<PathBuf>,
        /// Expected length, e.g. 1:13:55.
        #[arg(long, value_parser = timecode::parse_arg)]
        expect_duration: Option<f64>,
        #[arg(long, default_value = "1920x1080", value_parser = parse_size)]
        size: (u32, u32),
    },
}

fn parse_size(s: &str) -> Result<(u32, u32), String> {
    let (w, h) = s
        .split_once(['x', 'X'])
        .ok_or_else(|| format!("size {s:?} should look like 1920x1080"))?;
    let w: u32 = w
        .trim()
        .parse()
        .map_err(|_| format!("bad width in {s:?}"))?;
    let h: u32 = h
        .trim()
        .parse()
        .map_err(|_| format!("bad height in {s:?}"))?;
    Ok((w, h))
}

fn main() {
    let cli = Cli::parse();
    let sink = StdoutSink;
    let step = step_name(&cli.command);
    if let Err(e) = run(cli, &sink) {
        sink.emit(Event::error(step, format!("{e:#}")));
        std::process::exit(1);
    }
}

fn step_name(c: &Command) -> &'static str {
    match c {
        Command::Tools => "tools",
        Command::Encoders => "encoders",
        Command::Info { .. } => "info",
        Command::Fetch { .. } => "fetch",
        Command::Render { .. } => render::STEP,
        Command::Verify { .. } => verify::STEP,
    }
}

fn run(cli: Cli, sink: &dyn Sink) -> Result<()> {
    let tools = Tools::locate(cli.tools_dir);
    match cli.command {
        Command::Tools => {
            sink.emit(Event::result("tools", serde_json::to_value(&tools)?));
        }
        Command::Encoders => {
            let list = encoders::available(tools.ffmpeg()?)?;
            sink.emit(Event::result("encoders", json!({ "available": list })));
        }
        Command::Info { url } => {
            let info = fetch::info(&tools, &url)?;
            sink.emit(Event::result("info", serde_json::to_value(info)?));
        }
        Command::Fetch {
            url,
            dir,
            part,
            format,
        } => {
            let parts: &[Part] = match part {
                FetchPart::Audio => &[Part::Audio],
                FetchPart::Video => &[Part::Video],
                FetchPart::Both => &[Part::Audio, Part::Video],
            };
            for p in parts {
                let file = fetch::download(&tools, &url, &dir, *p, format.as_deref(), sink)?;
                sink.emit(Event::result(p.step(), json!({ "file": file })));
            }
        }
        Command::Render {
            source,
            banner,
            cut_in,
            cut_out,
            output,
            open_hold,
            dissolve,
            close_hold,
            fade_in,
            fade_out,
            encoder,
            video_bitrate,
            audio_bitrate,
            size,
            no_verify,
            overwrite,
        } => {
            let timings = Timings {
                open_hold,
                dissolve,
                close_hold,
                fade_in,
                fade_out,
            };
            let req = RenderRequest {
                source,
                banner: banner.clone(),
                cut_in,
                cut_out,
                timings,
                output,
                encoder,
                video_bitrate,
                audio_bitrate,
                width: size.0,
                height: size.1,
                overwrite,
            };
            let outcome = render::render(&tools, &req, sink)?;
            sink.emit(Event::result(render::STEP, serde_json::to_value(&outcome)?));
            if !no_verify {
                let expect = Expect {
                    duration: Some(outcome.cut_len),
                    width: size.0,
                    height: size.1,
                    banner_at_start: timings.open_hold > 0.0,
                    banner_at_end: timings.close_hold > 0.0,
                    quiet_start: timings.fade_in > 0.0,
                    quiet_end: timings.fade_out > 0.0,
                };
                let report = verify::verify(&tools, &outcome.output, Some(&banner), &expect)?;
                let passed = report.passed;
                sink.emit(Event::result(verify::STEP, serde_json::to_value(&report)?));
                if !passed {
                    anyhow::bail!("the exported file failed its self-check; see the verify result");
                }
            }
        }
        Command::Verify {
            file,
            banner,
            expect_duration,
            size,
        } => {
            let expect = Expect {
                duration: expect_duration,
                width: size.0,
                height: size.1,
                banner_at_start: banner.is_some(),
                banner_at_end: banner.is_some(),
                quiet_start: true,
                quiet_end: true,
            };
            let report = verify::verify(&tools, &file, banner.as_deref(), &expect)?;
            let passed = report.passed;
            sink.emit(Event::result(verify::STEP, serde_json::to_value(&report)?));
            if !passed {
                anyhow::bail!("the file failed its self-check");
            }
        }
    }
    Ok(())
}

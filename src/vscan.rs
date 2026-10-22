//! Watching a stream's picture.
//!
//! One ffmpeg pass turns the video into 160 x 90 grey frames. For every frame
//! the engine keeps its brightness and how much it changed from the frame
//! before; once a second it keeps a 32 x 18 thumbnail. That is enough to spot
//! a frozen picture, a black screen, a looping holding screen and a choppy
//! picture (see [`crate::quality`]) without holding any video in memory.

use crate::events::{Event, Sink};
use crate::run;
use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::path::Path;
use std::time::{Duration, Instant};

/// Frame size the picture is measured at.
pub const W: usize = 160;
pub const H: usize = 90;
/// Thumbnail size: each thumbnail pixel averages a 5 x 5 block of the frame.
pub const TW: usize = 32;
pub const TH: usize = 18;
const BLOCK: usize = W / TW;

/// Measurements of a stretch of picture.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Picture {
    /// Seconds into the stream of the first frame.
    pub start: f64,
    /// Frames per second.
    pub fps: f64,
    /// Mean grey level of each frame, 0 (black) to 255.
    pub luma: Vec<f32>,
    /// Mean absolute change in grey level from the previous frame.
    pub change: Vec<f32>,
    /// A 32 x 18 thumbnail for each second, row by row.
    pub thumbs: Vec<Vec<u8>>,
}

impl Picture {
    pub fn new(start: f64, fps: f64) -> Picture {
        Picture {
            start,
            fps,
            ..Picture::default()
        }
    }

    /// Adds one 160 x 90 grey frame; `prev` is the frame before it.
    pub fn push(&mut self, frame: &[u8], prev: Option<&[u8]>) {
        let n = frame.len() as f32;
        let sum: u64 = frame.iter().map(|&p| p as u64).sum();
        self.luma.push(sum as f32 / n);
        let change = match prev {
            Some(p) => {
                frame
                    .iter()
                    .zip(p)
                    .map(|(&a, &b)| (a as i32 - b as i32).unsigned_abs() as u64)
                    .sum::<u64>() as f32
                    / n
            }
            None => 255.0,
        };
        self.change.push(change);
        // The first frame of each second gives that second's thumbnail.
        let i = self.luma.len() - 1;
        if (i as f64 / self.fps).floor() as usize >= self.thumbs.len() {
            self.thumbs.push(thumbnail(frame));
        }
    }

    /// Seconds into the stream of frame `i`.
    pub fn time(&self, i: usize) -> f64 {
        self.start + i as f64 / self.fps
    }

    /// The frame index at `t` seconds into the stream (clamped).
    pub fn frame_at(&self, t: f64) -> usize {
        (((t - self.start) * self.fps).round().max(0.0) as usize).min(self.luma.len())
    }

    /// Seconds of picture held.
    pub fn seconds(&self) -> f64 {
        self.luma.len() as f64 / self.fps
    }

    /// Whether this holds the stretch from `a` to `b` seconds.
    pub fn covers(&self, a: f64, b: f64) -> bool {
        self.start <= a + 0.5 && self.start + self.seconds() >= b - 1.0
    }
}

/// Averages 5 x 5 blocks of a 160 x 90 frame into a 32 x 18 thumbnail.
pub fn thumbnail(frame: &[u8]) -> Vec<u8> {
    let mut t = vec![0u8; TW * TH];
    for ty in 0..TH {
        for tx in 0..TW {
            let mut s = 0u32;
            for y in ty * BLOCK..(ty + 1) * BLOCK {
                for x in tx * BLOCK..(tx + 1) * BLOCK {
                    s += frame[y * W + x] as u32;
                }
            }
            t[ty * TW + tx] = ((s + 12) / 25) as u8;
        }
    }
    t
}

/// Mean absolute difference between two thumbnails.
pub fn thumb_distance(a: &[u8], b: &[u8]) -> f32 {
    a.iter()
        .zip(b)
        .map(|(&x, &y)| (x as i32 - y as i32).unsigned_abs())
        .sum::<u32>() as f32
        / a.len() as f32
}

/// Measures `len` seconds of `file`'s picture from `start` seconds in.
/// `fps` is the stream's frame rate (from ffprobe).
pub fn scan(
    ffmpeg: &Path,
    file: &Path,
    start: f64,
    len: f64,
    fps: f64,
    step: &str,
    sink: &dyn Sink,
) -> Result<Picture> {
    if fps.is_nan() || fps <= 0.0 {
        bail!("the video's frame rate is unknown");
    }
    let mut args: Vec<OsString> = ["-hide_banner", "-nostdin", "-loglevel", "error"]
        .iter()
        .map(OsString::from)
        .collect();
    // Skipping the deblocking filter roughly halves decoding time and makes
    // no difference at 160 x 90.
    args.extend(
        ["-skip_loop_filter", "all", "-ss"]
            .iter()
            .map(OsString::from),
    );
    args.push(crate::num(start).into());
    args.push("-t".into());
    args.push(crate::num(len).into());
    args.push("-i".into());
    args.push(file.as_os_str().to_owned());
    args.extend(
        [
            "-an",
            "-sn",
            "-vf",
            &format!("scale={W}:{H}:flags=fast_bilinear,format=gray"),
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-",
        ]
        .iter()
        .map(OsString::from),
    );

    let mut pic = Picture::new(start, fps);
    let mut prev: Option<Vec<u8>> = None;
    let expected = (len * fps).max(1.0);
    let mut last = Instant::now();
    sink.emit(Event::progress(step, 0.0, None, None));
    let (ok, stderr) = run::stream_bytes(ffmpeg, &args, W * H, |frame| {
        if frame.len() < W * H {
            return;
        }
        pic.push(frame, prev.as_deref());
        match &mut prev {
            Some(p) => p.copy_from_slice(frame),
            None => prev = Some(frame.to_vec()),
        }
        if last.elapsed() >= Duration::from_millis(500) {
            let f = (pic.luma.len() as f64 / expected).min(1.0);
            sink.emit(Event::progress(step, f, None, None));
            last = Instant::now();
        }
    })?;
    if !ok {
        bail!("ffmpeg could not read the video: {}", run::tail(&stderr, 3));
    }
    if pic.luma.is_empty() {
        bail!(
            "no video frames between {} and {}",
            crate::timecode::format(start),
            crate::timecode::format(start + len)
        );
    }
    sink.emit(Event::progress(step, 1.0, None, None));
    Ok(pic)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_give_brightness_change_and_a_thumbnail_a_second() {
        let mut p = Picture::new(100.0, 2.0);
        let grey = vec![100u8; W * H];
        let white = vec![250u8; W * H];
        p.push(&grey, None);
        p.push(&grey, Some(&grey));
        p.push(&white, Some(&grey));
        assert_eq!(p.luma, [100.0, 100.0, 250.0]);
        assert_eq!(p.change[1..], [0.0, 150.0]);
        // Frames 0 and 2 start seconds 0 and 1.
        assert_eq!(p.thumbs.len(), 2);
        assert!(p.thumbs[1].iter().all(|&v| v == 250));
        assert_eq!(p.time(2), 101.0);
        assert_eq!(p.frame_at(101.0), 2);
        assert!(p.covers(100.0, 101.0));
    }

    #[test]
    fn thumbnails_average_blocks() {
        let mut f = vec![0u8; W * H];
        // Top-left 5 x 5 block white.
        for y in 0..5 {
            for x in 0..5 {
                f[y * W + x] = 255;
            }
        }
        let t = thumbnail(&f);
        assert_eq!(t[0], 255);
        assert_eq!(t[1], 0);
        assert_eq!(
            thumb_distance(&t, &vec![0u8; TW * TH]),
            255.0 / (TW * TH) as f32
        );
    }
}

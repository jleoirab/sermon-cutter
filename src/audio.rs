//! Measuring a stream's sound, one second at a time.
//!
//! ffmpeg decodes the audio to 16 kHz mono; for every second the engine keeps
//! a few numbers that separate worship from preaching (see [`crate::analysis`])
//! and a 10-per-second loudness track used to line up a final cut with its
//! stream (see [`crate::align`]).

use crate::events::{Event, Sink};
use crate::run;
use anyhow::{bail, Result};
use rustfft::num_complex::Complex;
use rustfft::FftPlanner;
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::path::Path;
use std::time::{Duration, Instant};

/// Samples per second after decoding.
pub const SR: usize = 16_000;
/// Loudness readings per second in [`Features::env`].
pub const ENV_RATE: usize = 10;
/// Anything quieter than this (dBFS) over a whole second counts as silence.
pub const SILENT_DB: f32 = -50.0;
/// Stream audio that drops out is digital silence, far below room tone.
pub const DEAD_AIR_DB: f32 = -60.0;

/// Per-second measurements of a stream's audio.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Features {
    /// Loudness of each second, dBFS.
    pub db: Vec<f32>,
    /// Share of 20 ms slices quieter than half the second's average: high for
    /// speech, which has gaps between syllables; low for continuous music.
    pub ler: Vec<f32>,
    /// Share of energy below 150 Hz: bass guitar and kick drum push it up;
    /// a preacher's microphone has almost none.
    pub bass: Vec<f32>,
    /// Spread (dB) of the 20 ms slices' loudness: speech swings, music holds.
    pub swing: Vec<f32>,
    /// Loudness every 100 ms, dBFS, floored at -100.
    pub env: Vec<f32>,
}

impl Features {
    pub fn seconds(&self) -> usize {
        self.db.len()
    }
}

/// Measures one second (`SR` samples) of audio.
pub struct SecondMeter {
    fft: std::sync::Arc<dyn rustfft::Fft<f32>>,
    window: Vec<f32>,
    scratch: Vec<Complex<f32>>,
}

impl Default for SecondMeter {
    fn default() -> Self {
        let mut planner = FftPlanner::new();
        let fft = planner.plan_fft_forward(SR);
        // Same Hann window as numpy.hanning(SR).
        let window = (0..SR)
            .map(|n| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * n as f32 / (SR as f32 - 1.0)).cos())
            .collect();
        SecondMeter {
            fft,
            window,
            scratch: vec![Complex::new(0.0, 0.0); SR],
        }
    }
}

fn db(x: f32) -> f32 {
    20.0 * (x + 1e-9).log10()
}

impl SecondMeter {
    /// Adds one second of samples (in -1..1) to `f`.
    pub fn measure(&mut self, x: &[f32], f: &mut Features) {
        debug_assert_eq!(x.len(), SR);
        let mean_sq = x.iter().map(|v| v * v).sum::<f32>() / SR as f32;
        f.db.push(db(mean_sq.sqrt()));

        // 50 slices of 20 ms.
        let slices: Vec<f32> = x
            .chunks(320)
            .map(|c| c.iter().map(|v| v * v).sum::<f32>() / 320.0 + 1e-12)
            .collect();
        let avg = slices.iter().sum::<f32>() / slices.len() as f32;
        f.ler
            .push(slices.iter().filter(|&&e| e < 0.5 * avg).count() as f32 / slices.len() as f32);
        let sdb: Vec<f32> = slices.iter().map(|e| 10.0 * e.log10()).collect();
        let m = sdb.iter().sum::<f32>() / sdb.len() as f32;
        f.swing
            .push((sdb.iter().map(|v| (v - m) * (v - m)).sum::<f32>() / sdb.len() as f32).sqrt());

        // 1 Hz bins: bin k is k Hz.
        for (i, c) in self.scratch.iter_mut().enumerate() {
            *c = Complex::new(x[i] * self.window[i], 0.0);
        }
        self.fft.process(&mut self.scratch);
        let power = |k: usize| self.scratch[k].norm_sqr();
        let total: f32 = (20..7000).map(power).sum::<f32>() + 1e-12;
        let low: f32 = (20..150).map(power).sum();
        f.bass.push(low / total);

        for c in x.chunks(SR / ENV_RATE) {
            let ms = c.iter().map(|v| v * v).sum::<f32>() / c.len() as f32;
            f.env.push(db(ms.sqrt()).max(-100.0));
        }
    }
}

/// Decodes `file`'s audio with ffmpeg and measures every whole second.
/// `duration` (seconds, if known) lets it report progress as `step`.
pub fn measure_file(
    ffmpeg: &Path,
    file: &Path,
    duration: Option<f64>,
    step: &str,
    sink: &dyn Sink,
) -> Result<Features> {
    if !file.exists() {
        bail!("{} does not exist", file.display());
    }
    let mut args: Vec<OsString> = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i"]
        .iter()
        .map(OsString::from)
        .collect();
    args.push(file.as_os_str().to_owned());
    args.extend(
        ["-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-"]
            .iter()
            .map(OsString::from),
    );

    let mut meter = SecondMeter::default();
    let mut features = Features::default();
    let mut samples = vec![0f32; SR];
    let mut last = Instant::now()
        .checked_sub(Duration::from_secs(5))
        .unwrap_or_else(Instant::now);
    let (ok, stderr) = run::stream_bytes(ffmpeg, &args, SR * 2, |bytes| {
        if bytes.len() < SR * 2 {
            return; // a final partial second is ignored
        }
        for (i, pair) in bytes.chunks_exact(2).enumerate() {
            samples[i] = i16::from_le_bytes([pair[0], pair[1]]) as f32 / 32768.0;
        }
        meter.measure(&samples, &mut features);
        if let Some(d) = duration.filter(|d| *d > 0.0) {
            if last.elapsed() >= Duration::from_millis(500) {
                sink.emit(Event::progress(
                    step,
                    features.seconds() as f64 / d,
                    None,
                    None,
                ));
                last = Instant::now();
            }
        }
    })?;
    if !ok {
        bail!(
            "ffmpeg could not decode the audio of {}: {}",
            file.display(),
            run::tail(&stderr, 4)
        );
    }
    if features.seconds() == 0 {
        bail!("{} has no audio", file.display());
    }
    Ok(features)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq: f32, amp: f32) -> Vec<f32> {
        (0..SR)
            .map(|i| amp * (2.0 * std::f32::consts::PI * freq * i as f32 / SR as f32).sin())
            .collect()
    }

    #[test]
    fn a_bass_note_reads_as_bass() {
        let mut m = SecondMeter::default();
        let mut f = Features::default();
        m.measure(&tone(80.0, 0.5), &mut f);
        m.measure(&tone(1000.0, 0.5), &mut f);
        assert!(f.bass[0] > 0.9, "80 Hz bass share {}", f.bass[0]);
        assert!(f.bass[1] < 0.01, "1 kHz bass share {}", f.bass[1]);
        // A steady tone holds its level.
        assert!(f.ler[0] < 0.05 && f.swing[0] < 1.0);
        assert!((f.db[0] - (-9.03)).abs() < 0.1, "{}", f.db[0]); // 0.5 amplitude sine = -9 dBFS
        assert_eq!(f.env.len(), 20);
    }

    #[test]
    fn bursts_with_gaps_read_like_speech() {
        // 100 ms on, 100 ms off, like syllables.
        let x: Vec<f32> = tone(300.0, 0.3)
            .into_iter()
            .enumerate()
            .map(|(i, v)| if (i / 1600) % 2 == 0 { v } else { 0.0 })
            .collect();
        let mut m = SecondMeter::default();
        let mut f = Features::default();
        m.measure(&x, &mut f);
        assert!(f.ler[0] > 0.4, "ler {}", f.ler[0]);
        assert!(f.swing[0] > 20.0, "swing {}", f.swing[0]);
    }
}

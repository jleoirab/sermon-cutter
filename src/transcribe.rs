//! Turning stretches of the stream into timed words with whisper.cpp.
//!
//! Only the part of the stream where the Out point can be is transcribed,
//! ten minutes at a time, and the words are cached so a second look costs
//! nothing.

use crate::run;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Word {
    /// Seconds into the stream.
    pub start: f64,
    pub end: f64,
    /// As heard, with punctuation ("seated.").
    pub text: String,
}

/// Words heard so far, and which stretches of the stream they cover.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Transcript {
    pub covered: Vec<(f64, f64)>,
    pub words: Vec<Word>,
}

impl Transcript {
    pub fn load(path: &Path) -> Transcript {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        std::fs::write(path, serde_json::to_string(self)?)?;
        Ok(())
    }

    pub fn covers(&self, a: f64, b: f64) -> bool {
        self.covered
            .iter()
            .any(|(x, y)| *x <= a + 0.5 && *y >= b - 0.5)
    }

    /// Adds the words of window [a, b), heard with a few seconds of run-up.
    /// Where windows overlap, the last seconds of the earlier window are the
    /// least reliable (a word may be cut off), so from 2.5 s before `a` the
    /// new window's words win.
    pub fn add(&mut self, a: f64, b: f64, words: Vec<Word>) {
        let split = a - 2.5;
        self.words.retain(|w| w.start < split || w.start >= b);
        self.words.extend(
            words
                .into_iter()
                .filter(|w| w.start >= split && w.start < b),
        );
        self.words.sort_by(|x, y| x.start.total_cmp(&y.start));
        self.covered.push((a, b));
    }
}

/// Parses whisper.cpp's `-oj` output (one word per item with `-ml 1 -sow`),
/// shifting times by `offset` seconds.
pub fn parse_whisper_json(json: &str, offset: f64) -> Result<Vec<Word>> {
    let v: Value = serde_json::from_str(json).context("whisper.cpp did not write JSON")?;
    let items = v["transcription"]
        .as_array()
        .context("no transcription in whisper.cpp output")?;
    Ok(items
        .iter()
        .filter_map(|it| {
            let text = it["text"].as_str()?.trim().to_string();
            // Skip empty items and non-speech tags such as [Music] or (applause).
            if text.is_empty() || text.starts_with('[') || text.starts_with('(') {
                return None;
            }
            let from = it["offsets"]["from"].as_f64()? / 1000.0 + offset;
            let to = it["offsets"]["to"].as_f64()? / 1000.0 + offset;
            Some(Word {
                start: from,
                end: to.max(from),
                text,
            })
        })
        .collect())
}

pub struct Transcriber<'a> {
    pub ffmpeg: &'a Path,
    pub whisper: &'a Path,
    pub model: &'a Path,
}

impl Transcriber<'_> {
    /// Transcribes `len` seconds of `media` from `start`, with a few seconds of
    /// run-up so the first words aren't clipped. Returns words in stream time.
    pub fn window(&self, media: &Path, start: f64, len: f64) -> Result<Vec<Word>> {
        let run_up = start.min(5.0);
        let from = start - run_up;
        let work = scratch_dir()?;
        let wav = work.join("window.wav");
        let base = work.join("words");

        let mut cut: Vec<OsString> = [
            "-hide_banner",
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-ss",
        ]
        .iter()
        .map(OsString::from)
        .collect();
        cut.push(crate::num(from).into());
        cut.push("-t".into());
        cut.push(crate::num(len + run_up).into());
        cut.push("-i".into());
        cut.push(media.as_os_str().to_owned());
        cut.extend(
            ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"]
                .iter()
                .map(OsString::from),
        );
        cut.push(wav.as_os_str().to_owned());
        let out = run::capture(self.ffmpeg, &cut)?;
        if !out.ok {
            let _ = std::fs::remove_dir_all(&work);
            bail!(
                "ffmpeg could not cut audio for transcription: {}",
                run::tail(&out.stderr, 3)
            );
        }

        let threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .to_string();
        let mut args: Vec<OsString> = vec![
            "-m".into(),
            self.model.as_os_str().to_owned(),
            "-f".into(),
            wav.as_os_str().to_owned(),
        ];
        // Greedy decoding with one word per item: fast, and gives word times.
        // `-mc 0` stops whisper prompting itself with the words it just
        // wrote; with them it can loop on one line for minutes ("I set you
        // free" fifty times on Sept 20) and drop the words that matter.
        args.extend(
            [
                "-l", "en", "-t", &threads, "-bs", "1", "-bo", "1", "-mc", "0", "-ml", "1", "-sow",
                "-oj", "-np", "-of",
            ]
            .iter()
            .map(OsString::from),
        );
        args.push(base.as_os_str().to_owned());
        let res = run::capture(self.whisper, &args);
        let json_path = work.join("words.json");
        let words = match res {
            Ok(o) if o.ok => std::fs::read_to_string(&json_path)
                .context("whisper.cpp wrote no transcript")
                .and_then(|j| parse_whisper_json(&j, from)),
            Ok(o) => Err(anyhow::anyhow!(
                "whisper.cpp failed: {}",
                run::tail(&o.stderr, 4)
            )),
            Err(e) => Err(e),
        };
        let _ = std::fs::remove_dir_all(&work);
        words
    }
}

fn scratch_dir() -> Result<PathBuf> {
    use std::sync::atomic::{AtomicU32, Ordering};
    static N: AtomicU32 = AtomicU32::new(0);
    let dir = std::env::temp_dir().join(format!(
        "sermoncut-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_word_items_and_skips_tags() {
        let json = r#"{"transcription":[
            {"offsets":{"from":12640,"to":14160},"text":" Please"},
            {"offsets":{"from":14160,"to":14640},"text":" be"},
            {"offsets":{"from":14640,"to":16160},"text":" seated."},
            {"offsets":{"from":16160,"to":16160},"text":""},
            {"offsets":{"from":16160,"to":18000},"text":" [Music]"}]}"#;
        let w = parse_whisper_json(json, 8940.0).unwrap();
        assert_eq!(w.len(), 3);
        assert_eq!(w[2].text, "seated.");
        assert!((w[2].start - 8954.64).abs() < 1e-6);
    }

    fn word(start: f64, text: &str) -> Word {
        Word {
            start,
            end: start + 0.4,
            text: text.into(),
        }
    }

    #[test]
    fn overlapping_windows_do_not_repeat_words() {
        let mut t = Transcript::default();
        t.add(0.0, 600.0, vec![word(598.0, "be"), word(599.5, "sea-")]);
        // The next window re-hears the edge, starting 5 s earlier.
        t.add(
            600.0,
            1200.0,
            vec![
                word(598.1, "be"),
                word(599.6, "seated."),
                word(601.0, "Now"),
            ],
        );
        let texts: Vec<&str> = t.words.iter().map(|w| w.text.as_str()).collect();
        assert_eq!(texts, ["be", "seated.", "Now"]);
        assert!(t.covers(600.0, 1200.0));
        assert!(!t.covers(1100.0, 1300.0));
    }
}

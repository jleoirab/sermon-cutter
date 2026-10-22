//! Lining up a finished sermon video with the stream it was cut from.
//!
//! Matching the loudness of the two files 10 times a second recovers the exact
//! In and Out someone used, so past Sundays become test cases for the sermon
//! finder.

use anyhow::{bail, Result};
use serde::Serialize;

use crate::audio::ENV_RATE;

/// Matches below this correlation are not trusted.
pub const MIN_SCORE: f64 = 0.8;

#[derive(Debug, Clone, Serialize)]
pub struct Alignment {
    /// Seconds into the stream where the final cut starts.
    pub cut_in: f64,
    /// Seconds into the stream where the final cut ends.
    pub cut_out: f64,
    /// How well the start and end matched (correlation, up to 1).
    pub start_score: f64,
    pub end_score: f64,
    /// True when both ends agree, meaning nothing was cut out in between.
    pub continuous: bool,
    pub final_len: f64,
}

fn mean_by(v: &[f32], k: usize) -> Vec<f32> {
    v.chunks_exact(k).map(|c| c.iter().sum::<f32>() / k as f32).collect()
}

/// Best normalised correlation of `query` inside `hay[lo..hi + query.len()]`.
fn best_match(hay: &[f32], query: &[f32], lo: usize, hi: usize) -> Option<(usize, f64)> {
    let n = query.len();
    if n < 2 || hay.len() < n {
        return None;
    }
    let qm = query.iter().map(|v| *v as f64).sum::<f64>() / n as f64;
    let q: Vec<f64> = query.iter().map(|v| *v as f64 - qm).collect();
    let qn = q.iter().map(|v| v * v).sum::<f64>().sqrt();
    if qn == 0.0 {
        return None;
    }
    let mut best: Option<(usize, f64)> = None;
    for p in lo..=hi.min(hay.len() - n) {
        let w = &hay[p..p + n];
        let wm = w.iter().map(|v| *v as f64).sum::<f64>() / n as f64;
        let (mut dot, mut wn) = (0.0, 0.0);
        for (a, b) in q.iter().zip(w) {
            let d = *b as f64 - wm;
            dot += a * d;
            wn += d * d;
        }
        if wn == 0.0 {
            continue;
        }
        let score = dot / (qn * wn.sqrt());
        if best.is_none_or(|(_, s)| score > s) {
            best = Some((p, score));
        }
    }
    best
}

/// Where final-cut time `from`..`from + len` (seconds) sits in the stream:
/// first to the second, then to the tenth of a second.
fn locate(stream: &[f32], fin: &[f32], from: f64, len: f64) -> Option<(f64, f64)> {
    let r = ENV_RATE;
    let (a, b) = ((from * r as f64) as usize, ((from + len) * r as f64) as usize);
    if b > fin.len() {
        return None;
    }
    let coarse_hay = mean_by(stream, r);
    let coarse_q = mean_by(&fin[a..b], r);
    let (p, _) = best_match(&coarse_hay, &coarse_q, 0, coarse_hay.len())?;
    let centre = p * r;
    let (fine, score) = best_match(stream, &fin[a..b], centre.saturating_sub(3 * r), centre + 3 * r)?;
    Some((fine as f64 / r as f64 - from, score))
}

/// Aligns a final cut (`fin`) with its stream, both as 10 Hz loudness tracks.
pub fn align(stream: &[f32], fin: &[f32]) -> Result<Alignment> {
    let final_len = fin.len() as f64 / ENV_RATE as f64;
    if final_len < 60.0 {
        bail!("the final cut is under a minute long; nothing to match");
    }
    // Skip the fades at both ends; a minute of sound is plenty to match on.
    let span = 60f64.min(final_len / 3.0);
    let start_from = 30f64.min(final_len / 6.0);
    let end_from = final_len - span - 10f64.min(final_len / 6.0);
    let (start_off, start_score) =
        locate(stream, fin, start_from, span).ok_or_else(|| anyhow::anyhow!("could not match the start"))?;
    let (end_off, end_score) =
        locate(stream, fin, end_from, span).ok_or_else(|| anyhow::anyhow!("could not match the end"))?;
    if start_score < MIN_SCORE || end_score < MIN_SCORE {
        bail!(
            "the final cut does not match this stream (scores {start_score:.2} and {end_score:.2}); is it the right stream?"
        );
    }
    Ok(Alignment {
        cut_in: round1(start_off),
        cut_out: round1(end_off + final_len),
        start_score: round3(start_score),
        end_score: round3(end_score),
        continuous: (start_off - end_off).abs() < 0.5,
        final_len: round1(final_len),
    })
}

fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}
fn round3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A loudness track that never repeats: a slow random walk.
    fn walk(len: usize, seed: u64) -> Vec<f32> {
        let mut s = seed;
        let mut level = -20.0f32;
        (0..len)
            .map(|_| {
                s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                level += ((s >> 33) as f32 / (1u64 << 31) as f32 - 0.5) * 4.0;
                level = level.clamp(-60.0, -5.0);
                level
            })
            .collect()
    }

    #[test]
    fn finds_a_continuous_cut() {
        let stream = walk(3 * 3600 * 10, 7);
        let (a, b) = (42_785_usize, 89_606_usize); // 4278.5 s .. 8960.6 s, in tenths
        let fin = stream[a..b].to_vec();
        let al = align(&stream, &fin).unwrap();
        assert_eq!(al.cut_in, 4278.5);
        assert_eq!(al.cut_out, 8960.6);
        assert!(al.continuous);
        assert!(al.start_score > 0.99 && al.end_score > 0.99);
    }

    #[test]
    fn notices_a_cut_in_the_middle() {
        let stream = walk(2 * 3600 * 10, 11);
        let mut fin = stream[10_000..30_000].to_vec();
        fin.extend_from_slice(&stream[40_000..60_000]); // ten minutes removed
        let al = align(&stream, &fin).unwrap();
        assert_eq!(al.cut_in, 1000.0);
        assert_eq!(al.cut_out, 6000.0);
        assert!(!al.continuous);
    }

    #[test]
    fn rejects_the_wrong_stream() {
        let stream = walk(3600 * 10, 1);
        let other = walk(1800 * 10, 2);
        assert!(align(&stream, &other).is_err());
    }
}

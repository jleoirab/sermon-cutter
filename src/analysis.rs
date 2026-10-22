//! Finding where the sermon starts from the stream's sound alone.
//!
//! Worship is sustained sound: a band with bass, or singing and keys that
//! hold their level. Preaching is one voice on a microphone: no bass and big
//! swings between syllables. The sermon starts where a stretch of worship
//! hands over to a long run of speech, and that run lasts until the next
//! long stretch of music. Short songs inside the sermon don't end it.
//!
//! Tuned on five past Sundays (Sept 13 to Oct 11, 2026) whose real In and
//! Out points were recovered with [`crate::align`].

use crate::audio::{Features, DEAD_AIR_DB, SILENT_DB};
use serde::Serialize;

/// Seconds with more bass than this share of their energy are music.
pub const MUSIC_BASS: f32 = 0.06;
/// Seconds whose 20 ms slices swing less than this (dB) are sustained sound: music.
pub const SUSTAINED_SWING: f32 = 3.0;
/// Seconds without bass whose slices swing more than this (dB) are speech.
pub const SPEECH_SWING: f32 = 4.5;
/// Window (seconds) for the service map's smoothing.
pub const SMOOTH: usize = 31;
/// Window (seconds) for deciding whether a stretch is mostly music.
pub const MUSIC_WINDOW: usize = 121;
/// Music has to dominate this long (seconds) to end a sermon; shorter songs
/// inside the sermon (3.5 minutes on Sept 27) don't.
pub const LONG_MUSIC: usize = 270;
/// A sermon has at least this many seconds of speech.
pub const MIN_SERMON_SPEECH: usize = 20 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Music,
    Speech,
    /// Neither clearly: talking over music, applause, crowd prayer.
    Mixed,
    /// Mostly silence, including stream dropouts.
    Silent,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Run {
    pub start: usize,
    pub end: usize,
    pub kind: Kind,
}

impl Run {
    pub fn len(&self) -> usize {
        self.end - self.start
    }
    pub fn is_empty(&self) -> bool {
        self.end == self.start
    }
}

/// Per-second labels before smoothing.
pub struct Labels {
    pub silent: Vec<bool>,
    pub music: Vec<bool>,
    pub speech: Vec<bool>,
    pub dead_air: Vec<bool>,
}

pub fn label(f: &Features) -> Labels {
    let n = f.seconds();
    let silent: Vec<bool> = f.db.iter().map(|d| *d < SILENT_DB).collect();
    let dead_air = f.db.iter().map(|d| *d < DEAD_AIR_DB).collect();
    let music = (0..n)
        .map(|i| !silent[i] && (f.bass[i] > MUSIC_BASS || f.swing[i] < SUSTAINED_SWING))
        .collect();
    let speech = (0..n)
        .map(|i| !silent[i] && f.bass[i] <= MUSIC_BASS && f.swing[i] > SPEECH_SWING)
        .collect();
    Labels {
        silent,
        music,
        speech,
        dead_air,
    }
}

/// Running totals, so any window's count is one subtraction.
struct Totals(Vec<u32>);

impl Totals {
    fn of(v: &[bool]) -> Self {
        let mut t = vec![0u32; v.len() + 1];
        for (i, x) in v.iter().enumerate() {
            t[i + 1] = t[i] + *x as u32;
        }
        Totals(t)
    }
    fn count(&self, a: usize, b: usize) -> u32 {
        let n = self.0.len() - 1;
        self.0[b.min(n)] - self.0[a.min(n)]
    }
}

/// Share of the voiced (non-silent) seconds in [a, b) that are `x`.
fn share(x: &Totals, voiced: &Totals, a: usize, b: usize) -> f32 {
    let v = voiced.count(a, b);
    if v == 0 {
        0.0
    } else {
        x.count(a, b) as f32 / v as f32
    }
}

/// Smoothed kind of each second, for the service map. Silent seconds are
/// left out of the averages so a dropout does not dilute the sound around it.
pub fn smooth(l: &Labels) -> Vec<Kind> {
    let n = l.silent.len();
    let voiced: Vec<bool> = l.silent.iter().map(|s| !s).collect();
    let (v, m, s) = (
        Totals::of(&voiced),
        Totals::of(&l.music),
        Totals::of(&l.speech),
    );
    let half = SMOOTH / 2;
    (0..n)
        .map(|i| {
            let (a, b) = (i.saturating_sub(half), i + half + 1);
            if (v.count(a, b) as f32) < 0.3 * SMOOTH as f32 {
                Kind::Silent
            } else if share(&m, &v, a, b) > 0.5 {
                Kind::Music
            } else if share(&s, &v, a, b) > 0.4 {
                Kind::Speech
            } else {
                Kind::Mixed
            }
        })
        .collect()
}

pub fn runs(kinds: &[Kind]) -> Vec<Run> {
    let mut out = Vec::new();
    let mut start = 0;
    for i in 1..=kinds.len() {
        if i == kinds.len() || kinds[i] != kinds[start] {
            out.push(Run {
                start,
                end: i,
                kind: kinds[start],
            });
            start = i;
        }
    }
    out
}

/// Seconds that sit inside a stretch where music dominates for `LONG_MUSIC`
/// seconds or more.
fn long_music(l: &Labels) -> Vec<bool> {
    let n = l.silent.len();
    let voiced: Vec<bool> = l.silent.iter().map(|s| !s).collect();
    let (v, m) = (Totals::of(&voiced), Totals::of(&l.music));
    let half = MUSIC_WINDOW / 2;
    let dominant: Vec<bool> = (0..n)
        .map(|i| share(&m, &v, i.saturating_sub(half), i + half + 1) > 0.6)
        .collect();
    let mut out = vec![false; n];
    let mut i = 0;
    while i < n {
        if dominant[i] {
            let mut j = i;
            while j < n && dominant[j] {
                j += 1;
            }
            if j - i >= LONG_MUSIC {
                out[i..j].iter_mut().for_each(|x| *x = true);
            }
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

#[derive(Debug, Clone, Serialize)]
pub struct SermonFinding {
    /// When the preacher starts talking for good, seconds into the stream.
    pub preacher_starts: usize,
    /// Where the run of speech that starts the sermon gives way to a long
    /// stretch of music (or the stream ends). The Out point is usually
    /// before this, but a ministration time after the sermon can push it later.
    pub speech_run_ends: usize,
    /// Seconds of speech in that run.
    pub speech_seconds: usize,
    /// Seconds of stream dropout (digital silence) in that run.
    pub dead_air_seconds: usize,
    /// "high" when clear worship hands over to a long sermon.
    pub start_confidence: &'static str,
    /// Every stretch of 20 s or more, for the Review screen's service map.
    pub runs: Vec<Run>,
}

/// Finds where the sermon starts. `None` when no run of speech is long enough.
pub fn find_sermon(f: &Features) -> Option<SermonFinding> {
    let n = f.seconds();
    if n < 600 {
        return None;
    }
    let l = label(f);
    let voiced: Vec<bool> = l.silent.iter().map(|s| !s).collect();
    let (v, m, s) = (
        Totals::of(&voiced),
        Totals::of(&l.music),
        Totals::of(&l.speech),
    );
    let long = long_music(&l);

    // For every second, where the next long stretch of music begins.
    let mut next_long = vec![n; n + 1];
    for t in (0..n).rev() {
        next_long[t] = if long[t] { t } else { next_long[t + 1] };
    }

    // Candidates: worship behind, speech ahead. Score by the speech that
    // follows before the next long stretch of music.
    let mut best: Option<(u32, usize)> = None;
    for t in (300..n.saturating_sub(120)).step_by(5) {
        if long[t] || share(&m, &v, t - 300, t) < 0.4 || share(&s, &v, t, t + 120) < 0.5 {
            continue;
        }
        let score = s.count(t, next_long[t]);
        if best.is_none_or(|(b, _)| score > b) {
            best = Some((score, t));
        }
    }
    let (score, t) = best?;
    if (score as usize) < MIN_SERMON_SPEECH {
        return None;
    }

    // First moment from which 20 s are mostly speech.
    let mut start = t;
    for u in t.saturating_sub(90)..(t + 120).min(n) {
        let hi = (u + 20).min(n);
        let voiced_secs = v.count(u, hi);
        if voiced_secs >= 10 && s.count(u, hi) * 10 >= voiced_secs * 6 {
            start = u;
            break;
        }
    }
    let end = next_long[t];

    let worship_before = share(&m, &v, start.saturating_sub(300), start) >= 0.6;
    let long_sermon = score as usize >= 40 * 60;
    let start_confidence = match (worship_before, long_sermon) {
        (true, true) => "high",
        (true, false) | (false, true) => "medium",
        _ => "low",
    };
    let dead_air_seconds = l.dead_air[start..end].iter().filter(|d| **d).count();
    let rs = runs(&smooth(&l));

    Some(SermonFinding {
        preacher_starts: start,
        speech_run_ends: end,
        speech_seconds: score as usize,
        dead_air_seconds,
        start_confidence,
        runs: rs.into_iter().filter(|r| r.len() >= 20).collect(),
    })
}

/// The In point: `lead_in` seconds of worship before the preacher starts,
/// moved to the quietest second within 3 s so the fade starts cleanly.
pub fn in_point(f: &Features, preacher_starts: usize, lead_in: f64) -> f64 {
    let target = (preacher_starts as f64 - lead_in).max(0.0).round() as usize;
    let lo = target.saturating_sub(3);
    let hi = (target + 4).min(f.seconds());
    (lo..hi)
        .min_by(|x, y| f.db[*x].total_cmp(&f.db[*y]))
        .unwrap_or(target) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds features for a made-up service: (seconds, kind) pieces.
    fn service(parts: &[(usize, Kind)]) -> Features {
        let mut f = Features::default();
        for (secs, kind) in parts {
            for _ in 0..*secs {
                let (db, bass, swing) = match kind {
                    Kind::Music => (-13.0, 0.5, 2.5),
                    Kind::Speech => (-18.0, 0.003, 9.8),
                    Kind::Mixed => (-20.0, 0.03, 4.0),
                    Kind::Silent => (-180.0, 0.0, 0.0),
                };
                f.db.push(db);
                f.bass.push(bass);
                f.swing.push(swing);
                f.ler.push(0.3);
            }
        }
        f
    }

    use Kind::*;

    #[test]
    fn finds_the_long_talk_after_worship() {
        let f = service(&[
            (600, Silent),
            (900, Music),   // worship 1
            (600, Speech),  // prayer
            (1200, Music),  // worship 2, ends at 3300
            (4300, Speech), // sermon
            (400, Music),   // giving song
            (300, Speech),  // announcements
        ]);
        let s = find_sermon(&f).unwrap();
        assert!(
            s.preacher_starts.abs_diff(3300) <= 20,
            "{}",
            s.preacher_starts
        );
        assert_eq!(s.start_confidence, "high");
        assert!(
            s.speech_run_ends.abs_diff(7600) <= 60,
            "{}",
            s.speech_run_ends
        );
        let cut_in = in_point(&f, s.preacher_starts, 120.0);
        assert!(
            (cut_in - (s.preacher_starts as f64 - 120.0)).abs() <= 3.0,
            "{cut_in}"
        );
    }

    #[test]
    fn a_song_inside_the_sermon_does_not_end_it() {
        let f = service(&[
            (1200, Music),
            (1700, Speech),
            (210, Music),
            (2700, Speech),
            (600, Music),
        ]);
        let s = find_sermon(&f).unwrap();
        assert!(
            s.preacher_starts.abs_diff(1200) <= 20,
            "{}",
            s.preacher_starts
        );
        assert!(
            s.speech_run_ends >= 5700,
            "sermon ended at {}",
            s.speech_run_ends
        );
    }

    #[test]
    fn soft_worship_still_counts_as_worship() {
        // Keys and voices with no bass, held notes: low swing.
        let mut f = service(&[(900, Mixed), (3000, Speech), (600, Music)]);
        for i in 0..900 {
            f.swing[i] = 2.0;
        }
        let s = find_sermon(&f).unwrap();
        assert!(
            s.preacher_starts.abs_diff(900) <= 20,
            "{}",
            s.preacher_starts
        );
    }

    #[test]
    fn dropouts_do_not_end_the_sermon() {
        let f = service(&[
            (1200, Music),
            (1500, Speech),
            (110, Silent),
            (70, Music),
            (500, Silent),
            (1500, Speech),
            (400, Music),
        ]);
        let s = find_sermon(&f).unwrap();
        assert!(
            s.speech_run_ends >= 4800,
            "sermon ended at {}",
            s.speech_run_ends
        );
        assert!(s.dead_air_seconds >= 600, "{}", s.dead_air_seconds);
    }

    #[test]
    fn a_long_ministration_song_does_end_it() {
        let f = service(&[(1200, Music), (2400, Speech), (420, Music), (1300, Speech)]);
        let s = find_sermon(&f).unwrap();
        assert!(s.speech_run_ends <= 3700, "{}", s.speech_run_ends);
    }

    #[test]
    fn no_sermon_in_a_concert() {
        assert!(find_sermon(&service(&[(3600, Music), (300, Speech)])).is_none());
    }
}

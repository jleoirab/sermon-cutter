//! Judging a stream before anyone cuts it.
//!
//! The engine looks for what goes wrong in a live stream: the sound drops to
//! digital silence, the preacher's microphone goes while the room carries
//! on, the picture freezes, goes black or is replaced by a looping holding
//! screen, or turns choppy. It then grades the cut Good, Usable but tell the
//! leads, or Not usable, and drafts the note for the leads.
//!
//! Tuned on six streams: five good Sundays (Sept 13 to Oct 11, 2026) and the
//! Oct 18 stream, whose sound dropped out 11 times and which showed the
//! church's looping holding graphic for 13 minutes mid-sermon.

use crate::audio::{Features, DEAD_AIR_DB};
use crate::events::Sink;
use crate::probe;
use crate::tools::Tools;
use crate::vscan::{self, thumb_distance, Picture};
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::path::Path;

/// Progress step names.
pub const STEP: &str = "check";
pub const STEP_PICTURE: &str = "check_picture";

/// Dead air shorter than this (seconds) is ignored.
pub const DEAD_AIR_MIN: usize = 1;
/// Gaps of this many seconds or fewer between two problems join them.
pub const JOIN: f64 = 2.0;
/// A lost microphone: this many dB under the 5-minute median...
pub const LOST_MIC_DROP: f32 = 25.0;
/// ...for at least this long (seconds). Pauses on the good Sundays reach 13 s.
pub const LOST_MIC_MIN: usize = 20;
/// A jump in audio timestamps longer than this (seconds) is a gap.
pub const PACKET_GAP: f64 = 0.25;
/// Frames that change by less than this (grey levels) are the same picture.
pub const STILL: f32 = 0.1;
/// A picture still for this long (seconds) is frozen.
pub const FROZEN_MIN: f64 = 2.0;
/// Frames darker than this (grey level, 0 to 255) are black. The darkest
/// worship lighting on the good Sundays stays above 15.
pub const BLACK: f32 = 10.0;
/// Black for this long (seconds) counts.
pub const BLACK_MIN: f64 = 1.0;
/// A frame repeated exactly enough to count towards choppiness.
pub const REPEAT: f32 = 0.05;
/// A minute with more than this many holds of 3 or more repeated frames is
/// choppy. The good Sundays have at most 6; Oct 18 at most 19.
pub const CHOPPY_HOLDS: usize = 10;

/// Any sound problem this long (seconds) means the stream isn't Good.
pub const MINOR_SOUND: f64 = 3.0;
/// The guide's rule: a sound gap this long (seconds) must be reported.
pub const TELL_LEADS: f64 = 30.0;
/// A Good stream has less than this much (seconds) picture trouble in all.
pub const PICTURE_BUDGET: f64 = 30.0;
/// Not usable: sound or picture lost for this share of the cut...
pub const LOST_SHARE: f64 = 0.05;
/// ...or in one stretch longer than this (seconds)...
pub const LONGEST: f64 = 180.0;
/// ...or in this many stretches longer than `TELL_LEADS`.
pub const MANY: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// The stream's sound dropped to digital silence.
    DeadAir,
    /// The sound fell far below the room's usual level: the microphone went.
    LostMic,
    /// The audio data itself has a hole.
    AudioGap,
    /// The picture stopped moving.
    Frozen,
    /// The picture went black.
    Black,
    /// A looping holding screen instead of the service.
    Holding,
    /// The picture keeps catching.
    Choppy,
}

impl Kind {
    pub fn is_sound(self) -> bool {
        matches!(self, Kind::DeadAir | Kind::LostMic | Kind::AudioGap)
    }
    /// Whether the picture of the service is gone, not just rough.
    pub fn loses_picture(self) -> bool {
        matches!(self, Kind::Frozen | Kind::Black | Kind::Holding)
    }
    pub fn describe(self) -> &'static str {
        match self {
            Kind::DeadAir => "no sound",
            Kind::LostMic => "the preacher's microphone drops out",
            Kind::AudioGap => "a gap in the sound",
            Kind::Frozen => "the picture freezes",
            Kind::Black => "the picture goes black",
            Kind::Holding => "a holding screen replaces the service",
            Kind::Choppy => "the picture is choppy",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Issue {
    pub kind: Kind,
    /// Seconds into the stream.
    pub start: f64,
    pub end: f64,
}

impl Issue {
    pub fn len(&self) -> f64 {
        self.end - self.start
    }
    pub fn is_empty(&self) -> bool {
        self.end <= self.start
    }
}

/// Runs of `true` as (start, end) index pairs, joining runs separated by
/// `join` or fewer `false`s, keeping those at least `min` long.
fn runs(mask: &[bool], join: usize, min: usize) -> Vec<(usize, usize)> {
    let mut out: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i < mask.len() {
        if !mask[i] {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < mask.len() && mask[j] {
            j += 1;
        }
        match out.last_mut() {
            Some(last) if i - last.1 <= join => last.1 = j,
            _ => out.push((i, j)),
        }
        i = j;
    }
    out.retain(|(a, b)| b - a >= min);
    out
}

/// Seconds of digital silence between `a` and `b`.
pub fn dead_air(f: &Features, a: usize, b: usize) -> Vec<Issue> {
    let b = b.min(f.seconds());
    if a >= b {
        return vec![];
    }
    let mask: Vec<bool> = f.db[a..b].iter().map(|d| *d < DEAD_AIR_DB).collect();
    runs(&mask, JOIN as usize, DEAD_AIR_MIN)
        .into_iter()
        .map(|(s, e)| Issue {
            kind: Kind::DeadAir,
            start: (a + s) as f64,
            end: (a + e) as f64,
        })
        .collect()
}

/// Stretches where the sound sits far below the room's usual level for the
/// surrounding 5 minutes, without being dead air.
pub fn lost_mic(f: &Features, a: usize, b: usize) -> Vec<Issue> {
    let n = f.seconds();
    let b = b.min(n);
    if a >= b {
        return vec![];
    }
    let mut window: Vec<f32> = Vec::with_capacity(300);
    let mask: Vec<bool> = (a..b)
        .map(|i| {
            let d = f.db[i];
            if d < DEAD_AIR_DB {
                return false;
            }
            window.clear();
            window.extend(
                f.db[i.saturating_sub(150)..(i + 150).min(n)]
                    .iter()
                    .filter(|x| **x >= DEAD_AIR_DB),
            );
            window.sort_by(|x, y| x.total_cmp(y));
            let median = window[window.len() / 2];
            d < median - LOST_MIC_DROP
        })
        .collect();
    // No joining: a burst of speech at the usual level means the microphone
    // works, and pauses between sentences are what this must not flag.
    runs(&mask, 0, LOST_MIC_MIN)
        .into_iter()
        .map(|(s, e)| Issue {
            kind: Kind::LostMic,
            start: (a + s) as f64,
            end: (a + e) as f64,
        })
        .collect()
}

/// Holes in the audio data: (timestamp, duration) of each packet, in order.
pub fn audio_gaps(packets: &[(f64, f64)], a: f64, b: f64) -> Vec<Issue> {
    packets
        .windows(2)
        .filter_map(|w| {
            let end = w[0].0 + w[0].1;
            let next = w[1].0;
            (next - end > PACKET_GAP && end < b && next > a).then_some(Issue {
                kind: Kind::AudioGap,
                start: end.max(a),
                end: next.min(b),
            })
        })
        .collect()
}

fn picture_runs(
    p: &Picture,
    a: f64,
    b: f64,
    kind: Kind,
    min: f64,
    test: impl Fn(usize) -> bool,
) -> Vec<Issue> {
    let (i0, i1) = (p.frame_at(a), p.frame_at(b));
    if i0 >= i1 {
        return vec![];
    }
    let mask: Vec<bool> = (i0..i1).map(test).collect();
    let min_frames = (min * p.fps).round() as usize;
    runs(&mask, 0, min_frames.max(1))
        .into_iter()
        .map(|(s, e)| Issue {
            kind,
            start: p.time(i0 + s),
            end: p.time(i0 + e),
        })
        .collect()
}

/// Stretches where the picture doesn't change at all.
pub fn frozen(p: &Picture, a: f64, b: f64) -> Vec<Issue> {
    picture_runs(p, a, b, Kind::Frozen, FROZEN_MIN, |i| p.change[i] < STILL)
}

/// Stretches of black picture.
pub fn black(p: &Picture, a: f64, b: f64) -> Vec<Issue> {
    picture_runs(p, a, b, Kind::Black, BLACK_MIN, |i| p.luma[i] < BLACK)
}

/// Seconds checked together when looking for a loop.
const LOOP_WINDOW: usize = 30;
/// Loop lengths tried (seconds).
const LOOP_LAGS: std::ops::RangeInclusive<usize> = 4..=60;
/// Thumbnails this close (grey levels) are the same picture.
const SAME: f32 = 4.0;
/// Half a loop apart, a holding animation looks this different (grey levels);
/// a camera on a still stage doesn't.
const ANIMATED: f32 = 15.0;

/// Stretches where the picture is a short animation playing over and over,
/// like the church's holding graphic on Oct 18 (a 15-second loop). A camera
/// on the service never repeats itself exactly; a still shot repeats but
/// doesn't change in between. Needs a minute of picture before `a`.
pub fn holding(p: &Picture, a: f64, b: f64) -> Vec<Issue> {
    let n = p.thumbs.len();
    let max_lag = *LOOP_LAGS.end();
    if n < max_lag + LOOP_WINDOW {
        return vec![];
    }
    let d = |t: usize, u: usize| thumb_distance(&p.thumbs[t], &p.thumbs[u]);
    let mut looping = vec![false; n];
    let mut starts: Vec<usize> = (max_lag..=n - LOOP_WINDOW).step_by(5).collect();
    if starts.last() != Some(&(n - LOOP_WINDOW)) {
        starts.push(n - LOOP_WINDOW);
    }
    for k0 in starts {
        let window = k0..k0 + LOOP_WINDOW;
        let is_loop = LOOP_LAGS.clone().any(|lag| {
            let same: Vec<usize> = window.clone().filter(|&t| d(t, t - lag) < SAME).collect();
            if same.len() * 10 < LOOP_WINDOW * 8 {
                return false;
            }
            // Among the seconds that repeat, half a loop back must look
            // different, or it's just a still picture.
            let mut half: Vec<f32> = same.iter().map(|&t| d(t, t - lag / 2)).collect();
            half.sort_by(|x, y| x.total_cmp(y));
            half[half.len() / 2] > ANIMATED
        });
        if is_loop {
            looping[window].iter_mut().for_each(|x| *x = true);
        }
    }
    runs(&looping, 0, 1)
        .into_iter()
        .map(|(s, e)| Issue {
            kind: Kind::Holding,
            start: (p.start + s as f64).max(a),
            end: (p.start + e as f64).min(b),
        })
        .filter(|i| i.len() > 0.0)
        .collect()
}

/// Minutes where the picture keeps catching: more than `CHOPPY_HOLDS` holds
/// of 3 or more repeated frames.
pub fn choppy(p: &Picture, a: f64, b: f64) -> Vec<Issue> {
    let mut out: Vec<Issue> = Vec::new();
    let mut m = a;
    while m < b {
        let e = (m + 60.0).min(b);
        let (i0, i1) = (p.frame_at(m), p.frame_at(e));
        let mask: Vec<bool> = (i0..i1).map(|i| p.change[i] < REPEAT).collect();
        let holds = runs(&mask, 0, 3).len();
        if holds > CHOPPY_HOLDS {
            match out.last_mut() {
                Some(last) if last.end >= m => last.end = e,
                _ => out.push(Issue {
                    kind: Kind::Choppy,
                    start: m,
                    end: e,
                }),
            }
        }
        m = e;
    }
    out
}

/// Every video problem between `a` and `b`.
pub fn picture_issues(p: &Picture, a: f64, b: f64) -> Vec<Issue> {
    let mut v = frozen(p, a, b);
    v.extend(black(p, a, b));
    v.extend(holding(p, a, b));
    v.extend(choppy(p, a, b));
    v.sort_by(|x, y| x.start.total_cmp(&y.start));
    v
}

/// Joins overlapping or touching stretches.
fn union(mut spans: Vec<(f64, f64)>) -> Vec<(f64, f64)> {
    spans.sort_by(|x, y| x.0.total_cmp(&y.0));
    let mut out: Vec<(f64, f64)> = Vec::new();
    for (s, e) in spans {
        match out.last_mut() {
            Some(last) if s <= last.1 + JOIN => last.1 = last.1.max(e),
            _ => out.push((s, e)),
        }
    }
    out
}

/// One problem as the app shows it.
#[derive(Debug, Clone, Serialize)]
pub struct Found {
    pub kind: Kind,
    pub what: &'static str,
    /// Seconds into the stream.
    pub start: f64,
    pub end: f64,
    pub len: f64,
    /// Seconds into the finished sermon video.
    pub into_cut: f64,
    pub into_cut_tc: String,
    pub stream_tc: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    /// "good", "tell_leads" or "not_usable".
    pub verdict: &'static str,
    pub headline: &'static str,
    /// Why, in a sentence each.
    pub reasons: Vec<String>,
    pub cut_in: f64,
    pub cut_out: f64,
    /// Seconds of the cut with no usable sound, and with no picture of the
    /// service.
    pub sound_lost: f64,
    pub picture_lost: f64,
    pub video_checked: bool,
    pub issues: Vec<Found>,
    /// One per minute of the cut: "good", "warn" or "bad".
    pub minutes: Vec<&'static str>,
    /// A message for the leads, empty when the stream is Good.
    pub note: String,
}

/// The video to check, and where to keep its measurements.
pub struct VideoSource<'a> {
    pub file: &'a Path,
    pub cache: Option<&'a Path>,
}

/// Checks the cut from `cut_in` to `cut_out`: the sound from `features` (the
/// stream's sound measurements) and `audio_file`'s packets, the picture from
/// `video` when given.
pub fn check(
    tools: &Tools,
    features: &Features,
    audio_file: &Path,
    video: Option<VideoSource>,
    cut_in: f64,
    cut_out: f64,
    sink: &dyn Sink,
) -> Result<Report> {
    if cut_out <= cut_in {
        bail!("Out must come after In");
    }
    let (a, b) = (cut_in.floor() as usize, cut_out.ceil() as usize);
    let mut issues = dead_air(features, a, b);
    issues.extend(lost_mic(features, a, b));
    let packets = probe::audio_packets(tools.ffprobe()?, audio_file, cut_in, cut_out)?;
    issues.extend(audio_gaps(&packets, cut_in, cut_out));
    let checked = video.is_some();
    if let Some(v) = video {
        let pic = picture(tools, &v, cut_in, cut_out, sink)?;
        issues.extend(picture_issues(&pic, cut_in, cut_out));
    }
    Ok(judge(&issues, cut_in, cut_out, checked))
}

/// The picture from a minute before `cut_in` (the loop check looks back that
/// far) to `cut_out`, from the cache when it holds it.
fn picture(
    tools: &Tools,
    v: &VideoSource,
    cut_in: f64,
    cut_out: f64,
    sink: &dyn Sink,
) -> Result<Picture> {
    let start = (cut_in - 60.0).max(0.0);
    if let Some(c) = v.cache {
        if let Some(p) = std::fs::read_to_string(c)
            .ok()
            .and_then(|t| serde_json::from_str::<Picture>(&t).ok())
            .filter(|p| p.covers(start, cut_out))
        {
            return Ok(p);
        }
    }
    let info = probe::probe(tools.ffprobe()?, v.file)?;
    let fps = info
        .video
        .with_context(|| format!("{} has no video", v.file.display()))?
        .fps;
    let p = vscan::scan(
        tools.ffmpeg()?,
        v.file,
        start,
        cut_out - start,
        fps,
        STEP_PICTURE,
        sink,
    )?;
    if let Some(c) = v.cache {
        std::fs::write(c, serde_json::to_string(&p)?)?;
    }
    Ok(p)
}

/// "19:38" or "1:02:05", whole seconds.
pub fn clock(secs: f64) -> String {
    let s = secs.max(0.0).floor() as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

/// "31 s", "8 min 17 s", "2 min".
pub fn span(secs: f64) -> String {
    let s = secs.round() as u64;
    match (s / 60, s % 60) {
        (0, r) => format!("{r} s"),
        (m, 0) => format!("{m} min"),
        (m, r) => format!("{m} min {r} s"),
    }
}

struct Lost {
    total: f64,
    longest: f64,
    long: usize,
    count: usize,
}

fn lost(spans: &[(f64, f64)]) -> Lost {
    Lost {
        total: spans.iter().map(|(s, e)| e - s).sum::<f64>() + 0.0,
        longest: spans.iter().map(|(s, e)| e - s).fold(0.0, f64::max),
        long: spans.iter().filter(|(s, e)| e - s > TELL_LEADS).count(),
        count: spans.len(),
    }
}

/// Grades the cut from `cut_in` to `cut_out` given the problems found.
pub fn judge(issues: &[Issue], cut_in: f64, cut_out: f64, video_checked: bool) -> Report {
    let cut = (cut_out - cut_in).max(1.0);
    let mut issues: Vec<Issue> = issues
        .iter()
        .filter(|i| i.end > cut_in && i.start < cut_out)
        .map(|i| Issue {
            start: i.start.max(cut_in),
            end: i.end.min(cut_out),
            ..*i
        })
        .collect();
    issues.sort_by(|x, y| x.start.total_cmp(&y.start));

    let sound = union(
        issues
            .iter()
            .filter(|i| i.kind.is_sound())
            .map(|i| (i.start, i.end))
            .collect(),
    );
    let picture = union(
        issues
            .iter()
            .filter(|i| i.kind.loses_picture())
            .map(|i| (i.start, i.end))
            .collect(),
    );
    let rough = union(
        issues
            .iter()
            .filter(|i| !i.kind.is_sound())
            .map(|i| (i.start, i.end))
            .collect(),
    );
    let (s, p) = (lost(&sound), lost(&picture));
    let rough_total: f64 = rough.iter().map(|(a, b)| b - a).sum::<f64>() + 0.0;

    let mut reasons = Vec::new();
    for (l, what) in [(&s, "sound"), (&p, "picture of the service")] {
        if l.total >= LOST_SHARE * cut {
            reasons.push(format!(
                "The {what} is lost for {} in all, {:.0}% of the sermon (the limit is {:.0}%).",
                span(l.total),
                100.0 * l.total / cut,
                100.0 * LOST_SHARE
            ));
        }
        if l.longest > LONGEST {
            reasons.push(format!(
                "The {what} is lost for {} in one stretch (the limit is {}).",
                span(l.longest),
                span(LONGEST)
            ));
        }
        if l.long >= MANY {
            reasons.push(format!(
                "The {what} is lost {} times for more than {} (the limit is {}).",
                l.long,
                span(TELL_LEADS),
                MANY - 1
            ));
        }
    }
    let (verdict, headline) = if !reasons.is_empty() {
        ("not_usable", "Not usable: use a different stream")
    } else if s.longest >= MINOR_SOUND || rough_total >= PICTURE_BUDGET {
        if s.count > 0 {
            reasons.push(format!(
                "The sound drops out {} time{}, {} in all; the longest is {}.",
                s.count,
                if s.count == 1 { "" } else { "s" },
                span(s.total),
                span(s.longest)
            ));
        }
        if rough_total >= PICTURE_BUDGET {
            reasons.push(format!(
                "The picture has trouble for {} in all.",
                span(rough_total)
            ));
        }
        ("tell_leads", "Usable, but tell the leads")
    } else {
        reasons.push(if video_checked {
            "No gaps in the sound or the picture.".to_string()
        } else {
            "No gaps in the sound; the picture wasn't checked.".to_string()
        });
        ("good", "Good")
    };

    let found: Vec<Found> = issues
        .iter()
        .map(|i| Found {
            kind: i.kind,
            what: i.kind.describe(),
            start: i.start,
            end: i.end,
            len: i.len(),
            into_cut: i.start - cut_in,
            into_cut_tc: clock(i.start - cut_in),
            stream_tc: clock(i.start),
        })
        .collect();

    let minutes = (0..(cut / 60.0).ceil() as usize)
        .map(|m| {
            let (a, b) = (
                cut_in + 60.0 * m as f64,
                (cut_in + 60.0 * (m + 1) as f64).min(cut_out),
            );
            let overlap = |spans: &[(f64, f64)]| -> f64 {
                spans
                    .iter()
                    .map(|(s, e)| (e.min(b) - s.max(a)).max(0.0))
                    .sum()
            };
            let any = issues.iter().any(|i| i.end > a && i.start < b);
            if overlap(&sound) >= MINOR_SOUND || overlap(&picture) >= MINOR_SOUND {
                "bad"
            } else if any {
                "warn"
            } else {
                "good"
            }
        })
        .collect();

    let note = note(verdict, &found, &s, &p, cut);
    Report {
        verdict,
        headline,
        reasons,
        cut_in,
        cut_out,
        sound_lost: s.total,
        picture_lost: p.total,
        video_checked,
        issues: found,
        minutes,
        note,
    }
}

fn note(verdict: &str, found: &[Found], s: &Lost, p: &Lost, cut: f64) -> String {
    if verdict == "good" {
        return String::new();
    }
    let mut lines = Vec::new();
    if verdict == "not_usable" {
        let mut what = Vec::new();
        if s.total > 0.0 {
            what.push(format!(
                "the sound drops out {} time{} ({} in all, {:.0}% of the sermon)",
                s.count,
                if s.count == 1 { "" } else { "s" },
                span(s.total),
                100.0 * s.total / cut
            ));
        }
        if p.total > 0.0 {
            what.push(format!(
                "the picture of the service is missing for {}",
                span(p.total)
            ));
        }
        lines.push(format!(
            "Heads up: this week's sermon stream isn't usable: {}. We'll need a different stream.",
            what.join(", and ")
        ));
    } else {
        lines.push("Heads up: this week's sermon video has a few problems:".to_string());
    }
    let shown: Vec<&Found> = found
        .iter()
        .filter(|f| {
            verdict == "not_usable"
                || f.kind.is_sound() && f.len >= MINOR_SOUND
                || !f.kind.is_sound()
        })
        .collect();
    for f in shown.iter().take(12) {
        lines.push(format!(
            "- {} into the sermon: {} for {}",
            f.into_cut_tc,
            f.what,
            span(f.len)
        ));
    }
    if shown.len() > 12 {
        lines.push(format!("- and {} more", shown.len() - 12));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn features(db: &[(usize, f32)]) -> Features {
        let mut f = Features::default();
        for (n, d) in db {
            f.db.extend(std::iter::repeat_n(*d, *n));
        }
        f
    }

    #[test]
    fn dead_air_runs_join_small_gaps() {
        let f = features(&[
            (100, -20.0),
            (30, -180.0),
            (1, -25.0),
            (10, -180.0),
            (100, -20.0),
            (1, -180.0),
            (50, -20.0),
        ]);
        let v = dead_air(&f, 0, f.seconds());
        assert_eq!(v.len(), 2, "{v:?}");
        assert_eq!((v[0].start, v[0].end), (100.0, 141.0));
        assert_eq!(v[1].len(), 1.0);
        // Quiet moments in the hall aren't dead air.
        assert!(dead_air(&features(&[(100, -69.0)]), 0, 100).is_empty());
    }

    #[test]
    fn lost_mic_needs_twenty_seconds_far_below_the_room() {
        let f = features(&[
            (300, -20.0),
            (25, -50.0),
            (300, -20.0),
            (15, -50.0),
            (300, -20.0),
        ]);
        let v = lost_mic(&f, 0, f.seconds());
        assert_eq!(v.len(), 1, "{v:?}");
        assert_eq!((v[0].start, v[0].end), (300.0, 325.0));
    }

    #[test]
    fn packet_gaps() {
        let mut p: Vec<(f64, f64)> = (0..100).map(|i| (i as f64 * 0.02, 0.02)).collect();
        p.push((3.0, 0.02));
        let v = audio_gaps(&p, 0.0, 10.0);
        assert_eq!(v.len(), 1);
        assert!((v[0].start - 2.0).abs() < 1e-9 && (v[0].end - 3.0).abs() < 1e-9);
    }

    /// A picture of `secs` seconds at 10 fps: frame `i` is a flat grey with a
    /// bright stripe that moves every frame, or repeats the frame before.
    fn picture(secs: usize, start: f64, f: impl Fn(usize) -> (u8, bool)) -> Picture {
        use crate::vscan::{H, W};
        let mut p = Picture::new(start, 10.0);
        let mut prev: Option<Vec<u8>> = None;
        for i in 0..secs * 10 {
            let (grey, repeat) = f(i);
            let frame = match (&prev, repeat) {
                (Some(pv), true) => pv.clone(),
                _ => {
                    let mut fr = vec![grey; W * H];
                    for y in 0..H {
                        fr[y * W + i % W] = grey.saturating_add(80);
                    }
                    fr
                }
            };
            p.push(&frame, prev.as_deref());
            prev = Some(frame);
        }
        p
    }

    #[test]
    fn frozen_and_black_pictures() {
        let p = picture(60, 1000.0, |i| match i {
            100..130 => (90, true),
            300..315 => (2, false),
            _ => (90, false),
        });
        let f = frozen(&p, 1000.0, 1060.0);
        assert_eq!(f.len(), 1, "{f:?}");
        assert!(
            (f[0].start - 1010.0).abs() < 1e-9 && (f[0].end - 1013.0).abs() < 1e-9,
            "{f:?}"
        );
        let b = black(&p, 1000.0, 1060.0);
        assert_eq!(b.len(), 1);
        assert!((b[0].len() - 1.5).abs() < 0.11);
    }

    #[test]
    fn a_looping_holding_screen_is_found_and_a_still_shot_is_not() {
        // 120 s of camera, then a 15-second animation of three colours playing
        // eight times, then 60 s of camera on a still stage.
        let mut p = Picture::new(0.0, 1.0);
        let mut prev: Option<Vec<u8>> = None;
        let mut seed: u32 = 7;
        for s in 0..300usize {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            let grey = if (120..240).contains(&s) {
                [40u8, 140, 240][((s - 120) % 15) / 5]
            } else if s < 120 {
                60 + ((seed >> 16) % 50) as u8 // a camera wandering about
            } else {
                70 // a still shot
            };
            let frame = vec![grey; crate::vscan::W * crate::vscan::H];
            p.push(&frame, prev.as_deref());
            prev = Some(frame);
        }
        let v = holding(&p, 60.0, 300.0);
        assert_eq!(v.len(), 1, "{v:?}");
        assert!(v[0].start >= 120.0 && v[0].start <= 140.0, "{v:?}");
        assert!(v[0].end >= 235.0 && v[0].end <= 245.0, "{v:?}");
    }

    #[test]
    fn choppy_minutes() {
        // 3 repeated frames every second for the first minute.
        let p = picture(120, 0.0, |i| (90, i < 600 && matches!(i % 10, 1..=3)));
        let v = choppy(&p, 0.0, 120.0);
        assert_eq!(v.len(), 1, "{v:?}");
        assert_eq!((v[0].start, v[0].end), (0.0, 60.0));
    }

    fn issue(kind: Kind, start: f64, len: f64) -> Issue {
        Issue {
            kind,
            start,
            end: start + len,
        }
    }

    #[test]
    fn verdicts() {
        let (a, b) = (1000.0, 1000.0 + 75.0 * 60.0);
        let good = judge(
            &[
                issue(Kind::DeadAir, 1500.0, 2.0),
                issue(Kind::Black, 2000.0, 1.0),
            ],
            a,
            b,
            true,
        );
        assert_eq!(good.verdict, "good");
        assert!(good.note.is_empty());

        let tell = judge(&[issue(Kind::DeadAir, 1500.0, 45.0)], a, b, true);
        assert_eq!(tell.verdict, "tell_leads");
        assert!(
            tell.note
                .contains("8:20 into the sermon: no sound for 45 s"),
            "{}",
            tell.note
        );
        assert_eq!(tell.minutes[8], "bad");
        assert_eq!(tell.minutes[0], "good");

        // Three gaps over 30 s.
        let three = judge(
            &[
                issue(Kind::DeadAir, 1500.0, 31.0),
                issue(Kind::DeadAir, 2500.0, 31.0),
                issue(Kind::LostMic, 3500.0, 40.0),
            ],
            a,
            b,
            true,
        );
        assert_eq!(three.verdict, "not_usable");
        assert_eq!(three.reasons.len(), 1, "{:?}", three.reasons);

        // A holding screen for 4 minutes loses the picture in one long stretch.
        let held = judge(&[issue(Kind::Holding, 2000.0, 240.0)], a, b, true);
        assert_eq!(held.verdict, "not_usable");
        assert!(
            held.note
                .contains("picture of the service is missing for 4 min"),
            "{}",
            held.note
        );

        // Problems outside the cut don't count.
        assert_eq!(
            judge(&[issue(Kind::DeadAir, 100.0, 600.0)], a, b, false).verdict,
            "good"
        );
    }

    #[test]
    fn clocks_and_spans() {
        assert_eq!(clock(1178.9), "19:38");
        assert_eq!(clock(3725.0), "1:02:05");
        assert_eq!(span(31.2), "31 s");
        assert_eq!(span(497.0), "8 min 17 s");
        assert_eq!(span(180.0), "3 min");
    }
}

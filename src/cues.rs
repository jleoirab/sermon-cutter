//! Finding the Out point in the words: where the preacher tells the
//! congregation to sit down after the closing prayer, just before the
//! offering.
//!
//! On four of the five reference Sundays (Sept 13, 20, 27 and Oct 11) the cut
//! ends right after "please be seated", keeping a short "Thank you, Jesus"
//! that follows it, and the offering or announcements start within a few
//! minutes. On Oct 4 the preacher closed in prayer and someone else thanked
//! him and led into the giving before asking people to sit; that cut ended at
//! the closing prayer.

use crate::transcribe::{Transcript, Word};
use anyhow::Result;
use serde::Serialize;

/// Word sequences that tell people to sit.
const SEAT_PHRASES: &[&[&str]] = &[
    &["be", "seated"],
    &["take", "your", "seat"],
    &["take", "your", "seats"],
    &["take", "our", "seats"],
    &["take", "our", "seat"],
    &["have", "your", "seat"],
    &["have", "your", "seats"],
    &["have", "a", "seat"],
    &["take", "a", "seat"],
    &["you", "may", "sit"],
    &["sit", "down"],
];

/// Words that close a prayer.
const CLOSERS: &[&str] = &["prayed", "amen"];
/// Word sequences that end a prayer "in Jesus' name", for when whisper drops
/// the closing word itself.
const IN_JESUS_NAME: &[&[&str]] = &[
    &["jesus", "name"],
    &["name", "of", "jesus"],
    &["jesus", "mighty"],
];
/// Words that mean the offering has started.
const OFFERING: &[&str] = &[
    "offering",
    "offerings",
    "tithe",
    "tithes",
    "giving",
    "announcement",
    "announcements",
];
/// Weaker signs that the service has moved on.
const MOVING_ON: &[&str] = &[
    "give",
    "seed",
    "link",
    "register",
    "visitor",
    "visitors",
    "timers",
    "volunteer",
    "volunteers",
    "welcome",
    "partner",
    "partners",
    "close",
];
/// Who gets thanked when someone else takes over from the preacher.
const PREACHER: &[&str] = &["apostle", "pastor", "bishop", "reverend"];
/// A short sentence of only these words right after the cue still belongs to
/// the preacher's sign-off ("Thank you, Jesus.", "Hallelujah!").
const PRAISE: &[&str] = &[
    "thank",
    "you",
    "jesus",
    "lord",
    "father",
    "hallelujah",
    "amen",
    "glory",
    "to",
    "god",
    "praise",
    "the",
    "bless",
    "yes",
];
/// How far (seconds) to look before and after a cue for its context.
const CONTEXT: f64 = 150.0;
/// How far (seconds) before a cue an "in Jesus' name" counts as its prayer.
const NAME_CONTEXT: f64 = 60.0;

pub fn norm(w: &str) -> String {
    w.chars()
        .filter(|c| c.is_alphabetic() || *c == '\'')
        .flat_map(|c| c.to_lowercase())
        .collect::<String>()
        .replace('\'', "")
}

fn ends_sentence(w: &str) -> bool {
    w.trim_end_matches(['"', '\'', ')'])
        .ends_with(['.', '!', '?'])
}

fn has_seq(normed: &[String], seq: &[&str]) -> bool {
    normed
        .windows(seq.len())
        .any(|w| w.iter().zip(seq).all(|(a, b)| a == b))
}

#[derive(Debug, Clone, Serialize)]
pub struct Cue {
    /// When the seat phrase starts, seconds into the stream.
    pub at: f64,
    /// The proposed Out point: the end of the phrase, or of a short praise
    /// sentence straight after it.
    pub out: f64,
    /// The words around the cue, for the Review screen.
    pub context: String,
    /// A prayer closed just before it: "prayed" or "amen" in the 150 s
    /// before, or "in Jesus' name" in the 60 s before.
    pub after_prayer: bool,
    /// The offering or announcements are named in the 150 s after it.
    pub before_offering: bool,
    /// A weaker sign of moving on ("give", "welcome", ...) in the 150 s after.
    pub before_next_part: bool,
}

/// Every seat cue in `words` (which must be in time order).
pub fn find_cues(words: &[Word]) -> Vec<Cue> {
    let normed: Vec<String> = words.iter().map(|w| norm(&w.text)).collect();
    let phrase_at = |i: usize| {
        SEAT_PHRASES
            .iter()
            .find(|p| {
                i + p.len() <= normed.len()
                    && p.iter().enumerate().all(|(k, w)| normed[i + k] == *w)
            })
            .map(|p| p.len())
            // whisper sometimes drops "please be" and keeps only "seated.",
            // as on Sept 20, so a sentence ending in "seated" counts too.
            .or_else(|| (normed[i] == "seated" && ends_sentence(&words[i].text)).then_some(1))
    };
    let span = |a: f64, b: f64| {
        let lo = words.partition_point(|w| w.start < a);
        let hi = words.partition_point(|w| w.start <= b);
        &normed[lo..hi.max(lo)]
    };
    let mut cues = Vec::new();
    let mut i = 0;
    while i < words.len() {
        let Some(len) = phrase_at(i) else {
            i += 1;
            continue;
        };
        let mut last = i + len - 1;
        loop {
            // Keep up to two short praise sentences that follow.
            for _ in 0..2 {
                let mut j = last + 1;
                while j < words.len() && !ends_sentence(&words[j].text) && j - last <= 4 {
                    j += 1;
                }
                let sentence = (last + 1)..(j + 1).min(words.len());
                let len = sentence.len();
                if len == 0
                    || len > 4
                    || !normed[sentence.clone()]
                        .iter()
                        .all(|w| PRAISE.contains(&w.as_str()))
                {
                    break;
                }
                last = sentence.end - 1;
            }
            // "Take your seats, please be seated" is one cue: carry on
            // through a second seat phrase that follows straight away.
            let again = (last + 1..(last + 4).min(words.len()))
                .find(|k| words[*k].start - words[last].end <= 4.0 && phrase_at(*k).is_some());
            match again {
                Some(k) => last = k + phrase_at(k).unwrap_or(1) - 1,
                None => break,
            }
        }
        let (at, out) = (words[i].start, words[last].end);
        let before = span(at - CONTEXT, at - 1e-6);
        let just_before = span(at - NAME_CONTEXT, at - 1e-6);
        let after = span(out + 1e-6, out + CONTEXT);
        let after_prayer = before.iter().any(|w| CLOSERS.contains(&w.as_str()))
            || IN_JESUS_NAME.iter().any(|s| has_seq(just_before, s));
        let before_offering = after.iter().any(|w| OFFERING.contains(&w.as_str()));
        let before_next_part =
            before_offering || after.iter().any(|w| MOVING_ON.contains(&w.as_str()));
        let lo = i.saturating_sub(8);
        let hi = (last + 9).min(words.len());
        let context = words[lo..hi]
            .iter()
            .map(|w| w.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        cues.push(Cue {
            at,
            out,
            context,
            after_prayer,
            before_offering,
            before_next_part,
        });
        i = last + 1;
    }
    cues
}

/// Picks the Out cue: the first at or after `not_before` that either leads
/// into the offering or follows a prayer and leads somewhere new. It is
/// "high" when it does both (a prayer before, the offering after), else
/// "medium".
pub fn choose(cues: &[Cue], not_before: f64) -> Option<(Cue, &'static str)> {
    let c = cues.iter().find(|c| {
        c.at >= not_before && (c.before_offering || (c.after_prayer && c.before_next_part))
    })?;
    let confidence = if c.after_prayer && c.before_offering {
        "high"
    } else {
        "medium"
    };
    Some((c.clone(), confidence))
}

/// When someone else thanked the preacher between his closing prayer and
/// the seat cue (Oct 4: "... we have prayed. Can we say a very big thank you
/// to our apostle ..."), the preacher's part ended at that prayer. Returns
/// the end of the prayer's last closing word.
pub fn handover_before(words: &[Word], cue: &Cue) -> Option<f64> {
    let lo = words.partition_point(|w| w.start < cue.at - CONTEXT);
    let hi = words.partition_point(|w| w.start < cue.at);
    let normed: Vec<String> = words[lo..hi].iter().map(|w| norm(&w.text)).collect();
    let close = normed.iter().rposition(|w| CLOSERS.contains(&w.as_str()))?;
    let thanked = (close + 1..normed.len()).any(|k| {
        PREACHER.contains(&normed[k].as_str())
            && normed[k.saturating_sub(8)..k]
                .iter()
                .any(|w| w == "thank" || w == "thanks" || w == "appreciate")
    });
    thanked.then(|| words[lo + close].end)
}

/// When nobody said to sit: the last prayer close ("... we have prayed",
/// "amen") before the offering starts.
pub fn prayer_close_before_offering(words: &[Word], not_before: f64) -> Option<f64> {
    let first = words
        .iter()
        .filter(|w| w.start >= not_before && OFFERING.contains(&norm(&w.text).as_str()))
        .map(|w| w.start)
        .next()?;
    words
        .iter()
        .filter(|w| {
            w.start >= first - CONTEXT
                && w.start < first
                && CLOSERS.contains(&norm(&w.text).as_str())
        })
        .map(|w| w.end)
        .next_back()
}

/// Seconds of stream heard at a time.
pub const WINDOW: f64 = 600.0;
/// The Out comes at least this long (seconds) after the preacher starts.
pub const EARLIEST_OUT: f64 = 25.0 * 60.0;

/// Hears the stream window by window from `from`, stopping once the Out
/// cue (see [`choose`]) has been heard together with its 150 s of context,
/// or at `until`. `hear(a, len)` returns the words of [a, a + len);
/// windows already in `t` are not heard again. `after_window(t, b)` runs
/// after each window (to save the words and report progress). Returns how
/// far it heard. With `to_the_end` it hears all the way to `until` (for
/// scoring).
pub fn listen_for_out(
    t: &mut Transcript,
    not_before: f64,
    from: f64,
    until: f64,
    to_the_end: bool,
    mut hear: impl FnMut(f64, f64) -> Result<Vec<Word>>,
    mut after_window: impl FnMut(&Transcript, f64) -> Result<()>,
) -> Result<f64> {
    let mut a = from;
    loop {
        let b = (a + WINDOW).min(until);
        if b <= a {
            return Ok(a);
        }
        if !t.covers(a, b) {
            let words = hear(a, b - a)?;
            t.add(a, b, words);
        }
        after_window(t, b)?;
        if !to_the_end {
            let heard: Vec<Word> = t.words.iter().filter(|w| w.start < b).cloned().collect();
            if let Some((c, _)) = choose(&find_cues(&heard), not_before) {
                // The first fitting cue can't be displaced by anything heard
                // later, once its own context is complete.
                if c.out + CONTEXT <= b {
                    return Ok(b);
                }
            }
        }
        if b >= until {
            return Ok(b);
        }
        a = b;
    }
}

/// whisper.cpp's word times can drift by a few seconds deep into a 10-minute
/// window, so the chosen cue is heard again on its own, from this many
/// seconds before it, for `RETIME_LEN` seconds.
pub const RETIME_BEFORE: f64 = 45.0;
pub const RETIME_LEN: f64 = 90.0;

/// The window to hear again for `cue`.
pub fn retime_window(cue: &Cue) -> (f64, f64) {
    ((cue.at - RETIME_BEFORE).max(0.0), RETIME_LEN)
}

/// Re-times a seat-cue Out from the words of its retime window: the cue
/// heard there nearest the original (within 10 s) gives the Out. Leaves `f`
/// as it was when the cue isn't heard again or the Out isn't a seat cue.
pub fn retime(f: &mut OutFinding, words: &[Word]) {
    if f.method != "seat_cue" {
        return;
    }
    let Some(cue) = &mut f.cue else { return };
    let again = find_cues(words)
        .into_iter()
        .filter(|c| (c.at - cue.at).abs() <= 10.0)
        .min_by(|a, b| (a.at - cue.at).abs().total_cmp(&(b.at - cue.at).abs()));
    if let Some(c) = again {
        f.retimed_by = Some(c.out - cue.out);
        cue.at = c.at;
        cue.out = c.out;
        f.out = c.out;
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct OutFinding {
    /// Seconds into the stream.
    pub out: f64,
    pub confidence: &'static str,
    /// "seat_cue", "prayer_before_handover", "prayer_close" or
    /// "speech_run_end".
    pub method: &'static str,
    /// The seat cue the Out was taken from or found near.
    pub cue: Option<Cue>,
    /// Every seat cue heard after `not_before`, for the Review screen.
    pub cues: Vec<Cue>,
    /// How far (seconds) hearing the cue again on its own moved the Out.
    pub retimed_by: Option<f64>,
}

/// Decides the Out from the words heard: the seat cue that leads into the
/// offering (or the closing prayer before it, when someone else took over
/// in between), else the prayer close before the offering, else `fallback`
/// (the end of the sermon's run of speech).
pub fn decide(words: &[Word], not_before: f64, fallback: f64) -> OutFinding {
    let cues: Vec<Cue> = find_cues(words)
        .into_iter()
        .filter(|c| c.at >= not_before)
        .collect();
    let found = |out, confidence, method, cue| OutFinding {
        out,
        confidence,
        method,
        cue,
        cues: cues.clone(),
        retimed_by: None,
    };
    if let Some((c, confidence)) = choose(&cues, not_before) {
        if let Some(out) = handover_before(words, &c) {
            return found(out, "medium", "prayer_before_handover", Some(c));
        }
        return found(c.out, confidence, "seat_cue", Some(c));
    }
    if let Some(out) = prayer_close_before_offering(words, not_before) {
        return found(out, "low", "prayer_close", None);
    }
    found(fallback, "low", "speech_run_end", None)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Words spaced 0.4 s apart from `t0`.
    fn say(t0: f64, text: &str) -> Vec<Word> {
        text.split_whitespace()
            .enumerate()
            .map(|(i, w)| Word {
                start: t0 + i as f64 * 0.4,
                end: t0 + i as f64 * 0.4 + 0.4,
                text: w.into(),
            })
            .collect()
    }

    fn joined(parts: &[(f64, &str)]) -> Vec<Word> {
        parts.iter().flat_map(|(t, s)| say(*t, s)).collect()
    }

    #[test]
    fn oct_11_keeps_thank_you_jesus() {
        // As heard on Oct 11 around 2:29:12.
        let w = joined(&[
            (8930.0, "May this nation recognize itself blessed. Thank you, Father. In Jesus mighty name we've prayed."),
            (8946.0, "If we were blessed, say loud amen to somebody. Hallelujah! God bless you. Please be seated."),
            (8956.2, "Thank you, Jesus."),
            (8960.2, "Oh my God. Important, important, important sermon right there."),
            (8980.0, "Now, I want to make an open call. Please fill that link anyway."),
        ]);
        let cues = find_cues(&w);
        assert_eq!(cues.len(), 1);
        let (c, conf) = choose(&cues, 0.0).unwrap();
        // A prayer before, and only a link (not the offering) after: the
        // offering came three minutes later that Sunday.
        assert_eq!(conf, "medium");
        // Out = end of "Jesus." (third word from 8956.2).
        assert!((c.out - (8956.2 + 1.2)).abs() < 1e-9, "{}", c.out);
        assert!(c.context.contains("Please be seated."));
    }

    #[test]
    fn sept_13_stops_before_the_offering() {
        let w = joined(&[
            (7426.0, "For in Jesus mighty name we have prayed, amen, hallelujah."),
            (7446.7, "Glory to God, I'd like us to take our seats. Please be seated. Let's package our offerings."),
        ]);
        let cues = find_cues(&w);
        assert_eq!(cues.len(), 1, "{cues:?}");
        let (c, conf) = choose(&cues, 0.0).unwrap();
        assert_eq!(conf, "high");
        // One cue from "take our seats" through "be seated.", the 13th word.
        assert!(
            (c.out - (7446.7 + 12.0 * 0.4 + 0.4)).abs() < 1e-9,
            "{}",
            c.out
        );
    }

    #[test]
    fn a_mid_sermon_sit_down_without_offering_is_not_preferred() {
        let mut w = joined(&[(1000.0, "Everybody stand up and shout. Now you may sit down. Let us continue in the book of Acts.")]);
        w.extend(joined(&[(
            5000.0,
            "In Jesus name we have prayed. Amen. Please be seated. It's time for the offering.",
        )]));
        let (c, conf) = choose(&find_cues(&w), 0.0).unwrap();
        assert_eq!(conf, "high");
        assert!(c.at > 5000.0);
    }

    #[test]
    fn oct_4_ends_at_the_prayer_before_a_handover() {
        // As heard on Oct 4 from 2:22:12.
        let w = joined(&[
            (8530.0, "In Jesus mighty name we have prayed."),
            (8538.7, "Can we say a very big thank you to our apostle. Thank you apostle for such an instructive word. God bless you sir. Hallelujah. It's time to give to the work of God."),
            (8570.0, "We know very much that giving. Can we be seated please? Glory to God. Giving is part of our worship."),
        ]);
        let d = decide(&w, 0.0, 9000.0);
        assert_eq!(
            (d.method, d.confidence),
            ("prayer_before_handover", "medium")
        );
        // End of "prayed.", the 7th word.
        assert!(
            (d.out - (8530.0 + 6.0 * 0.4 + 0.4)).abs() < 1e-9,
            "{}",
            d.out
        );
        // Re-timing leaves a prayer-close Out alone.
        let mut e = d.clone();
        retime(&mut e, &joined(&[(8575.0, "Can we be seated please?")]));
        assert_eq!(e.out, d.out);
    }

    #[test]
    fn sept_20_lone_seated_after_in_jesus_mighty() {
        // whisper dropped "name we have prayed, please be" that Sunday.
        let w = joined(&[
            (10600.0, "But the power of the Holy Ghost in Jesus mighty seated."),
            (10620.0, "Now I want us to be as quick as possible as we give our offerings."),
            (10690.0, "In Jesus' mighty, marvelous name, Amen. God bless you. Please be seated. The offering details are on the screen."),
        ]);
        let d = decide(&w, 0.0, 12000.0);
        assert_eq!((d.method, d.confidence), ("seat_cue", "high"));
        // The first cue, ending at "seated.", the 11th word.
        assert!(
            (d.out - (10600.0 + 10.0 * 0.4 + 0.4)).abs() < 1e-9,
            "{}",
            d.out
        );
        assert_eq!(d.cues.len(), 2);
    }

    #[test]
    fn prayer_close_before_the_offering_when_nobody_says_sit() {
        let w = joined(&[(8537.4, "In Jesus' mighty name we have prayed. And we say a very big thank you. It is time for the offering.")]);
        assert!(find_cues(&w).is_empty());
        let d = decide(&w, 0.0, 9000.0);
        assert_eq!((d.method, d.confidence), ("prayer_close", "low"));
        assert!(
            (d.out - (8537.4 + 6.0 * 0.4 + 0.4)).abs() < 1e-9,
            "{}",
            d.out
        );
    }

    #[test]
    fn listening_stops_once_the_cue_and_its_context_are_heard() {
        let all = joined(&[
            (2000.0, "Let us pray. Amen. You may sit down."), // too early to count
            (
                5000.0,
                "In Jesus name we have prayed. Amen. Please be seated.",
            ),
            (5100.0, "Now it's time for the offering."),
            (7000.0, "Welcome to everyone. Please be seated."),
        ]);
        let mut t = Transcript::default();
        let mut heard = Vec::new();
        let until = listen_for_out(
            &mut t,
            3500.0,
            3500.0,
            9000.0,
            false,
            |a, len| {
                heard.push(a);
                Ok(all
                    .iter()
                    .filter(|w| w.start >= a - 5.0 && w.start < a + len)
                    .cloned()
                    .collect())
            },
            |_, _| Ok(()),
        )
        .unwrap();
        // Windows from 3500: [3500, 4100), [4100, 4700), [4700, 5300). The
        // cue at ~5010 needs words to ~5160, so it stops after the third.
        assert_eq!(heard, [3500.0, 4100.0, 4700.0]);
        assert_eq!(until, 5300.0);
        let d = decide(&t.words, 3500.0, 6000.0);
        assert_eq!((d.method, d.confidence), ("seat_cue", "high"));
        assert!(d.out > 5000.0 && d.out < 5010.0, "{}", d.out);

        // A second look hears nothing new.
        let mut again = 0;
        listen_for_out(
            &mut t,
            3500.0,
            3500.0,
            9000.0,
            false,
            |_, _| {
                again += 1;
                Ok(vec![])
            },
            |_, _| Ok(()),
        )
        .unwrap();
        assert_eq!(again, 0);
    }

    #[test]
    fn retiming_moves_the_out_to_the_short_window() {
        let long = joined(&[
            (
                8946.0,
                "In Jesus name we have prayed. Amen. God bless you, please be seated.",
            ),
            (8970.0, "Fill that link."),
        ]);
        let mut f = decide(&long, 0.0, 9500.0);
        let (from, len) = retime_window(f.cue.as_ref().unwrap());
        assert_eq!((from, len), (f.cue.as_ref().unwrap().at - 45.0, 90.0));
        // Heard alone, the same words land 3 s later.
        let short = joined(&[(
            8949.0,
            "In Jesus name we have prayed. Amen. God bless you, please be seated.",
        )]);
        let before = f.out;
        retime(&mut f, &short);
        assert!((f.out - before - 3.0).abs() < 1e-9);
        assert!((f.retimed_by.unwrap() - 3.0).abs() < 1e-9);
        // Not heard again: unchanged.
        let mut g = decide(&long, 0.0, 9500.0);
        retime(&mut g, &joined(&[(8949.0, "music")]));
        assert_eq!((g.out, g.retimed_by), (before, None));
    }

    #[test]
    fn decide_falls_back_to_the_speech_run() {
        let d = decide(
            &joined(&[(5000.0, "and so we go on with the story")]),
            0.0,
            6100.0,
        );
        assert_eq!(
            (d.method, d.confidence, d.out),
            ("speech_run_end", "low", 6100.0)
        );
    }

    #[test]
    fn norm_strips_punctuation_and_case() {
        assert_eq!(norm("Seated."), "seated");
        assert_eq!(norm("Jesus'"), "jesus");
        assert_eq!(norm("I'd"), "id");
    }
}

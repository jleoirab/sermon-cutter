//! Banner and fade timings for the two ends of the cut.
//!
//! Defaults come from the Oct 4 and Oct 11, 2026 reference cuts; every value
//! is adjustable per Sunday.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};

/// One end of the cut.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum End {
    Opening,
    Closing,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Timings {
    /// Seconds the banner covers the footage, fully opaque, at the start.
    pub open_hold: f64,
    /// Seconds each banner dissolve takes, at both ends.
    pub dissolve: f64,
    /// Seconds the banner covers the footage, fully opaque, at the end.
    pub close_hold: f64,
    /// Seconds the audio takes to rise from silence, starting on the first frame.
    pub fade_in: f64,
    /// Seconds the audio takes to fall to silence, ending on the last frame.
    pub fade_out: f64,
    /// Whether the banner covers the start at all (off when previewing only
    /// the closing).
    #[serde(default = "on")]
    pub opening: bool,
    /// Whether the banner covers the end at all (off when previewing only the
    /// opening).
    #[serde(default = "on")]
    pub closing: bool,
}

fn on() -> bool {
    true
}

impl Default for Timings {
    fn default() -> Self {
        Timings {
            open_hold: 8.0,
            dissolve: 0.5,
            close_hold: 6.0,
            fade_in: 4.0,
            fade_out: 3.0,
            opening: true,
            closing: true,
        }
    }
}

impl Timings {
    /// True when the opening banner appears at all.
    pub fn has_opening(&self) -> bool {
        self.opening && self.open_hold + self.dissolve > 0.0
    }

    /// True when the closing banner appears at all.
    pub fn has_closing(&self) -> bool {
        self.closing && self.close_hold + self.dissolve > 0.0
    }

    /// The timings for a preview of just one end: the other end's banner and
    /// fade are left off.
    pub fn only(self, end: End) -> Timings {
        match end {
            End::Opening => Timings {
                closing: false,
                fade_out: 0.0,
                ..self
            },
            End::Closing => Timings {
                opening: false,
                fade_in: 0.0,
                ..self
            },
        }
    }

    /// Checks the timings make sense for a cut of `cut_len` seconds.
    pub fn validate(&self, cut_len: f64) -> Result<()> {
        let named = [
            ("open hold", self.open_hold),
            ("dissolve", self.dissolve),
            ("close hold", self.close_hold),
            ("fade in", self.fade_in),
            ("fade out", self.fade_out),
        ];
        for (name, v) in named {
            if !(v.is_finite() && v >= 0.0) {
                bail!("{name} must be zero or more seconds, got {v}");
            }
        }
        if !(cut_len.is_finite() && cut_len > 0.0) {
            bail!("the cut must be longer than zero seconds");
        }
        let opening = if self.has_opening() {
            self.open_hold + self.dissolve
        } else {
            0.0
        };
        let closing = if self.has_closing() {
            self.close_hold + self.dissolve
        } else {
            0.0
        };
        if opening + closing > cut_len {
            bail!(
                "the banners need {:.1} s but the cut is only {:.1} s; shorten the holds or widen In and Out",
                opening + closing,
                cut_len
            );
        }
        if self.fade_in + self.fade_out > cut_len {
            bail!(
                "the audio fades need {:.1} s but the cut is only {:.1} s",
                self.fade_in + self.fade_out,
                cut_len
            );
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_fit_a_sermon() {
        Timings::default().validate(75.0 * 60.0).unwrap();
    }

    #[test]
    fn rejects_overlapping_banners() {
        let t = Timings::default();
        assert!(t.validate(14.0).is_err()); // 8.5 + 6.5 = 15 > 14
        assert!(t.validate(15.0).is_ok());
    }

    #[test]
    fn rejects_negative_and_nan() {
        let t = Timings {
            dissolve: -1.0,
            ..Default::default()
        };
        assert!(t.validate(100.0).is_err());
        let t = Timings {
            fade_in: f64::NAN,
            ..Default::default()
        };
        assert!(t.validate(100.0).is_err());
    }

    #[test]
    fn a_preview_leaves_the_other_end_off() {
        let t = Timings::default().only(End::Opening);
        assert!(t.has_opening() && !t.has_closing());
        assert_eq!(t.fade_out, 0.0);
        // 8.5 s of opening fits a 10 s preview once the closing is off.
        t.validate(10.0).unwrap();
        let c = Timings::default().only(End::Closing);
        assert!(!c.has_opening() && c.has_closing() && c.fade_in == 0.0);
    }

    #[test]
    fn zero_holds_mean_no_banner() {
        let t = Timings {
            open_hold: 0.0,
            dissolve: 0.0,
            close_hold: 0.0,
            ..Default::default()
        };
        assert!(!t.has_opening());
        assert!(!t.has_closing());
        t.validate(10.0).unwrap();
    }
}

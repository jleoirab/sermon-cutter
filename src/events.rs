//! Events the engine reports while it works.
//!
//! The command-line tool writes each event as one JSON object per line on
//! standard output, for example:
//!
//! ```text
//! {"event":"progress","step":"render","fraction":0.42,"eta_s":51.2}
//! {"event":"result","step":"render","data":{"output":"/path/sermon.mp4"}}
//! {"event":"error","step":"render","message":"ffmpeg failed: ..."}
//! ```

use serde::Serialize;
use serde_json::Value;
use std::io::Write;
use std::sync::Mutex;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    /// Work in progress. `fraction` runs from 0 to 1 within one step.
    Progress {
        step: String,
        fraction: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        eta_s: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    /// Something worth showing a person, but not a failure.
    Log { level: String, message: String },
    /// The outcome of a step.
    Result { step: String, data: Value },
    /// The step failed.
    Error { step: String, message: String },
}

impl Event {
    pub fn progress(step: &str, fraction: f64, eta_s: Option<f64>, detail: Option<String>) -> Self {
        Event::Progress {
            step: step.to_string(),
            fraction: fraction.clamp(0.0, 1.0),
            eta_s: eta_s.filter(|e| e.is_finite() && *e >= 0.0).map(round1),
            detail,
        }
    }

    pub fn log(level: &str, message: impl Into<String>) -> Self {
        Event::Log {
            level: level.to_string(),
            message: message.into(),
        }
    }

    pub fn result(step: &str, data: Value) -> Self {
        Event::Result {
            step: step.to_string(),
            data,
        }
    }

    pub fn error(step: &str, message: impl Into<String>) -> Self {
        Event::Error {
            step: step.to_string(),
            message: message.into(),
        }
    }
}

fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

/// Where events go.
pub trait Sink: Send + Sync {
    fn emit(&self, event: Event);
}

/// Writes events as JSON lines on standard output.
pub struct StdoutSink;

impl Sink for StdoutSink {
    fn emit(&self, event: Event) {
        let line = serde_json::to_string(&event).expect("events always serialise");
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
    }
}

/// Keeps events in memory; used by tests.
#[derive(Default)]
pub struct VecSink(pub Mutex<Vec<Event>>);

impl Sink for VecSink {
    fn emit(&self, event: Event) {
        self.0.lock().unwrap().push(event);
    }
}

impl VecSink {
    pub fn events(&self) -> Vec<Event> {
        self.0.lock().unwrap().clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn progress_serialises_as_one_flat_object() {
        let e = Event::progress("render", 0.4234, Some(51.234), None);
        let v = serde_json::to_value(&e).unwrap();
        assert_eq!(
            v,
            json!({"event": "progress", "step": "render", "fraction": 0.4234, "eta_s": 51.2})
        );
    }

    #[test]
    fn fraction_is_clamped_and_bad_eta_dropped() {
        let e = Event::progress("render", 1.7, Some(f64::NAN), None);
        let v = serde_json::to_value(&e).unwrap();
        assert_eq!(
            v,
            json!({"event": "progress", "step": "render", "fraction": 1.0})
        );
    }
}

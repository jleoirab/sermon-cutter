//! Finding the helper programs the engine runs.
//!
//! Each tool is looked up, in order:
//! 1. an environment variable naming the exact file (`SERMONCUT_FFMPEG`, ...),
//! 2. the app's tools folder (kept outside the signed app so it can update yt-dlp),
//! 3. the `PATH`.

use anyhow::{anyhow, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
pub struct Tools {
    pub tools_dir: Option<PathBuf>,
    pub ffmpeg: Option<PathBuf>,
    pub ffprobe: Option<PathBuf>,
    pub ytdlp: Option<PathBuf>,
    pub deno: Option<PathBuf>,
    /// whisper.cpp's command-line tool, for hearing the "have your seats" cue.
    pub whisper: Option<PathBuf>,
    /// The speech model whisper.cpp uses.
    pub whisper_model: Option<PathBuf>,
}

/// Speech models to look for in `<tools folder>/models`, best first.
pub const WHISPER_MODELS: &[&str] = &[
    "ggml-small.en-q8_0.bin",
    "ggml-small.en.bin",
    "ggml-small.en-q5_1.bin",
    "ggml-base.en.bin",
    "ggml-base.en-q8_0.bin",
];

impl Tools {
    /// Looks up every tool, using `tools_dir` or the default tools folder.
    pub fn locate(tools_dir: Option<PathBuf>) -> Tools {
        let dir = tools_dir.or_else(default_tools_dir);
        let d = dir.as_deref();
        let whisper_model = std::env::var_os("SERMONCUT_WHISPER_MODEL")
            .map(PathBuf::from)
            .filter(|p| p.is_file())
            .or_else(|| {
                let models = d?.join("models");
                WHISPER_MODELS.iter().map(|m| models.join(m)).find(|p| p.is_file())
            });
        Tools {
            ffmpeg: find(&["ffmpeg"], "SERMONCUT_FFMPEG", d),
            ffprobe: find(&["ffprobe"], "SERMONCUT_FFPROBE", d),
            ytdlp: find(&["yt-dlp", "yt-dlp_macos"], "SERMONCUT_YTDLP", d),
            deno: find(&["deno"], "SERMONCUT_DENO", d),
            whisper: find(&["whisper-cli", "whisper-cpp"], "SERMONCUT_WHISPER", d),
            whisper_model,
            tools_dir: dir,
        }
    }

    pub fn whisper(&self) -> Result<&Path> {
        self.whisper
            .as_deref()
            .ok_or_else(|| self.missing("whisper-cli (whisper.cpp)", "SERMONCUT_WHISPER"))
    }

    pub fn whisper_model(&self) -> Result<&Path> {
        self.whisper_model.as_deref().ok_or_else(|| {
            let models = self
                .tools_dir
                .as_ref()
                .map(|d| d.join("models").display().to_string())
                .unwrap_or_else(|| "the tools folder's models folder".into());
            anyhow!("no speech model found; put ggml-small.en-q8_0.bin in {models} or set SERMONCUT_WHISPER_MODEL")
        })
    }

    pub fn ffmpeg(&self) -> Result<&Path> {
        self.ffmpeg
            .as_deref()
            .ok_or_else(|| self.missing("ffmpeg", "SERMONCUT_FFMPEG"))
    }

    pub fn ffprobe(&self) -> Result<&Path> {
        self.ffprobe
            .as_deref()
            .ok_or_else(|| self.missing("ffprobe", "SERMONCUT_FFPROBE"))
    }

    pub fn ytdlp(&self) -> Result<&Path> {
        self.ytdlp
            .as_deref()
            .ok_or_else(|| self.missing("yt-dlp", "SERMONCUT_YTDLP"))
    }

    fn missing(&self, name: &str, var: &str) -> anyhow::Error {
        let dir = self
            .tools_dir
            .as_ref()
            .map(|d| format!("the tools folder ({})", d.display()))
            .unwrap_or_else(|| "the tools folder".to_string());
        anyhow!("{name} was not found; put it in {dir}, set {var} to its path, or add it to PATH")
    }
}

/// The app's tools folder on this system.
pub fn default_tools_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        home().map(|h| h.join("Library/Application Support/Sermon Cutter/bin"))
    }
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Sermon Cutter").join("bin"))
    }
    #[cfg(all(not(windows), not(target_os = "macos")))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| home().map(|h| h.join(".local/share")))
            .map(|d| d.join("sermon-cutter/bin"))
    }
}

#[cfg(not(windows))]
fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Finds the first of `names` via `env_var`, then `dir`, then the `PATH`.
pub fn find(names: &[&str], env_var: &str, dir: Option<&Path>) -> Option<PathBuf> {
    if let Some(p) = std::env::var_os(env_var).map(PathBuf::from) {
        if is_executable(&p) {
            return Some(p);
        }
    }
    let with_suffix = |n: &str| format!("{n}{}", std::env::consts::EXE_SUFFIX);
    if let Some(d) = dir {
        for n in names {
            let p = d.join(with_suffix(n));
            if is_executable(&p) {
                return Some(p);
            }
        }
    }
    let path = std::env::var_os("PATH")?;
    for d in std::env::split_paths(&path) {
        for n in names {
            let p = d.join(with_suffix(n));
            if is_executable(&p) {
                return Some(p);
            }
        }
    }
    None
}

fn is_executable(p: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        p.metadata()
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        p.is_file()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn tools_folder_wins_over_path() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("yt-dlp_macos");
        std::fs::write(&fake, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        let found = find(
            &["yt-dlp", "yt-dlp_macos"],
            "SERMONCUT_TEST_UNSET_VAR",
            Some(dir.path()),
        );
        assert_eq!(found, Some(fake));
    }

    #[cfg(unix)]
    #[test]
    fn non_executable_files_are_skipped() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("deno"), "not a program").unwrap();
        let found = find(
            &["deno-that-does-not-exist-anywhere"],
            "SERMONCUT_TEST_UNSET_VAR",
            Some(dir.path()),
        );
        assert_eq!(found, None);
        let found = find(&["deno"], "SERMONCUT_TEST_UNSET_VAR", Some(dir.path()));
        assert_ne!(found, Some(dir.path().join("deno")));
    }
}

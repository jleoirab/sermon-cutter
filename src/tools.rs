//! Finding the helper programs the engine runs.
//!
//! The Mac app carries every helper inside itself, next to the engine
//! (`CCI Sermon Cutter.app/Contents/Helpers`), and the speech model in
//! `Contents/Resources/models`. yt-dlp is the exception that has to change
//! after install, since YouTube keeps breaking old copies: the app keeps a
//! copy it can update in its own folder, `~/Library/Application Support/CCI
//! Sermon Cutter/bin` (see [`update_ytdlp`]).
//!
//! Each tool is looked up, in order:
//! 1. an environment variable naming the exact file (`SERMONCUT_FFMPEG`, ...),
//! 2. the folders above: for yt-dlp the updatable copy first, for the rest
//!    the copy inside the app first,
//! 3. the `PATH` (for running the engine by hand during development).

use crate::run;
use anyhow::{anyhow, bail, Context, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
pub struct Tools {
    /// The app's own folder for helpers it updates (yt-dlp).
    pub tools_dir: Option<PathBuf>,
    /// The folder the engine itself is in: inside the app, its helpers.
    pub bundle_dir: Option<PathBuf>,
    pub ffmpeg: Option<PathBuf>,
    pub ffprobe: Option<PathBuf>,
    pub ytdlp: Option<PathBuf>,
    pub deno: Option<PathBuf>,
    /// whisper.cpp's command-line tool, for hearing the "have your seats" cue.
    pub whisper: Option<PathBuf>,
    /// The speech model whisper.cpp uses.
    pub whisper_model: Option<PathBuf>,
}

/// Speech models to look for, best first.
pub const WHISPER_MODELS: &[&str] = &[
    "ggml-small.en-q8_0.bin",
    "ggml-small.en.bin",
    "ggml-small.en-q5_1.bin",
    "ggml-base.en.bin",
    "ggml-base.en-q8_0.bin",
];

/// yt-dlp's names: as the app carries it, and as yt-dlp publishes it.
const YTDLP_NAMES: &[&str] = &["yt-dlp", "yt-dlp_macos"];

impl Tools {
    /// Looks up every tool, using `tools_dir` or the default tools folder,
    /// and the folder the engine is in.
    pub fn locate(tools_dir: Option<PathBuf>) -> Tools {
        Tools::locate_in(tools_dir.or_else(default_tools_dir), engine_dir())
    }

    /// Looks up every tool given the updatable tools folder and the folder
    /// of helpers that came with the app.
    pub fn locate_in(tools_dir: Option<PathBuf>, bundle_dir: Option<PathBuf>) -> Tools {
        let t = tools_dir.as_deref();
        let b = bundle_dir.as_deref();
        let bundled_first: Vec<&Path> = [b, t].into_iter().flatten().collect();
        let updatable_first: Vec<&Path> = [t, b].into_iter().flatten().collect();
        let whisper_model = std::env::var_os("SERMONCUT_WHISPER_MODEL")
            .map(PathBuf::from)
            .filter(|p| p.is_file())
            .or_else(|| {
                model_dirs(b, t)
                    .into_iter()
                    .flat_map(|d| WHISPER_MODELS.iter().map(move |m| d.join(m)))
                    .find(|p| p.is_file())
            });
        Tools {
            ffmpeg: find(&["ffmpeg"], "SERMONCUT_FFMPEG", &bundled_first),
            ffprobe: find(&["ffprobe"], "SERMONCUT_FFPROBE", &bundled_first),
            ytdlp: find(YTDLP_NAMES, "SERMONCUT_YTDLP", &updatable_first),
            deno: find(&["deno"], "SERMONCUT_DENO", &bundled_first),
            whisper: find(
                &["whisper-cli", "whisper-cpp"],
                "SERMONCUT_WHISPER",
                &bundled_first,
            ),
            whisper_model,
            tools_dir,
            bundle_dir,
        }
    }

    pub fn whisper(&self) -> Result<&Path> {
        self.whisper
            .as_deref()
            .ok_or_else(|| self.missing("whisper-cli (whisper.cpp)", "SERMONCUT_WHISPER"))
    }

    pub fn whisper_model(&self) -> Result<&Path> {
        self.whisper_model.as_deref().ok_or_else(|| {
            anyhow!("no speech model found; the app carries ggml-small.en-q8_0.bin in Contents/Resources/models, or set SERMONCUT_WHISPER_MODEL")
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
        let place = match &self.bundle_dir {
            Some(d) => format!("the app's helpers ({})", d.display()),
            None => "the app's helpers".to_string(),
        };
        anyhow!("{name} was not found in {place}; reinstall the app, or set {var} to its path")
    }
}

/// Where a speech model may be: beside the helpers inside the app
/// (`Contents/Resources/models` for helpers in `Contents/Helpers`), then the
/// tools folder's `models`.
fn model_dirs(bundle: Option<&Path>, tools: Option<&Path>) -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(b) = bundle {
        if let Some(contents) = b.parent() {
            v.push(contents.join("Resources").join("models"));
        }
        v.push(b.join("models"));
    }
    if let Some(t) = tools {
        v.push(t.join("models"));
    }
    v
}

/// The folder the running engine is in.
fn engine_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe = exe.canonicalize().unwrap_or(exe);
    exe.parent().map(Path::to_path_buf)
}

/// The app's folder for helpers it keeps up to date.
pub fn default_tools_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        home().map(|h| h.join("Library/Application Support/CCI Sermon Cutter/bin"))
    }
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(|d| PathBuf::from(d).join("CCI Sermon Cutter").join("bin"))
    }
    #[cfg(all(not(windows), not(target_os = "macos")))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| home().map(|h| h.join(".local/share")))
            .map(|d| d.join("cci-sermon-cutter/bin"))
    }
}

#[cfg(not(windows))]
fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Finds the first of `names` via `env_var`, then in each of `dirs`, then
/// on the `PATH`.
pub fn find(names: &[&str], env_var: &str, dirs: &[&Path]) -> Option<PathBuf> {
    if let Some(p) = std::env::var_os(env_var).map(PathBuf::from) {
        if is_executable(&p) {
            return Some(p);
        }
    }
    let with_suffix = |n: &str| format!("{n}{}", std::env::consts::EXE_SUFFIX);
    for d in dirs {
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

/// What [`update_ytdlp`] did.
#[derive(Debug, Clone, Serialize)]
pub struct YtdlpUpdate {
    /// The copy the engine uses from now on.
    pub path: PathBuf,
    /// Its version, like "2026.10.21".
    pub version: Option<String>,
    /// The copy came from the app (first run, or the app is newer).
    pub copied_from_app: bool,
    /// yt-dlp downloaded a newer version of itself.
    pub updated: bool,
    /// Why the update didn't happen, when it didn't. The copy still works.
    pub problem: Option<String>,
}

/// yt-dlp's version, as `--version` prints it.
pub fn ytdlp_version(exe: &Path) -> Option<String> {
    let out = run::capture(exe, ["--version"]).ok()?;
    let v = out.stdout.trim().to_string();
    (out.ok && !v.is_empty()).then_some(v)
}

/// Compares yt-dlp versions ("2026.10.21", "2026.10.21.1") number by number.
pub fn newer(a: &str, b: &str) -> bool {
    let parts = |s: &str| -> Vec<u64> { s.split('.').map(|p| p.parse().unwrap_or(0)).collect() };
    parts(a) > parts(b)
}

/// Keeps the app's own copy of yt-dlp in `tools_dir`: copies the one inside
/// the app there when there's none yet or the app's is newer, then (when
/// `update`) lets yt-dlp update itself from GitHub.
pub fn update_ytdlp(tools_dir: &Path, bundled: Option<&Path>, update: bool) -> Result<YtdlpUpdate> {
    std::fs::create_dir_all(tools_dir)
        .with_context(|| format!("could not create {}", tools_dir.display()))?;
    let copy = tools_dir.join(format!("yt-dlp{}", std::env::consts::EXE_SUFFIX));
    let mut copied_from_app = false;
    if let Some(app) = bundled.filter(|p| is_executable(p)) {
        let refresh = if is_executable(&copy) {
            match (ytdlp_version(app), ytdlp_version(&copy)) {
                (Some(a), Some(c)) => newer(&a, &c),
                (Some(_), None) => true,
                _ => false,
            }
        } else {
            true
        };
        if refresh {
            // Copy beside it, then rename, so a half-copied file never runs.
            let part = tools_dir.join("yt-dlp.copying");
            std::fs::copy(app, &part)
                .with_context(|| format!("could not copy {}", app.display()))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o755))?;
            }
            std::fs::rename(&part, &copy)?;
            copied_from_app = true;
        }
    }
    if !is_executable(&copy) {
        bail!("there is no yt-dlp in the app to start from");
    }
    let before = ytdlp_version(&copy);
    let mut problem = None;
    if update {
        match run::capture(&copy, ["-U"]) {
            Ok(out) if out.ok => {}
            Ok(out) => problem = Some(run::tail(&format!("{}{}", out.stdout, out.stderr), 3)),
            Err(e) => problem = Some(format!("{e:#}")),
        }
    }
    let version = ytdlp_version(&copy);
    Ok(YtdlpUpdate {
        updated: update && version.is_some() && version != before,
        path: copy,
        version,
        copied_from_app,
        problem,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn program(dir: &Path, name: &str, script: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let p = dir.join(name);
        std::fs::write(&p, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    #[cfg(unix)]
    #[test]
    fn helpers_inside_the_app_win_except_yt_dlp() {
        let app = tempfile::tempdir().unwrap();
        let own = tempfile::tempdir().unwrap();
        for d in [app.path(), own.path()] {
            program(d, "ffmpeg", "");
            program(d, "yt-dlp", "");
        }
        let t = Tools::locate_in(Some(own.path().into()), Some(app.path().into()));
        assert_eq!(t.ffmpeg, Some(app.path().join("ffmpeg")));
        assert_eq!(t.ytdlp, Some(own.path().join("yt-dlp")));
    }

    #[cfg(unix)]
    #[test]
    fn the_app_s_model_is_found_beside_its_helpers() {
        let contents = tempfile::tempdir().unwrap();
        let helpers = contents.path().join("Helpers");
        let models = contents.path().join("Resources/models");
        std::fs::create_dir_all(&helpers).unwrap();
        std::fs::create_dir_all(&models).unwrap();
        std::fs::write(models.join("ggml-small.en-q8_0.bin"), "model").unwrap();
        let t = Tools::locate_in(None, Some(helpers));
        if std::env::var_os("SERMONCUT_WHISPER_MODEL").is_none() {
            assert_eq!(t.whisper_model, Some(models.join("ggml-small.en-q8_0.bin")));
        }
    }

    #[cfg(unix)]
    #[test]
    fn tools_folder_wins_over_path() {
        let dir = tempfile::tempdir().unwrap();
        let fake = program(dir.path(), "yt-dlp_macos", "");
        let found = find(YTDLP_NAMES, "SERMONCUT_TEST_UNSET_VAR", &[dir.path()]);
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
            &[dir.path()],
        );
        assert_eq!(found, None);
        let found = find(&["deno"], "SERMONCUT_TEST_UNSET_VAR", &[dir.path()]);
        assert_ne!(found, Some(dir.path().join("deno")));
    }

    #[test]
    fn versions_compare_number_by_number() {
        assert!(newer("2026.10.21", "2026.8.19"));
        assert!(newer("2026.10.21.1", "2026.10.21"));
        assert!(!newer("2026.10.21", "2026.10.21"));
        assert!(!newer("2026.07.04", "2026.10.21"));
    }

    #[cfg(unix)]
    #[test]
    fn yt_dlp_is_copied_out_of_the_app_and_kept_when_newer() {
        let app = tempfile::tempdir().unwrap();
        let own = tempfile::tempdir().unwrap();
        let bundled = program(app.path(), "yt-dlp", "echo 2026.10.21");
        // First run: copied from the app.
        let r = update_ytdlp(own.path(), Some(&bundled), false).unwrap();
        assert!(r.copied_from_app);
        assert_eq!(r.version.as_deref(), Some("2026.10.21"));
        // The copy has since updated itself: the app's older one leaves it be.
        program(own.path(), "yt-dlp", "echo 2026.11.30");
        let r = update_ytdlp(own.path(), Some(&bundled), false).unwrap();
        assert!(!r.copied_from_app);
        assert_eq!(r.version.as_deref(), Some("2026.11.30"));
        // A newer app brings a newer one than the copy: it replaces it.
        let bundled = program(app.path(), "yt-dlp", "echo 2026.12.24");
        let r = update_ytdlp(own.path(), Some(&bundled), false).unwrap();
        assert!(r.copied_from_app);
        assert_eq!(r.version.as_deref(), Some("2026.12.24"));
    }

    #[cfg(unix)]
    #[test]
    fn a_failed_update_still_leaves_a_working_copy() {
        let app = tempfile::tempdir().unwrap();
        let own = tempfile::tempdir().unwrap();
        let bundled = program(
            app.path(),
            "yt-dlp",
            r#"if [ "$1" = "-U" ]; then echo "ERROR: Unable to reach GitHub" >&2; exit 1; fi; echo 2026.10.21"#,
        );
        let r = update_ytdlp(own.path(), Some(&bundled), true).unwrap();
        assert!(!r.updated);
        assert!(r
            .problem
            .as_deref()
            .unwrap_or("")
            .contains("Unable to reach GitHub"));
        assert_eq!(r.version.as_deref(), Some("2026.10.21"));
    }
}

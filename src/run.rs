//! Running the helper programs (ffmpeg, ffprobe, yt-dlp).

use anyhow::{Context, Result};
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Command, Stdio};

/// What a finished program printed.
pub struct Captured {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
}

fn command(program: &Path) -> Command {
    #[allow(unused_mut)]
    let mut cmd = Command::new(program);
    cmd.stdin(Stdio::null());
    #[cfg(windows)]
    {
        // Keep a console window from flashing up when a GUI app drives the engine.
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// Runs a program to completion and captures what it printed.
pub fn capture<I, S>(program: &Path, args: I) -> Result<Captured>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let out = command(program)
        .args(args)
        .output()
        .with_context(|| format!("could not run {}", program.display()))?;
    Ok(Captured {
        ok: out.status.success(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

/// Runs a program, handing each line it prints on standard output to `on_line`
/// as it arrives. Returns whether it succeeded and everything it printed on
/// standard error.
pub fn stream<I, S, F>(program: &Path, args: I, mut on_line: F) -> Result<(bool, String)>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
    F: FnMut(&str),
{
    let mut child = command(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("could not run {}", program.display()))?;

    // Drain stderr on its own thread so a chatty program can never block on a full pipe.
    let mut stderr = child.stderr.take().expect("stderr is piped");
    let err_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr.read_to_end(&mut buf);
        String::from_utf8_lossy(&buf).into_owned()
    });

    let stdout = child.stdout.take().expect("stdout is piped");
    let mut reader = BufReader::new(stdout);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', &mut buf)?;
        if n == 0 {
            break;
        }
        let line = String::from_utf8_lossy(&buf);
        on_line(line.trim_end_matches(['\r', '\n']));
    }

    let status = child.wait()?;
    let err_text = err_reader.join().unwrap_or_default();
    Ok((status.success(), err_text))
}

/// The last `n` non-empty lines of a program's output, for error messages.
pub fn tail(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    lines[lines.len().saturating_sub(n)..].join(" | ")
}

#[cfg(test)]
mod tests {
    use super::tail;

    #[test]
    fn tail_keeps_last_lines() {
        assert_eq!(tail("a\n\nb\nc\n", 2), "b | c");
        assert_eq!(tail("", 3), "");
    }
}

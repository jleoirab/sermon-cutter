//! Drives the real yt-dlp against a file served on this machine, to prove the
//! progress and "where did it save" plumbing. YouTube itself is not contacted.
//! Needs yt-dlp, ffmpeg and python3; skipped otherwise.

use sermoncut::events::{Event, VecSink};
use sermoncut::fetch::{download, Part};
use sermoncut::tools::Tools;
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

#[test]
fn downloads_a_file_and_reports_where_it_went() {
    let tools = Tools::locate(None);
    let python = sermoncut::tools::find(&["python3"], "SERMONCUT_TEST_PYTHON", None);
    let (Some(ffmpeg), Some(_), Some(python)) = (tools.ffmpeg.clone(), tools.ytdlp.clone(), python)
    else {
        return eprintln!("skipped: needs yt-dlp, ffmpeg and python3");
    };

    let served = tempfile::tempdir().unwrap();
    let ok = Command::new(&ffmpeg)
        .args([
            "-v",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=30:duration=5",
            "-f",
            "lavfi",
            "-i",
        ])
        .args([
            "sine=frequency=440:duration=5",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-c:a",
            "aac",
            "-shortest",
        ])
        .arg(served.path().join("service.mp4"))
        .status()
        .unwrap()
        .success();
    assert!(ok);

    let port = free_port();
    let _server = Server(
        Command::new(python)
            .args([
                "-m",
                "http.server",
                &port.to_string(),
                "--bind",
                "127.0.0.1",
                "--directory",
            ])
            .arg(served.path())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(Instant::now() < deadline, "local server did not start");
        std::thread::sleep(Duration::from_millis(100));
    }

    let into = tempfile::tempdir().unwrap();
    let sink = VecSink::default();
    let url = format!("http://127.0.0.1:{port}/service.mp4");
    // "b" because a plain file has no separate audio and video renditions.
    let file =
        download(&tools, &url, into.path(), Part::Video, Some("b"), &sink).expect("download");

    assert!(file.exists(), "{} missing", file.display());
    assert!(
        file.starts_with(into.path()),
        "{} is outside the target folder",
        file.display()
    );
    assert!(
        file.file_name()
            .unwrap()
            .to_string_lossy()
            .ends_with(".video.mp4"),
        "{}",
        file.display()
    );
    let finished = sink.events().iter().any(|e| matches!(e, Event::Progress { step, fraction, .. } if step == "fetch_video" && *fraction == 1.0));
    assert!(finished, "no finished progress event: {:?}", sink.events());
}

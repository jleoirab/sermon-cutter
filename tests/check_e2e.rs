//! End-to-end stream check on a synthetic 6-minute stream with a frozen
//! picture, a black screen and a dropout in the sound. Needs ffmpeg and
//! ffprobe with libx264; skipped otherwise.

use sermoncut::audio;
use sermoncut::events::VecSink;
use sermoncut::quality::{self, Kind, VideoSource};
use sermoncut::tools::Tools;
use std::process::Command;

#[test]
fn finds_a_freeze_a_black_screen_and_a_dropout() {
    let t = Tools::locate(None);
    let (Some(ffmpeg), Some(_)) = (t.ffmpeg.clone(), t.ffprobe.clone()) else {
        eprintln!("skipped: ffmpeg or ffprobe missing");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("stream.mp4");
    // 100 s moving, 4 s frozen, 2 s black, 254 s moving; the sound is
    // digital silence from 150 to 160 s.
    let video = "testsrc2=s=320x180:r=30:d=100[a];\
        testsrc2=s=320x180:r=30:d=1,trim=end_frame=1,tpad=stop_mode=clone:stop_duration=4[b];\
        color=black:s=320x180:r=30:d=2[c];\
        testsrc2=s=320x180:r=30:d=254[d];\
        [a][b][c][d]concat=n=4:v=1:a=0,format=yuv420p[v]";
    let sound =
        "aevalsrc=exprs='if(between(t\\,150\\,160)\\,0\\,0.2*sin(2*PI*440*t))':s=44100:d=360";
    let ok = Command::new(&ffmpeg)
        .args([
            "-v",
            "error",
            "-y",
            "-filter_complex",
            video,
            "-f",
            "lavfi",
            "-i",
            sound,
        ])
        .args([
            "-map",
            "[v]",
            "-map",
            "0:a",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "1000",
        ])
        .args(["-c:a", "aac", "-shortest"])
        .arg(&file)
        .status()
        .unwrap()
        .success();
    assert!(ok, "could not make the test stream");

    let sink = VecSink::default();
    let f = audio::measure_file(&ffmpeg, &file, Some(360.0), "check_listen", &sink).unwrap();
    let report = quality::check(
        &t,
        &f,
        &file,
        Some(VideoSource {
            file: &file,
            cache: None,
        }),
        30.0,
        350.0,
        &sink,
    )
    .unwrap();

    let kinds: Vec<(Kind, f64, f64)> = report
        .issues
        .iter()
        .map(|i| (i.kind, i.start, i.end))
        .collect();
    let near = |kind: Kind, start: f64, end: f64| {
        kinds
            .iter()
            .any(|(k, s, e)| *k == kind && (s - start).abs() <= 1.0 && (e - end).abs() <= 1.0)
    };
    assert!(near(Kind::Frozen, 100.0, 104.0), "{kinds:?}");
    assert!(near(Kind::Black, 104.0, 106.0), "{kinds:?}");
    assert!(near(Kind::DeadAir, 150.0, 160.0), "{kinds:?}");
    assert_eq!(kinds.len(), 3, "{kinds:?}");
    // 10 s of lost sound in a 5 min 20 s cut: tell the leads.
    assert_eq!(report.verdict, "tell_leads");
    // The AAC encoder smears the edges of the silence by up to a second.
    assert!(
        report.note.contains("into the sermon: no sound for 9 s")
            || report.note.contains("into the sermon: no sound for 10 s"),
        "{}",
        report.note
    );
    assert!(report.video_checked);
}

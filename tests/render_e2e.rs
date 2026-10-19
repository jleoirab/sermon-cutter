//! End-to-end render and self-check on synthetic clips. Needs ffmpeg and
//! ffprobe with libx264 (or a hardware H.264 encoder); skipped otherwise.

use sermoncut::events::{Event, VecSink};
use sermoncut::render::{render, RenderRequest};
use sermoncut::timings::Timings;
use sermoncut::tools::Tools;
use sermoncut::verify::{verify, Expect};
use std::path::{Path, PathBuf};
use std::process::Command;

fn tools() -> Option<Tools> {
    let t = Tools::locate(None);
    (t.ffmpeg.is_some() && t.ffprobe.is_some()).then_some(t)
}

fn ffmpeg(t: &Tools, args: &[&str]) {
    let ok = Command::new(t.ffmpeg.as_ref().unwrap())
        .args(["-v", "error", "-y"])
        .args(args)
        .status()
        .unwrap()
        .success();
    assert!(ok, "ffmpeg {args:?} failed");
}

/// A 30-second 640x360 "service": moving test pattern and a steady tone.
fn make_service(t: &Tools, dir: &Path) -> PathBuf {
    let p = dir.join("service.mp4");
    ffmpeg(
        t,
        &[
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=640x360:rate=30:duration=30",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=44100:duration=30",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-c:a",
            "aac",
            "-shortest",
            p.to_str().unwrap(),
        ],
    );
    p
}

fn request(source: PathBuf, banner: PathBuf, output: PathBuf) -> RenderRequest {
    RenderRequest {
        source,
        banner,
        cut_in: 5.0,
        cut_out: 25.0,
        timings: Timings {
            open_hold: 4.0,
            dissolve: 0.5,
            close_hold: 3.0,
            fade_in: 2.0,
            fade_out: 1.5,
        },
        output,
        encoder: "auto".into(),
        video_bitrate: 1_500_000,
        audio_bitrate: 128_000,
        width: 640,
        height: 360,
    }
}

fn expect_all(len: f64) -> Expect {
    Expect {
        duration: Some(len),
        width: 640,
        height: 360,
        banner_at_start: true,
        banner_at_end: true,
        quiet_start: true,
        quiet_end: true,
    }
}

/// Average luma of a crop of the frame at `at` seconds (16 = black).
fn luma(t: &Tools, file: &Path, at: f64, crop: &str) -> f64 {
    let out = Command::new(t.ffmpeg.as_ref().unwrap())
        .args([
            "-v",
            "error",
            "-ss",
            &at.to_string(),
            "-i",
            file.to_str().unwrap(),
            "-frames:v",
            "1",
            "-vf",
        ])
        .arg(format!(
            "crop={crop},signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-"
        ))
        .args(["-f", "null", "-"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines()
        .find_map(|l| l.split("YAVG=").nth(1))
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or_else(|| panic!("no YAVG in {text}"))
}

#[test]
fn renders_and_passes_its_self_check() {
    let Some(t) = tools() else {
        return eprintln!("skipped: no ffmpeg");
    };
    let dir = tempfile::tempdir().unwrap();
    let source = make_service(&t, dir.path());
    let banner = dir.path().join("banner.png");
    ffmpeg(
        &t,
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=0x2a6f4e:size=1600x900,drawbox=x=400:y=300:w=800:h=300:color=white:t=fill",
            "-frames:v",
            "1",
            banner.to_str().unwrap(),
        ],
    );

    let out = dir
        .path()
        .join("Sermons/Oct 11th 2026/Sun Oct 11th Sermon.mp4");
    let sink = VecSink::default();
    let outcome = render(&t, &request(source, banner.clone(), out.clone()), &sink).expect("render");
    assert_eq!(outcome.cut_len, 20.0);
    assert!(out.exists(), "output was not moved into place");
    assert!(!dir
        .path()
        .join("Sermons/Oct 11th 2026/.Sun Oct 11th Sermon.mp4.partial")
        .exists());

    let events = sink.events();
    assert!(matches!(events.last(), Some(Event::Progress { fraction, .. }) if *fraction == 1.0));

    let report = verify(&t, &out, Some(&banner), &expect_all(20.0)).expect("verify");
    assert!(report.passed, "{report:#?}");
}

#[test]
fn letterboxes_square_banners_and_flattens_transparency() {
    let Some(t) = tools() else {
        return eprintln!("skipped: no ffmpeg");
    };
    let dir = tempfile::tempdir().unwrap();
    let source = make_service(&t, dir.path());
    // 800x800, transparent except a white square in the middle.
    let banner = dir.path().join("square.png");
    // (drawbox would leave the square's alpha at zero, so build the alpha with geq.)
    let square = "color=c=white:size=800x800,format=rgba,geq=r=255:g=255:b=255:a='if(between(X\\,300\\,499)*between(Y\\,300\\,499)\\,255\\,0)'";
    ffmpeg(
        &t,
        &[
            "-f",
            "lavfi",
            "-i",
            square,
            "-frames:v",
            "1",
            banner.to_str().unwrap(),
        ],
    );

    let out = dir.path().join("square.mp4");
    render(
        &t,
        &request(source, banner.clone(), out.clone()),
        &VecSink::default(),
    )
    .expect("render");

    // At 1 s the banner covers the frame: 360x360 in the middle, black bars either side.
    let bar = luma(&t, &out, 1.0, "40:360:0:0");
    assert!(bar < 20.0, "left bar should be black, luma {bar}");
    // Inside the banner but in its transparent corner: black, not footage.
    let corner = luma(&t, &out, 1.0, "40:40:150:10");
    assert!(
        corner < 20.0,
        "transparent corner should be black, luma {corner}"
    );
    // The white square still shows.
    let square = luma(&t, &out, 1.0, "40:40:300:160");
    assert!(
        square > 200.0,
        "white square should be white, luma {square}"
    );
    // Mid-cut is footage again.
    let mid = luma(&t, &out, 10.0, "40:360:0:0");
    assert!(mid > 20.0, "footage should show mid-cut, luma {mid}");
}

#[test]
fn self_check_catches_a_cut_without_banner_or_fades() {
    let Some(t) = tools() else {
        return eprintln!("skipped: no ffmpeg");
    };
    let dir = tempfile::tempdir().unwrap();
    let source = make_service(&t, dir.path());
    let banner = dir.path().join("banner.png");
    ffmpeg(
        &t,
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=0x2a6f4e:size=1600x900",
            "-frames:v",
            "1",
            banner.to_str().unwrap(),
        ],
    );

    let report = verify(&t, &source, Some(&banner), &expect_all(20.0)).expect("verify");
    assert!(!report.passed);
    let failed: Vec<&str> = report
        .checks
        .iter()
        .filter(|c| !c.passed)
        .map(|c| c.name.as_str())
        .collect();
    for name in [
        "length",
        "banner at start",
        "banner at end",
        "quiet start",
        "quiet end",
    ] {
        assert!(failed.contains(&name), "{name} should fail: {report:#?}");
    }
    assert!(!failed.contains(&"footage in the middle"));
}

#[test]
fn refuses_impossible_requests() {
    let Some(t) = tools() else {
        return eprintln!("skipped: no ffmpeg");
    };
    let dir = tempfile::tempdir().unwrap();
    let source = make_service(&t, dir.path());
    let banner = dir.path().join("banner.png");
    ffmpeg(
        &t,
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=red:size=1600x900",
            "-frames:v",
            "1",
            banner.to_str().unwrap(),
        ],
    );
    let sink = VecSink::default();

    let mut past_end = request(source.clone(), banner.clone(), dir.path().join("a.mp4"));
    past_end.cut_out = 45.0;
    let e = render(&t, &past_end, &sink).unwrap_err().to_string();
    assert!(e.contains("past the end"), "{e}");

    let mut backwards = request(source.clone(), banner.clone(), dir.path().join("b.mp4"));
    backwards.cut_out = 4.0;
    let e = render(&t, &backwards, &sink).unwrap_err().to_string();
    assert!(e.contains("must come after In"), "{e}");

    let mut too_short = request(source, banner, dir.path().join("c.mp4"));
    too_short.cut_out = 12.0; // 7 s cut, banners need 8 s
    let e = render(&t, &too_short, &sink).unwrap_err().to_string();
    assert!(e.contains("banners need"), "{e}");
}

/// Time of the first frame brighter than `min_luma`.
fn first_flash(t: &Tools, file: &Path, min_luma: f64) -> f64 {
    let out = Command::new(t.ffmpeg.as_ref().unwrap())
        .args(["-v", "error", "-i", file.to_str().unwrap(), "-vf"])
        .arg("signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-")
        .args(["-an", "-f", "null", "-"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    let mut time = None;
    for line in text.lines() {
        if let Some(rest) = line.split("pts_time:").nth(1) {
            time = rest
                .split_whitespace()
                .next()
                .and_then(|v| v.parse::<f64>().ok());
        } else if let Some(v) = line.split("YAVG=").nth(1) {
            if v.trim().parse::<f64>().unwrap() > min_luma {
                return time.expect("pts_time before YAVG");
            }
        }
    }
    panic!("no flash found");
}

/// Start of the first 10 ms window louder than `min_db`.
fn first_beep(t: &Tools, file: &Path, min_db: f64) -> f64 {
    let out = Command::new(t.ffmpeg.as_ref().unwrap())
        .args(["-v", "error", "-i", file.to_str().unwrap(), "-vn", "-af"])
        .arg("asetnsamples=441,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-")
        .args(["-f", "null", "-"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    let mut time = None;
    for line in text.lines() {
        if let Some(rest) = line.split("pts_time:").nth(1) {
            time = rest
                .split_whitespace()
                .next()
                .and_then(|v| v.parse::<f64>().ok());
        } else if let Some(v) = line.split("RMS_level=").nth(1) {
            let db: f64 = v.trim().parse().unwrap_or(f64::NEG_INFINITY);
            if db > min_db {
                return time.expect("pts_time before RMS_level");
            }
        }
    }
    panic!("no beep found");
}

#[test]
fn keeps_sound_in_sync_when_the_audio_starts_late() {
    let Some(t) = tools() else {
        return eprintln!("skipped: no ffmpeg");
    };
    let dir = tempfile::tempdir().unwrap();
    // Black picture with a white flash at 12.0 s, silence with a beep at 12.0 s,
    // and the audio track starting 0.25 s after the video, as live streams can.
    let source = dir.path().join("sync.mp4");
    ffmpeg(
        &t,
        &[
            "-f", "lavfi", "-i",
            "color=c=black:s=640x360:r=30:d=30,drawbox=x=0:y=0:w=640:h=360:color=white:t=fill:enable='between(t,12,12.1)'",
            "-itsoffset", "0.25", "-f", "lavfi", "-i",
            "sine=frequency=1000:sample_rate=44100:duration=29.75,volume=volume=0:enable='not(between(t,11.75,11.85))'",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", source.to_str().unwrap(),
        ],
    );
    let banner = dir.path().join("banner.png");
    ffmpeg(
        &t,
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=0x2a6f4e:size=1600x900",
            "-frames:v",
            "1",
            banner.to_str().unwrap(),
        ],
    );

    // Cut from the very start, where the late audio matters: resetting each
    // stream's timestamps separately would pull the beep 0.25 s early.
    let out = dir.path().join("synced.mp4");
    let mut req = request(source.clone(), banner, out.clone());
    req.cut_in = 0.0;
    req.cut_out = 20.0;
    render(&t, &req, &VecSink::default()).expect("render");

    let (src_flash, src_beep) = (
        first_flash(&t, &source, 180.0),
        first_beep(&t, &source, -30.0),
    );
    assert!(
        (src_flash - src_beep).abs() < 0.05,
        "fixture out of sync: {src_flash} vs {src_beep}"
    );
    let (flash, beep) = (first_flash(&t, &out, 180.0), first_beep(&t, &out, -30.0));
    assert!((flash - 12.0).abs() < 0.1, "flash at {flash}, want 12.0");
    assert!(
        (flash - beep).abs() < 0.05,
        "sound drifted: flash {flash}, beep {beep}"
    );
}

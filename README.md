# sermoncut: the Sermon Cutter engine

`sermoncut` does the processing for the Sermon Cutter app:

1. It downloads a stream from YouTube, audio first and then H.264 video.
2. It cuts the sermon and lays the Sunday banner over both ends, with dissolves and audio fades.
3. It checks the exported file before anyone uploads it.

It runs the same on macOS and Windows. The Mac app, and a Windows app later, drive it as a command-line tool and read its progress as JSON.

This is milestone 1 of the [Sermon Cutter PRD & Design Plan](https://claude.ai/code/artifact/159c19aa-033f-42a7-ac98-4f42af1fc993). Sermon detection, the quality check and the app itself come in later milestones.

## Try it on a Mac

```bash
brew install rust ffmpeg yt-dlp deno
cargo build --release
B=./target/release/sermoncut

$B tools                       # which ffmpeg, ffprobe, yt-dlp and Deno it found
$B encoders                    # expect h264_videotoolbox first

$B info  https://www.youtube.com/watch?v=iz0PPVUleUw
$B fetch https://www.youtube.com/watch?v=iz0PPVUleUw --dir ~/Movies/SermonCutter

# In and Out are wherever you'd cut today (these are only examples).
$B render \
  --source ~/Movies/SermonCutter/iz0PPVUleUw.video.mp4 \
  --banner "$HOME/Documents/CCIKW/Service/Oct 11th 2026/YOUR-MOUNTAIN-16BY9.webp" \
  --in 1:21:05 --out 2:35:00 \
  -o "$HOME/Documents/CCIKW/Service/Oct 11th 2026/Sun Oct 11th Sermon.mp4"
```

`render` checks its own output and fails if the check fails; pass `--no-verify` to skip the check.

## Commands

| Command | What it does |
| --- | --- |
| `tools` | Shows which ffmpeg, ffprobe, yt-dlp and Deno will be used |
| `encoders` | Lists the H.264 encoders that work on this computer, best first |
| `info <url>` | Reads the title, length, live status and best H.264 rendition, without downloading |
| `fetch <url> [--dir D] [--part audio\|video\|both]` | Downloads the AAC audio, then H.264 video up to 1080p merged to MP4 |
| `render --source --banner --in --out -o` | Cuts, adds the banner and fades, exports 1080p H.264 + AAC, then self-checks |
| `verify --file [--banner] [--expect-duration]` | Checks format, length, banner on the first and last frames, footage mid-cut, and quiet first and last 100 ms |

Timecodes accept `1:23:05`, `1:23:05.5`, `83:05` or plain seconds.

Banner and fade timings, with defaults taken from the Oct 4 and Oct 11 reference cuts:

| Option | Default | Meaning |
| --- | --- | --- |
| `--open-hold` | 8 | Seconds the banner fully covers the start |
| `--dissolve` | 0.5 | Seconds each banner dissolve takes |
| `--close-hold` | 6 | Seconds the banner fully covers the end |
| `--fade-in` | 4 | Seconds the audio rises from silence, from the first frame |
| `--fade-out` | 3 | Seconds the audio falls to silence, ending on the last frame |

Other options: `--encoder auto|h264_videotoolbox|libx264|...`, `--video-bitrate 6M`, `--audio-bitrate 192k`.

## Output: one JSON object per line

```text
{"event":"progress","step":"render","fraction":0.42,"eta_s":51.2}
{"event":"log","level":"info","message":"encoding 1:13:55.000 of sermon with h264_videotoolbox"}
{"event":"result","step":"render","data":{"output":"...","encoder":"h264_videotoolbox","cut_len":4435.0,"elapsed_s":212.4,"speed":20.9}}
{"event":"result","step":"verify","data":{"passed":true,"checks":[...]}}
{"event":"error","step":"render","message":"Out (2:55:00.000) is past the end of the source (2:53:11.000)"}
```

The exit status is 0 on success and 1 on failure.

## Where it finds its tools

For each tool it checks, in order:

1. An environment variable: `SERMONCUT_FFMPEG`, `SERMONCUT_FFPROBE`, `SERMONCUT_YTDLP` or `SERMONCUT_DENO`.
2. The app's tools folder, or `--tools-dir`:
    - macOS: `~/Library/Application Support/Sermon Cutter/bin`
    - Windows: `%LOCALAPPDATA%\Sermon Cutter\bin`
3. The `PATH`.

The tools folder sits outside the signed app so yt-dlp can keep itself up to date. YouTube downloads need a JavaScript runtime, and Deno is yt-dlp's recommended one.

## How the render works

ffmpeg makes one pass, using a hardware H.264 encoder when there is one: VideoToolbox on the Mac, NVENC, QuickSync or AMF on Windows, and x264 as the fallback.

- The banner is fitted inside 1920x1080 and letterboxed. Any transparency is flattened onto black, and it is converted with BT.709 like the footage.
- The banner is overlaid on the footage. Its opacity fades out after the opening hold and back in before the closing hold, so the sermon audio plays under it at both ends.
- The output is written to a hidden `.name.partial` file and moved into place only when it is complete.

## Tests

```bash
cargo test
```

The suite has 40 tests. The end-to-end tests need ffmpeg with libx264, and the download test needs yt-dlp and python3; any test whose tools are missing is skipped.

| Test | What it proves |
| --- | --- |
| Render and self-check | A synthetic 20 s cut passes every check |
| Square, transparent banner | Letterboxing and flattening work |
| Missing banner or fades | The self-check catches a cut that has neither |
| Bad requests | Out past the end, Out before In, and holds too long for the cut are all refused |
| Late audio | Sound stays in sync when a stream's audio starts after its video |
| Local download | The real yt-dlp downloads a file from a local web server, reporting progress and where it saved the file |

### Checked so far

- **Real footage and banner.** The engine's ffmpeg command ran on 60 s of the Oct 11 final cut, with `YOUR-MOUNTAIN-16BY9.webp` as the banner, using ffmpeg 4.4 and x264. Against the banner, the opening and closing frames scored SSIM 0.999 and the middle scored 0.14. The first and last 100 ms measured −55.6 and −53.7 dBFS.
- **YouTube download.** Not run yet: YouTube was unreachable from the build environment.
- **VideoToolbox speed.** Not measured yet. On a Linux VM, x264 managed about 1.7× real time at 1080p, which is why a Mac hardware encoder matters.

Both of these are milestone 1's gate, to run on the 2022 MacBook Pro.

# sermoncut: the Sermon Cutter engine

`sermoncut` does the processing for the Sermon Cutter app:

1. It downloads a stream from YouTube, audio first and then H.264 video.
2. It finds where the sermon starts and ends, from the sound and the words, with no chapters needed.
3. It cuts the sermon and lays the Sunday banner over both ends, with dissolves and audio fades.
4. It checks the exported file before anyone uploads it.

It runs the same on macOS and Windows. The Mac app, and a Windows app later, drive it as a command-line tool and read its progress as JSON.

This is milestones 1 and 2 of the [Sermon Cutter PRD & Design Plan](https://claude.ai/code/artifact/159c19aa-033f-42a7-ac98-4f42af1fc993). The quality check and the app itself come in later milestones.

## Try it on a Mac

```bash
brew install rust ffmpeg yt-dlp deno whisper-cpp
cargo build --release
B=./target/release/sermoncut

# The speech model for hearing "please be seated" (264 MB, once).
mkdir -p ~/Movies/SermonCutter/models
curl -L -o ~/Movies/SermonCutter/models/ggml-small.en-q8_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q8_0.bin
export SERMONCUT_WHISPER_MODEL=~/Movies/SermonCutter/models/ggml-small.en-q8_0.bin

$B tools                       # which ffmpeg, ffprobe, yt-dlp, Deno and whisper.cpp it found
$B encoders                    # expect h264_videotoolbox first

$B info  https://www.youtube.com/watch?v=iz0PPVUleUw
$B fetch https://www.youtube.com/watch?v=iz0PPVUleUw --dir ~/Movies/SermonCutter

# Find the sermon: prints "in_tc" and "out_tc" with their confidence.
$B find ~/Movies/SermonCutter/iz0PPVUleUw.audio.m4a --lead-in 6:00 \
  --cache ~/Movies/SermonCutter/iz0PPVUleUw.sound.json \
  --transcript-cache ~/Movies/SermonCutter/iz0PPVUleUw.words.json

# Render with the In and Out that find printed.
$B render \
  --source ~/Movies/SermonCutter/iz0PPVUleUw.video.mp4 \
  --banner "$HOME/Documents/CCIKW/Service/Oct 11th 2026/YOUR-MOUNTAIN-16BY9.webp" \
  --in 1:11:36 --out 2:29:21.6 \
  -o "$HOME/Movies/SermonCutter/Oct 11 test.mp4"
```

`render` checks its own output and fails if the check fails; pass `--no-verify` to skip the check. It never replaces an existing file unless you pass `--overwrite`, so a test run can't write over a finished sermon.

`find` only needs the audio file, so it can run while the video is still downloading. The caches make a second run instant.

## Commands

| Command | What it does |
| --- | --- |
| `tools` | Shows which ffmpeg, ffprobe, yt-dlp and Deno will be used |
| `encoders` | Lists the H.264 encoders that work on this computer, best first |
| `info <url>` | Reads the title, length, live status and best H.264 rendition, without downloading |
| `fetch <url> [--dir D] [--part audio\|video\|both]` | Downloads the AAC audio, then H.264 video up to 1080p merged to MP4 |
| `find <stream> [--lead-in 2:00]` | Proposes In and Out, each with a confidence, plus a map of music and speech for the timeline |
| `align --stream --final` | Finds where a finished cut sits in its stream by matching their sound (for scoring `find` on past Sundays) |
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

Other options: `--encoder auto|h264_videotoolbox|libx264|...`, `--video-bitrate 6M`, `--audio-bitrate 192k`, `--overwrite`.

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

1. An environment variable: `SERMONCUT_FFMPEG`, `SERMONCUT_FFPROBE`, `SERMONCUT_YTDLP`, `SERMONCUT_DENO` or `SERMONCUT_WHISPER` (whisper.cpp's `whisper-cli`).
2. The app's tools folder, or `--tools-dir`:
    - macOS: `~/Library/Application Support/Sermon Cutter/bin`
    - Windows: `%LOCALAPPDATA%\Sermon Cutter\bin`
3. The `PATH`.

The speech model comes from `SERMONCUT_WHISPER_MODEL`, `--model`, or the tools folder's `models` folder (`ggml-small.en-q8_0.bin` first).

The tools folder sits outside the signed app so yt-dlp can keep itself up to date. YouTube downloads need a JavaScript runtime, and Deno is yt-dlp's recommended one.

## How find works

It listens first, then reads.

1. **The preacher's start, from the sound.** Each second gets two measures: the share of its energy below 150 Hz, and how much its level swings between 20 ms slices. A band or held notes mean music. One voice with no bass and big syllable swings means speech. The sermon starts where at least 40% of the previous 5 minutes was music and at least half of the next 2 minutes is speech. Among those moments, the one followed by the most speech before the next 4.5 minutes of music wins. Short songs inside the sermon don't end it.
2. **In** is that start minus `--lead-in`, moved to the quietest second within 3 s.
3. **Out, from the words.** whisper.cpp transcribes from 25 minutes after the preacher starts, 10 minutes at a time. It stops at the first "please be seated" (or "take your seats") that leads into the offering, or that follows a prayer and leads somewhere new. Out is the end of that phrase, kept through a short "Thank you, Jesus" straight after it.
4. **Hand-over.** If someone thanks the apostle or pastor between the closing prayer and that cue, the preacher's part ended at the prayer, so Out moves there.
5. **Fallbacks.** With no cue, Out is the closing prayer before the offering. With no words at all, Out is the end of the sermon's run of speech.

| Out confidence | When |
| --- | --- |
| high | The cue follows a prayer and the offering is named within 2.5 minutes after it |
| medium | Only one of those, or a hand-over |
| low | No seat cue was heard |

whisper runs with `-mc 0` so it can't prompt itself with its own last words. Without it, whisper looped "I set you free" fifty times on Sept 20 and lost the cue.

## How the render works

ffmpeg makes one pass, using a hardware H.264 encoder when there is one: VideoToolbox on the Mac, NVENC, QuickSync or AMF on Windows, and x264 as the fallback.

- The banner is fitted inside 1920x1080 and letterboxed. Any transparency is flattened onto black, and it is converted with BT.709 like the footage.
- The banner is overlaid on the footage. Its opacity fades out after the opening hold and back in before the closing hold, so the sermon audio plays under it at both ends.
- The output is written to a hidden `.name.partial` file and moved into place only when it is complete.

## Tests

```bash
cargo test
```

The suite has 62 tests. The end-to-end tests need ffmpeg with libx264, and the download test needs yt-dlp and python3; any test whose tools are missing is skipped.

| Test | What it proves |
| --- | --- |
| Render and self-check | A synthetic 20 s cut passes every check |
| Square, transparent banner | Letterboxing and flattening work |
| Missing banner or fades | The self-check catches a cut that has neither |
| Bad requests | Out past the end, Out before In, and holds too long for the cut are all refused |
| Late audio | Sound stays in sync when a stream's audio starts after its video |
| Local download | The real yt-dlp downloads a file from a local web server, reporting progress and where it saved the file |
| Made-up services | The start is found after worship; a 3.5-minute song or a dropout inside the sermon doesn't end it; a concert has no sermon |
| Seat cues | Words as heard on Sept 13, Sept 20, Oct 4 and Oct 11 give the right Out; a mid-sermon "sit down" is passed over |
| Alignment | A cut found in its stream to 0.1 s; a cut from another stream is refused |

### Checked so far

- **Real footage and banner.** The engine's ffmpeg command ran on 60 s of the Oct 11 final cut, with `YOUR-MOUNTAIN-16BY9.webp` as the banner, using ffmpeg 4.4 and x264. Against the banner, the opening and closing frames scored SSIM 0.999 and the middle scored 0.14. The first and last 100 ms measured −55.6 and −53.7 dBFS.
- **YouTube download.** The Oct 11 stream downloaded on the 2022 MacBook Pro, audio first, then 1080p H.264 video.
- **VideoToolbox speed.** On the same Mac, a 73:55 cut exported in 11:08 (6.6× real time) and passed every self-check. The file was 3.4 GB, against 8.8 GB from CapCut.

**Sermon finder on past Sundays.** `align` recovered each real cut's In and Out from its stream. `find` then ran on each stream with no chapters:

| Sunday | Preacher starts | Your In was | Out found | Off by | Confidence |
| --- | --- | --- | --- | --- | --- |
| Sept 13 | 0:49:00 | 2.9 min before | 2:04:10.4 | −0.3 s | high |
| Sept 20 | 1:14:44 | 7.2 min before | 2:56:59.9 | +0.5 s | high |
| Sept 27 | 1:33:24 | 1.4 min before | 2:53:12.2 | −0.8 s | high |
| Oct 4 | 1:12:17 | 3.2 min before | 2:22:18.7 | +11.2 s | medium |
| Oct 11 | 1:17:38 | 6.3 min before | 2:29:21.6 | +1.1 s | medium |
| Oct 18 | 1:28:14 | (not cut) | 2:46:02.6 | | high |

On Oct 4 the preacher never said to sit. Someone else thanked him and started the giving, and your cut ended 10 s before the end of his closing prayer.

Your lead-ins ranged from 1.4 to 7.2 minutes, so the lead-in stays your call each week. A transcript of the minute around each found start confirms the speaker taking over from the worship team there.

The listening covered 50 to 80 minutes of each stream. On the 2022 MacBook Pro, `find` on Oct 11 took 1 min 40 s in all, including measuring the sound and transcribing 50 minutes on the GPU. It put Out at 2:29:19.2, 1.3 s before the real cut; whisper's word times differ by a second or so between computers.

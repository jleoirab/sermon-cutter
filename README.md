# sermoncut: the Sermon Cutter engine

`sermoncut` does the processing for the Sermon Cutter app:

1. It downloads a stream from YouTube, audio first and then H.264 video.
2. It finds where the sermon starts and ends, from the sound and the words, with no chapters needed.
3. It checks the stream's sound and picture over the sermon and grades it Good, Usable but tell the leads, or Not usable.
4. It cuts the sermon and lays the Sunday banner over both ends, with dissolves and audio fades.
5. It checks the exported file before anyone uploads it.

It runs the same on macOS and Windows. The Mac app, and a Windows app later, drive it as a command-line tool and read its progress as JSON.

This is milestones 1 to 3 of the [Sermon Cutter PRD & Design Plan](https://claude.ai/code/artifact/159c19aa-033f-42a7-ac98-4f42af1fc993), plus the first version of the Mac app (milestone 4) in `app/`.

## The Mac app

```bash
app/build.sh        # builds the engine and the app, installs ~/Applications/Sermon Cutter.app
```

It needs the Xcode Command Line Tools (Swift 5.9 or later), Rust, and for now the tools from Homebrew (`brew install ffmpeg yt-dlp deno whisper-cpp`) plus the speech model (see Settings).

- **Streams** lists the channel's newest streams; pick one or paste a link. Sundays already started are listed below to pick up where they left off.
- **Preparing** downloads the audio, finds the sermon and checks the sound while the video downloads, then checks the picture. Everything is cached next to the downloads, so reopening a Sunday is instant.
- **Review** has the player and the timeline on the left: music and speech bands, the cut, the quality strip, and loudness when zoomed to 10 minutes or 1 minute. Drag In or Out (the player follows), or click to play from anywhere. On the right are In and Out with their confidence and evidence, nudges, Set to playhead and typed times; the lead-in; the verdict, each problem (click to listen) and Copy the note for the leads; the banner (dropped, chosen, from a Drive link shared with anyone, or found already in the Sunday's Service folder); the holds and fades with 20-second previews of each end.
- **Export** writes Service/<date>/<date> Sermon.mp4 (for example "Oct 11th 2026/Oct 11th Sermon.mp4"), self-checks it, and offers Show in Finder.

Still to come before the pilot: tools bundled with the app (no Homebrew), dragging the banner and fade edges on the timeline, Drive upload, and signing.

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

# Check the stream over that cut: prints "headline", the problems and a note for the leads.
$B check ~/Movies/SermonCutter/iz0PPVUleUw.video.mp4 --in 1:11:36 --out 2:29:21.6 \
  --cache ~/Movies/SermonCutter/iz0PPVUleUw.sound.json

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
| `check <stream> --in --out [--video V] [--no-video]` | Grades the cut's sound and picture, lists each problem with its time in the sermon, and drafts a note for the leads |
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

## How check works

It scans only the cut, from In to Out.

| Problem | How it's found | Counts when |
| --- | --- | --- |
| No sound | Loudness under −90 dBFS: digital silence from a dropped feed. The quietest second on the good Sundays was −69 | 1 s or more |
| Microphone lost | 25 dB under the surrounding 5 minutes, without a break | 20 s or more |
| Gap in the audio data | Audio timestamps jump | over 0.25 s |
| Frozen picture | Frames identical (mean change under 0.1 grey levels at 160 x 90) | 2 s or more |
| Black picture | Mean grey under 10 of 255 | 1 s or more |
| Holding screen | The picture repeats itself every 4 to 60 s but changes in between: a looping animation, not a still shot | 30 s windows |
| Choppy picture | More than 10 holds of 3 or more repeated frames in a minute | that minute |

The verdict:

- **Not usable: use a different stream** when the sound, or the picture of the service, is lost for 5% of the cut, for more than 3 minutes at once, or 3 times for more than 30 s.
- **Usable, but tell the leads** when any sound problem lasts 3 s or more, or the picture has trouble for 30 s or more in all.
- **Good** otherwise.

`note` is a message for the leads with each problem's time into the sermon. `minutes` marks every minute of the cut good, warn or bad for the Review screen's quality strip.

The picture scan decodes the video once at 160 x 90 grey and keeps only a few numbers per frame and a 32 x 18 thumbnail a second. It starts a minute before In, because the loop check looks back that far. `--picture-cache` saves those measurements.

## How the render works

ffmpeg makes one pass, using a hardware H.264 encoder when there is one: VideoToolbox on the Mac, NVENC, QuickSync or AMF on Windows, and x264 as the fallback.

- The banner is fitted inside 1920x1080 and letterboxed. Any transparency is flattened onto black, and it is converted with BT.709 like the footage.
- The banner is overlaid on the footage. Its opacity fades out after the opening hold and back in before the closing hold, so the sermon audio plays under it at both ends.
- The output is written to a hidden `.name.partial` file and moved into place only when it is complete.

## Tests

```bash
cargo test
```

The suite has 74 tests. The end-to-end tests need ffmpeg with libx264, and the download test needs yt-dlp and python3; any test whose tools are missing is skipped.

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
| Stream check | A synthetic stream with a 4 s freeze, 2 s of black and 10 s without sound gets all three found and "tell the leads"; a looping animation is a holding screen but a still shot isn't |

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

**Stream check on past Sundays.** `check` ran over each real cut (Oct 18: the found cut). The sound was checked on all six. The picture was checked on Oct 11 and Oct 18, whose videos are on the MacBook, using measurements taken there.

| Sunday | Verdict | What it found |
| --- | --- | --- |
| Sept 13, 20, 27, Oct 4 | Good | Nothing (sound) |
| Oct 11 | Good | Nothing (sound and picture) |
| Oct 18 | Not usable | Sound lost 11 times, 16 min 31 s in all (21%), the longest 8 min 17 s; the holding screen for 12 min 44 s, from 2:01:30 to 2:14:55; 3 choppy minutes; 4 one-second black flashes |

On the 2022 MacBook Pro, `check` on the Oct 18 video took 1 min 20 s in all. That includes measuring the whole stream's sound and scanning 81 minutes of 1080p picture; the verdict came out Not usable.

# Optional AetherEngine comparison

Settings > App settings > 試験用AetherEngineを使用 defaults off. Snapshot the
choice when opening a recording: only non-recording encoded PLAY uses the new
controller. TS PLAY and every STREAMING request retain VLC. Closing the trial
releases the engine; switching off restores normal PLAY on the next opening.

The trial has video/audio, startup from the beginning, pause/play, ±10s, a seek slider,
double tap, orientation and diagnostic export. It deliberately has no comment,
subtitle, PiP or history-write integration. Trial playback starts at zero and
does not overwrite history. It reuses NeoPlayerChrome. Menu, subtitle/comment,
PiP, reload, zoom/drag and settings that have no comparison-engine connection
are disabled; diagnostic export remains available. Starting at zero isolates
the comparison from resume integration.

AetherEngine 7.46.0 is pinned by revision along with its transitive package
lock. One Swift 6.2 compatibility patch passes a Boolean capability verdict to
the routing closure instead of capturing a task-isolated C pointer; the same
profile exemption and post-panel retry remain. The packaging step verifies checkout
identity and collects dependency license texts, exact source links and source
build recipes. FFmpeg components remain dynamically embedded beside VLCKit.

Measure `seek.start` to `seek.videoResume`; keep `aether.seekLanded` separate.
A software result requires the pixel buffer actually displayed by the sample
buffer renderer, tagged with source PTS and flush generation; a prior generation
cannot satisfy a new seek. Native output requires a display-ready AVPlayerLayer
and a pixel buffer whose item PTS maps through PresentationAxisMap to the target.
The generic sourceTimeFollowsPicture flag is not picture evidence. Startup also
requires actual output, not just the engine ready flag. Synthetic tests retain a
rendered picture and reject flat/black output. `aether.telemetry` contains periodic
byte/cache counters, not exact per-seek cache hits. Exported decisions are fixed
tokens plus numeric/Boolean fields; no raw logs, URLs, headers or titles.

Acceptance: both platform builds link both engines. A real synthetic HTTP Range
origin serves H.264, HEVC 10bit and AV1 10bit MKV; each trial starts at zero,
seeks to 20/40/30/20s, seeks while paused and closes cleanly. The same
binary must pass existing indexed VLC startup/rewind probes. Simulator AV1
software results do not predict iPhone hardware seek latency. Real performance,
audio, device rotation and LiveContainer behavior remain device checks.

Build 244 verification (commit `662839271a405c004f0b75833120d334bde394fd`):

- Device and simulator application builds, IPA signing verification, dependency
  provenance and the Foundation parser/clock checks passed.
- H.264 and HEVC 10bit MKV each passed all 10 comparison assertions, including
  startup, four transport seeks, a paused seek and teardown.
- AV1 10bit software startup failed: no first display-ready edge within 30s,
  and the initial clock no longer matched the starting position. All five
  subsequent seeks passed the software picture-clock assertion. This remains
  unresolved; no hardware AV1 performance claim follows from these tests.
- The Actions run is failed, not fully verified. The retained VLC startup
  script was not reached because the AV1 assertion failed first.
- A prior synthetic-origin suffix Range parsing error was fixed and locally
  tested. Correcting that test-server error did not fix AV1 startup.

The opt-in IPA is suitable for an explicit engine comparison with these known
limits, not a replacement for the default VLC path. Use the comparison screen's
diagnostic export on a device to identify the selected route and measured seek
outcomes. Do not present these simulator timings as device performance.

Build 245 diagnostic recheck reused the exact Build 244 binary. It reproduced
AV1 software decode failure: generic FFmpeg `av1` selected hardware formats
(Vulkan) without a hardware device; audio continued and no frames were produced.
The old five "successful" software seeks were false positives from the clock
flag and are superseded, not evidence of displayed video.

Build 247 established the actual integration defect: app imports such as
av_read_frame, avcodec_descriptor_get_by_name, avcodec_find_decoder_by_name,
avcodec_send_packet and avformat_open_input bind to VLCKit, while avcodec_version
binds to AetherLibavcodec. VLCKit exports its own static FFmpeg symbols, and the
application linker selected them before the SPM dynamic frameworks. The observed
ID discrepancy belongs to those different libraries; the pinned Aether headers
are correct. The earlier 0003 header experiment is retired and reversed on any
already-prepared checkout, not applied to the new build.

The application links Aether's nine frameworks before inherited CocoaPods flags.
An independent Mach-O import check rejects any FFmpeg/dav1d function bound to
VLCKit on both device and simulator outputs, before packaging/testing. The runtime
codec descriptor/dav1d check then detects a future binding/ABI error. Software AV1
explicitly opens libdav1d and rejects hardware-only pixel formats. Actual displayed
picture PTS/generation gates still replace the old clock-only seek assertion.
All active source patches are hash verified and retained with source recipes.

The corrected device/simulator build and scoped playback verification are pending.

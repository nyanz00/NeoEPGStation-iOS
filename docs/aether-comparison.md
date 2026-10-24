# Optional AetherEngine comparison

Settings > App settings > 再生エンジン > 試験用：AetherEngine is opt-in (default VLC). Snapshot the
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
A software startup requires a real displayed pixel buffer. When its IOSurface
preserves source PTS/generation, only the actual target picture can emit
`seek.videoResume`. P010 may instead be copied by the OS into a new BGRA surface
that strips both custom and standard movie-time attachments (calibration 258).
That case uses a fresh post-seek decoded-target callback plus an available display
image to release the UI. It emits `aether.seekDecodedTarget` with `decodeReadyMs`
and `displayTimeVerified=false`, never a seek-to-display duration. It must not be
presented as equivalent to measured visible latency. Native output uses actual
AVPlayer pixel timestamps mapped through PresentationAxisMap.

Synthetic acceptance separately captures the displayed target image after every
20/40/30/20/30s jump, including the paused jump, and compares the burned-in counter
against source-hashed reference PNGs. Every successive target has a different tens
digit, so retaining the previous picture fails. This verifies visual positioning
without relying on optional OS timestamp metadata. PNG conversion runs after all
latency measurements; simulator Core Image shader compilation previously blocked
the main actor and inflated the recorded startup time. Byte/cache telemetry is
periodic, not an exact per-seek cache hit. Logs retain fixed tokens and numeric/
Boolean fields; no raw URLs, headers, subtitles or titles are exported.

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

The corrected build and verification results are recorded below.

Build 249 passed all 145 FFmpeg import bindings on both architectures, and the
runtime descriptors/dav1d agreed with the original headers. A displayed synthetic
H.264 frame was captured from the unchanged binary. Calibration runs 253/256
established that copyDisplayedPixelBuffer strips custom CVBuffer attachments,
even when propagation is requested, but retains IOSurface metadata (42 observed
tag writes, source PTS/generation present on the actual displayed surface).
Patch 0004 stores that identity on the surface, not on an optimistic clock.
A native output observed just before the seek callback is retained for that same
pending seek, so a paused frame is not consumed and lost by the observer.

The software host previously parked its feeder on every paused seek, moving its
clock and reporting landed without decoding a target picture. Patch 0004 reuses
the existing paused-first-frame gate to decode/drain one post-target frame at a
stopped audio clock, then parks again; it does not resume paused audio. The
comparison probe requires an actual displayed target picture for that case too.
A retained VLC cost assertion now permits one admitted producer frame between
sample preparation/submission and the asynchronous stats callback; larger gaps,
inversions and accounting errors remain failures.

Build 257 verified the shared chrome, startup, all five H.264 target pictures by
source timestamp, paused-target production, both 145-symbol import checks and all
six retained VLC startup/rewind cases (48 assertions each). The HEVC test exposed
the P010-to-BGRA copy and correctly failed its timestamp-dependent observer; it
did not establish a failure to decode or display. The following build separates
untimed displayed images from target-decode evidence and verifies all three
formats using the burned-in target counter. Device hardware latency remains an
explicit device comparison, not a simulator claim.

Final verification: Build 259, application commit
`59a3fdb9ea174f690f042f76c11d94b9119965ff`.

- Run 40075321803: device + simulator builds, signing/package checks, both
  145-symbol FFmpeg import checks and source provenance passed. H.264 + HEVC
  each passed 12 functional checks and five displayed-target image comparisons.
  All six retained VLC cases passed 48 assertions each.
- That run failed the AV1 image matcher at the 40s target even though the saved
  display image reads 00:00:40.000 and all 12 app checks passed. Its yellow text's
  green channel changes in P010-to-BGRA/sRGB conversion. The test now compares
  its stable red-channel glyph mask, keeping the same mismatch threshold and
  rejecting the wrong counter references.
- Run 40086474536 reused the exact same compiled application and passed AV1's
  12 checks and all five target images (including paused seek). The already
  verified VLC results were reused only after checking identical source, test
  fixtures, test code and six explicit success results. No app rebuild or timing
  threshold relaxation was used for the image-matcher correction.
- Together these checks verify 15 displayed seek targets across H.264/HEVC/AV1.
  The test-only renderer injection is absent from this application and final
  verification. H.264 software display timing is available; ten-bit software
  results are explicitly decode-ready observations, not display-latency claims.
- IPA SHA-256: `59d691c1a07034f79dc9df8e9ac151c9ff512d0d58dcdd069c611f6c0acf9b35`.

Actual iPhone AV1 hardware routing, AVPlayer latency, audio and device rotation
still need device comparison. The opt-in engine is not enabled by default.

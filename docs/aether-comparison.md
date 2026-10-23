# Optional AetherEngine comparison

Settings > App settings > 試験用AetherEngineを使用 defaults off. Snapshot the
choice when opening a recording: only non-recording encoded PLAY uses the new
controller. TS PLAY and every STREAMING request retain VLC. Closing the trial
releases the engine; switching off restores normal PLAY on the next opening.

The trial has video/audio, startup from the beginning, pause/play, ±10s, a seek slider,
double tap, orientation and diagnostic export. It deliberately has no comment,
subtitle, PiP or history-write integration. Trial playback starts at zero and
does not overwrite history. Software AV1 failed to display an initial picture
in the simulator both at 30s and at zero; subsequent target seeks succeeded.
Starting at zero isolates the comparison from resume integration; it does not
fix that AV1 software issue.

AetherEngine 7.46.0 is pinned by revision along with its transitive package
lock. One Swift 6.2 compatibility patch passes a Boolean capability verdict to
the routing closure instead of capturing a task-isolated C pointer; the same
profile exemption and post-panel retry remain. The packaging step verifies checkout
identity and collects dependency license texts, exact source links and source
build recipes. FFmpeg components remain dynamically embedded beside VLCKit.

Measure `seek.start` to `seek.videoResume`; keep `aether.seekLanded` separate.
Native output additionally requires an AVPlayerItemVideoOutput pixel buffer
whose item timestamp matches the current item clock after the engine's target
landing. Software output uses the engine's picture-following clock and labels
that evidence `engineRenderedClock`; do not conflate it with the pixel-buffer
check. Keep timeout/rejection/superseded outcomes rather than reporting a fast
seek from an optimistic clock. `aether.telemetry` contains periodic source-byte
and cache/restart counters; their update interval does not establish an exact
per-seek cache hit. No raw engine log lines, URLs, headers or titles are exported.

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

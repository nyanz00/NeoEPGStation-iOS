# Optional AetherEngine comparison

Settings > App settings > 試験用AetherEngineを使用 defaults off. Snapshot the
choice when opening a recording: only non-recording encoded PLAY uses the new
controller. TS PLAY and every STREAMING request retain VLC. Closing the trial
releases the engine; switching off restores normal PLAY on the next opening.

The trial has video/audio, resume startup, pause/play, ±10s, a seek slider,
double tap, orientation and diagnostic export. It deliberately has no comment,
subtitle, PiP or history-write integration. The server history may supply the
initial resume position, but trial playback does not overwrite it.

AetherEngine 7.46.0 is pinned by revision along with its transitive package
lock. The upstream engine is unmodified. The packaging step verifies checkout
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
origin serves H.264, HEVC 10bit and AV1 10bit MKV; each trial resumes at 30s,
seeks before/after that point, seeks while paused and closes cleanly. The same
binary must pass existing indexed VLC startup/rewind probes. Simulator AV1
software results do not predict iPhone hardware seek latency. Real performance,
audio, device rotation and LiveContainer behavior remain device checks.

# Encoded PLAY cached seeks

Encoded PLAY now opens the whole recording with a zero time origin. Resume and
transport restoration open paused, then use the existing verified native position
path. MP4 needs active decoding to establish that first target picture/clock;
this priming is hidden/muted, then restores the user's play/pause intent.
A normal seek before the resume/recovery position keeps the same VLC input,
container index and retained byte cache; it does not stop/reopen the player.

The displayed encoded clock uses libVLC's pause-aware native getter, like TS/HLS,
rather than extrapolating VLCKit's previous cached point during a discontinuity.
Accurate seeks are retained: neither fast/keyframe-only seeking nor global frame
dropping is enabled. Long GOPs can still require prerequisite reference decoding;
the compressed byte cache does not hold a second cache of decoded video frames.

Buffer percentage updates are coalesced at 100ms, but entering/leaving buffering
replaces the queued percentage update immediately. Seek video readiness is checked
both on frame arrival and when buffering completes, without waiting for another
frame or the periodic UI timer.

The `encoded-seek` Actions scope builds device/simulator apps and checks native
types, repeated cached MKV/MP4 seeks across a resume point using sparse 24-second
keyframes, continued video/clock progress, no input reopen/upstream data fetch, and
terminal buffering delivery. The shared zero-origin/buffering changes also passed
TS positioning and HLS checks in build 223. Simulator timings are diagnostics, not device performance
guarantees.

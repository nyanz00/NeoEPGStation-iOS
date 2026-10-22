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

## Decoder selection and output readiness

Every input explicitly requests `codec=videotoolbox,any` and
`videotoolbox-hw-decoder-only`. VideoToolbox is attempted first; unsupported
formats retain automatic fallback. This does not add codecs missing from the
pinned VLC build. The shared library/logger is retained.

The diagnostics separate `vlc.decoderPolicy` from `vlc.decoderSelected` and keep
a bounded `decoders` list outside the event ring. Only fixed module names are
exported. `avcodec` alone is reported as unknown acceleration, since the module
can use either hardware or software. A policy request is not a successful
hardware selection or proof of improved device performance.

An encoded seek can release its loading overlay when the native clock is near
the precise target and a new due output sample is confirmed, without waiting for
a delayed buffering notification. Future-dated target pictures arm one coalesced
presentation-time check rather than waiting for the 0.5-second UI timer. Input
and seek generation checks invalidate obsolete callbacks. TS/HLS retain their
additional position verification. Decoder preroll is still required; these
changes do not claim that the whole measured decoder wait can be eliminated.

Muted preparation is reapplied after media replacement and before each internal
play. The native mute getter must confirm mute before priming may start. A
pause command alone cannot release the guard: paused user intent requires an
actual Paused acknowledgement. State transitions and periodic samples include
the native mute state. Failed restoration also pauses before releasing mute.

The encoded probe includes paused reload, deliberate loss of the old output's
mute before priming, confirmed mute gates, deferred release until pause, and
stable paused clock/audio afterward. Decoder diagnostics parsing, redaction and
retention are checked by the Foundation tests. The focused Actions scope also
runs HLS and TS positioning checks because decoder policy and restoration are
shared; unrelated UI tests remain excluded.

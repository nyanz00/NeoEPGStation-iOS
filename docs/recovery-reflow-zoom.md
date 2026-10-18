# Recovery, responsive layout and full-display zoom

## Success conditions

- An HTTP outage extending beyond the input-opening deadline must retire that
  input. A one-byte upstream probe gates a fresh open at the retained position.
  No late `Paused` event from the retired input can complete restoration.
- Preserve the latest play/pause intent through the outage. Keep presentation
  time/comments held until the fresh output is usable. Native decoded-picture
  and lost-picture deltas distinguish real video from repeated paused callbacks;
  a correctly decoded static scene is valid. No continuous image comparison is
  added. Failed output verification remains bounded.
- Commentary track preference follows its name across recordings and reordered
  indexes. An unavailable preferred name falls back without overwriting it.
- Above 1x, the video viewport covers the player's entire display bounds,
  including safe-area margins. One-finger pan moves only video, clamped to the
  scaled image bounds. At 1x the normal viewport and center are restored.
  Navigation/orientation pans cannot steal an enlarged-video drag. Maximum 8x,
  zoom badges and existing light/medium haptic tails remain.
  VLC's drawable retains the normal viewport size while its center/affine
  transform change, avoiding asynchronous inner-video resize races. Pan limits
  use the source pixel aspect ratio as well as encoded dimensions.
- Sidebar row and bottom shortcut content have explicit reusable geometry.
  Visible recording cells update their horizontal/vertical mode with the list
  width, in addition to invalidating collection layout.
- Detail swipe-back duration is 0.22 seconds; finger tracking remains interactive.
  Player dismissal retains its previous 0.30-second duration.

## Targeted checks

Actions `check_scope=recovery-ui` builds both binaries, runs native model/type
checks, cycles sidebar safe-area margins and recording-list widths, and checks
full-display zoom/panning on iPhone and iPad. A synthetic HTTP MKV tunnel outage
lasts 58 seconds. Playback begins at 90 seconds so the file header has aged out
of the default 60-second rewind cache, matching a mid-recording outage and
crossing the 25-second opening deadline. Assertions require
retirement, an upstream availability check, a fresh reopen, held presentation
time and actual changing video/audio/comment progress after recovery. Unrelated
ARIB timing, complete page/navigation suites and TS startup checks are excluded.
The native probe leaves playback at 2x after completion; a compositor screenshot
must contain the synthetic video pattern at the display center. This detects
cases where view-frame assertions pass while the actual video stays at an old
origin. `drawHierarchy` snapshots alone are not accepted for this assertion.

## Verification result — Build 198

- Source: `f92597ad7df8e48e6b1493500aa73eb17ed84a7d` on `master`.
- [Focused Actions run](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/39125596654)
  succeeded: native model checks, Swift type checks, device and simulator builds,
  reflow/zoom checks on both simulator device classes, and the long tunnel test.
- iPhone and iPad each passed all 22 reflow/pan assertions. All 16 existing
  zoom-boundary, badge and haptic assertions also passed. The actual compositor
  screenshot passed the center-video pixel check and was visually reviewed.
  The drawable retained its normal bounds at 2x while only video was transformed.
- During the tunnel test, the opening deadline retired the input and the
  availability probe gated a fresh open at the retained position. Both
  `lateInputRetired` and `freshVideoAndAudioConfirmed` passed. The final samples
  showed video, audio and comment progress with no lost pictures.
- Commentary preference model checks cover name-based restoration, reordered
  indexes, and missing-name fallback without replacing the saved preference.
- Local workflow lint, eight CI-helper tests and whitespace checks passed.
- Build 196 exposed a legacy zoom test that reused the pre-expansion viewport
  height; its second gesture now uses the current viewport. Build 197 passed
  automated checks, but visual review exposed an ambiguous live-video snapshot
  with a stale origin. The final source keeps VLC drawable geometry stable and
  adds the compositor pixel assertion; these were verified in Build 198.
- IPA metadata confirms build `198`, bundle
  `io.github.nyanz00.NeoEPGStation`, and the bundled Noto Sans JP Bold font.
  SHA-256: `39548742033fe72df76912b5689876de8919c1bf0c198015eaec1ee5f6104b50`.

Actual train-radio conditions, hardware decoding differences, physical rotation
and the feel of interactive gestures still require device observation. Simulator
fault injection confirms this failure path and does not cover every network or
decoder failure mode.

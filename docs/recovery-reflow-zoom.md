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

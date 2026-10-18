# TS positioning and commentary resolution

## Success conditions

- Preserve the paused presentation position before entering decoder repair.
  Keep UI/history/comments at that target until fresh output confirms arrival.
- Healthy paused TS inputs remain retained. When foreground resource revocation
  requires rebuilding video, recreate the damaged TS input once at the saved
  position. Reselecting only paused TS video leaves the audio-master host-time
  origin stale: actual tests observed a roughly 4.5-second clock jump on play.
  Encoded inputs retain their existing partial decoder-repair path.
- Do not treat VLCKit's synthetic requested seek point as actual playback.
  Its pinned watcher sends the point before setting `seeking=true`; invalidate
  it at that transition, then retain genuine output updates arriving before
  `seeking=false`. Do not register a second, conflicting time watcher.
- TS reads LibVLC's native movie-time getter, whose timer accounts for paused
  dates and discontinuities, rather than VLCKit's separate cached convenience
  clock or an independently extrapolated watcher point. Watcher updates are
  retained to verify fresh output. Do not invent a new relative time origin.
- All TS position changes, including paused decoder priming, require the seek
  notification, LibVLC's native movie time near the target, newly decoded video
  and a new due sample. A same-position paused repair may not emit a new watcher
  point because its timestamp is unchanged; this is not a failed seek. The
  output stays hidden and the clock stays held until arrival is confirmed.
- JSON commentary uses normal 56 / big 84 / small 42 in a 1920x1080 space.
  Existing commentary ASS styles remain honored; a 28/200% normal style and
  JSON 56 both become 70 logical units at 1.25x.
- Raster resolution includes ASS scale and the user's multiplier before glyph
  generation, for screen drawing, preparation, packing and PiP. Logical text
  dimensions and motion remain independent of raster density. Existing cache
  limits remain, with a 256-pixel glyph-size safety cap.

## Focused verification

Use Actions `check_scope=ts-comments`. The HTTP TS probe runs H.264 and MPEG-2
with a nonzero source PCR origin, initial/later/earlier positions and paused
decoder repair after a background interval. A simulator-only incorrect wrapper
clock verifies that restoration uses the retained position and real native
points. Require exactly one reopen for damaged TS output, no repeated recovery
or seek loop, and continued video, audio and correctly timed comments afterwards.

The font probe compares actual bitmaps for matching TS and ASS small/normal/big
comments at 1.25x, including outline pixels and final display resolution. Native
model checks also assert that normal TS 56 at 1.25x is 70. No full navigation,
iPad rotation-notice, ARIB subtitle or unrelated network suite is requested.

## Verified result — Build 202

- Source `b095a65e598dce505f45e99bbc136142fbe21643`, on `master`.
- [Focused Actions verification](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/39162417080)
  passed native models, Swift UI type checking, device/simulator builds and all
  targeted runtime checks. H.264 and MPEG-2 each passed 24 TS assertions.
- Both codecs preserved the paused position across the background interval and
  reopened the damaged input exactly once. New clock/video confirmation took
  approximately 0.43/0.45 seconds from the repair request; final paused output
  verification completed in approximately 1.39/0.47 seconds. Video, audio and
  comments subsequently advanced with the incorrect wrapper getter still
  injected. No 10-second partial-repair timeout or repeated reload occurred.
- The font/gesture probe passed all 44 assertions, including six new checks for
  matching small/normal/big bitmaps at 1.25x and final display resolution.
- Earlier runs informed the final implementation: Build 199 exposed the MPEG-2
  watcher-clock mismatch; Build 200 demonstrated that paused same-position
  video can arrive without another watcher point; Build 201 then exposed the
  native shared-clock jump on resuming a partially rebuilt TS input. Build 202
  avoids that damaged-clock path instead of masking its displayed position.
- Local workflow lint, Python syntax checks, eight CI-helper tests and
  whitespace checks passed. The packaged IPA confirms build `202`, unchanged
  bundle identity and the bundled Noto Sans JP Bold font.
- IPA SHA-256:
  `9daa343599910dc219aa799c8fe3fd554d3bf31eb97e39d45c0c5e987ff46f4e`.

The synthetic HTTP TS fixtures have a nonzero PCR origin and exercise unknown
native duration/byte-position seeking. Arrival checks allow a two-second
tolerance for that seek path; this is not a claim of frame-exact TS seeking.
Actual device resource revocation and the supplied recording remain unverified
on hardware.

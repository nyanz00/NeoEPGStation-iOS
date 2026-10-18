# TS positioning and commentary resolution

## Success conditions

- Preserve the paused presentation position before entering decoder repair.
  Keep UI/history/comments at that target until fresh output confirms arrival.
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
points. Require continued video, audio and correctly timed comments afterwards.

The font probe compares actual bitmaps for matching TS and ASS small/normal/big
comments at 1.25x, including outline pixels and final display resolution. Native
model checks also assert that normal TS 56 at 1.25x is 70. No full navigation,
iPad rotation-notice, ARIB subtitle or unrelated network suite is requested.

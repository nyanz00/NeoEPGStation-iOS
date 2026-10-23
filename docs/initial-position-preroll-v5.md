# Initial positioning and preroll preparation (patch version 5)

## Behavior

`neo-initial-time` is a one-shot absolute position, separate from VLC's
`start-time` playback range. After demux/index/program discovery, before the
ordinary demux/buffering loop, VLC positions the input while leaving `i_start`
at zero. Later time/position seeks and reported duration still cover the full
recording. No additional player input or decoder session is created.

The app verifies real clock and fresh video at the requested position, retains
the muted/paused restoration gate, and does not send the previous second seek
when the native initial request succeeds. Demuxers that require an initial
clock/PCR retain the verified fallback after real output demonstrates that the
early request did not take effect. This is logged explicitly; a fallback is not
reported as a successful single-buffer startup.

## AV1 preparation

The first checked frame header from the reference-map scan is shared with output
ordering. It is not parsed again there. Existing reference updates, sequence
changes, key show-existing handling and malformed-input guards remain in place.
The independent sequence-header walk is retained for format changes.

Disposable preroll is rejected before creating CoreMedia sample/block wrappers.
Required parser, reference-slot and DPB/timestamp updates still run. H.264/HEVC
use the same wrapper optimization without broadening their drop conditions.

`vlc.prerollCost` aggregates one bounded record per preroll batch:

- `prepareMs`: host preparation; `sampleMs` is a component of this value.
- `submitCallMs`: total time inside the VideoToolbox submission API, including
  any synchronous work/callbacks, not a pure hardware-decode measurement.
- `callbackLatencySumMs`: sum of submission-to-callback intervals, which can
  overlap. Do not add it to wall time or label it independent decode time.
- `completionTailMs`: latest completion after the last submission returned.
- Submitted frames/sample wrappers, and AV1 skipped new INTER versus
  show-existing instructions. Ordinary playback does not emit per-frame logs.

## Verification and acceptance

Before Actions: compile the actual portable classifier with warnings as errors,
check shared-header/malformed/reference guards, compare all 1008 pictures from
the target onward for AV1 8/10bit and HEVC 10bit, apply the full patch stack to
the pinned sources, and check Python/build scripts and CI helper tests.

`startup-preroll` runs the same built application with old/new startup on the
same H.264 MKV and new startup on H.264 MP4, HEVC 10bit MKV and AV1 8/10bit MKV.
Require the old two-buffer path to be reproduced, native initial positioning
before the only startup-buffer completion, real target output, zero range
origin and no fallback on the indexed files. Each case also exercises repeated
cached seeks before the 30s resume point and paused restoration. Native cost
records must show `sampleBuffers + droppedFrames == frames` and preserve
output. Actual decoder modules determine which hardware paths were exercised;
software fallback is not hardware performance evidence.

Because initial positioning is shared by PLAY and STREAMING/recovery, also run
the focused HLS and nonzero-origin H.264/MPEG-2 TS resume probes. Do not run the
unrelated iPad/UI/ARIB matrix. A cold simulator's initial connection has a 20s
setup allowance; the measured repeated-seek allowance stays at 5s.

No AV1 speedup amount is assumed. Record measured results and remaining
hardware-only verification limits after the build completes.

The first build (239) passed all six indexed-file startup/cached-seek cases:
baseline had two buffer cycles and each optimized case had one, with full
rewind range and paused recovery retained. HLS exposed an early-position
validation issue: a successful request at 70s could start at its 68s segment
boundary, within the old 2s acceptance window. Initial verification now requires
500ms for every route and falls back to the existing exact seek on larger
offsets. The later ordinary TS/HLS restoration tolerance is unchanged. Native
sources are unchanged for this correction, so the verified v5 libraries are
reused. Independent HLS/TS probes retain each result even if one fails.

## Final result: build 240

Actions run `39953704447`, application source `59053b3`, succeeded. Both native
libraries reused the exact verified v5 inputs from run `39950215381`. Native
type checks and application builds passed for device and simulator.

All 423 focused functional checks passed: 288 across the six startup/cached-seek
cases, 44 encoded HLS, 43 TS HLS, and 24 each for H.264/MPEG-2 raw TS resume.
The indexed PLAY cases retained the full recording range, verified output at
30s, rewound before that position, and restored paused playback correctly.

| Simulator startup case | Buffer cycles | Ready time (ms) |
| --- | ---: | ---: |
| H.264 MKV, previous startup | 2 | 3810 |
| H.264 MKV, initial positioning | 1 | 1390 |
| H.264 MP4 | 1 | 839 |
| HEVC 10bit MKV | 1 | 1530 |
| AV1 8bit MKV | 1 | 658 |
| AV1 10bit MKV | 1 | 764 |

These are synthetic simulator samples, not iPhone hardware speed measurements.
HLS and raw TS retain the verified exact-position fallback when early seeking
is unavailable or lands at a segment boundary; a universal single-buffer
startup is not claimed. Controlled HLS outage/recovery, clock progression,
quality switching and session teardown also passed.

The production portable classifier passed its guards with compiler warnings
treated as errors. All 1008 pictures from the target onward matched baseline
for each of AV1 8bit, AV1 10bit and HEVC 10bit. The corresponding preroll skips
were 358, 358 and 359. CI helper tests passed all 10 cases.

The actual simulator VideoToolbox H.264 path emitted 20 cost batches: 1464
sample wrappers created and 1464 frames dropped before wrapper creation, with
the count/timing invariants satisfied. AV1 used dav1d software decoding in the
simulator. AV1 hardware seek latency and the new cost breakdown therefore
still require the actual iPhone VideoToolbox path; no hardware speedup is
inferred from these simulator results.

Delivered `dist/NeoEPGStation.ipa` is build 240, SHA-256
`c26cddc2460e018860f448b397e5a9a194e065fdaff5018bea667e918bf6bf6e`.
The embedded framework hash, v5 markers, all four bundled patches, AV1 source
includes and complete corresponding-source archive were checked against the
verified native provenance and current source files.

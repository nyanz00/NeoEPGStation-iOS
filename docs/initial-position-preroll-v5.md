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

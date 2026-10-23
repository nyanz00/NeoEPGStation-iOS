# Modified VLCKit / libVLC

VLCKit remains at `2e0868f5ed40fe59cd92f377645fdcc260c6e759`
(4.0.0a25). Its build recipe pins VLC to
`005e69e67a8730f128e44bde68437fbb048cf45f` and applies the wrapper's
`libvlc/patches/*.patch`. These sources are available at:

- https://github.com/videolan/vlckit/tree/2e0868f5ed40fe59cd92f377645fdcc260c6e759
- https://github.com/videolan/vlc/tree/005e69e67a8730f128e44bde68437fbb048cf45f

The additional LGPL-2.1-or-later patches and `av1.c.inc` in this directory add
AV1 Main profile 4:2:0 8/10-bit support to the existing VideoToolbox decoder.
They retain VLC's demuxer, audio clock, output, flush, PiP and precise seeking.
The OS hardware capability is queried once, not tested by playing a video.
Unsupported hardware/configuration selects dav1d through normal VLC module
selection. An AV1 VT session requires hardware acceleration; its actual session
property is checked before the first compressed sample is submitted. A failed
session initialization falls back before playback, without reopening the input.
Seek flushes discard/wait for outstanding old frames using the existing VLC
decoder lifecycle. An unrecoverable runtime VT failure uses VLC's existing
one-way `videotoolbox-failed` fallback for that elementary stream.

Patch version 3 also avoids output images for explicitly marked, dated,
progressive preroll pictures before an accurate seek target. Reference decoding
and POC/DPB metadata are retained. `DoNotOutputFrame` is a hint; even if VT returns
an image, the decoder does not wrap it in a VLC output picture. An expected NULL
output is not treated as decoder failure. Preroll submission is bounded to 16
outstanding frames; normal output pacing and memory limits stay unchanged.
Submission accounting precedes DecodeFrame and saves callback-owned scalars,
including when the no-output callback occurs before DecodeFrame returns.
The per-input `videotoolbox-skip-preroll-output` flag defaults to true; only the
simulator diagnostic launcher exposes a same-binary baseline override. Numeric
`neo-preroll-ready` diagnostics record the suppression, queue wait and duration.
Non-reference H.264 preroll slices are not submitted for decoding at all, after
the existing parser has updated SPS/PPS/SEI/POC and all VCL NALs have been checked.
Unknown, partitioned, mixed-reference, extension, interlaced and end-of-sequence
pictures retain the original path. For ordered AV1 preroll, VT is asked to use
OnlyTheseFrames/NonDroppableFrames, restoring AllFrames before display resumes.
An unsupported optional property leaves full decoding enabled; a failed restore
uses the existing one-way module fallback rather than dropping normal frames.
`neo-preroll-filter` records whether AV1 accepted this request.
`encoded-seek` compares enabled/disabled runs on the same 1080p H.264 MKV/MP4,
then checks AV1 fallback and seeks. Simulator results do not establish AV1
hardware seek performance on a physical iPhone.

Patch version 4 adds conservative HEVC/AV1 decoder-only reference skipping
in `neo_preroll.h`, independently of Apple's optional frame filter. HEVC _N
slices must all belong to layer 0 and the active SPS's highest temporal layer.
AV1 tracks reference-slot types across every temporal unit, resetting on flush
and sequence changes. Only no-refresh displayed INTER pictures and known
non-KEY show-existing units are omitted. Hidden/reference pictures, KEY
show-existing (which refreshes all slots), mixed/unknown units and unsupported
frame-ID/timing/scalability configurations retain full decoding. The AV1 reorder
parser no longer reads padding after show-existing as a KEY frame. CoreMedia
duration/DTS units are corrected for HEVC as well as AV1.

`scripts/preroll-reference-test.py` compiles the production C classifiers and
compares the complete 42 seconds after the seek target (1008 decoded picture
hashes per synthetic 8/10-bit AV1 and 10-bit HEVC fixture). `--compare-hevc`
compares the same binary/input/targets with image suppression enabled on BOTH
sides; only new reference skipping is disabled in its baseline. AV1 simulator
fallback tests and reference correctness do not establish physical AV1 hardware
speed. Device performance must be measured separately.

`scripts/build-vlckit.sh` builds arm64 device and simulator slices separately.
The upstream deployment target is raised to iOS 18, matching this app. GNU
source downloads use an explicit HTTPS mirror instead of a redirect that can
select an expired mirror; upstream source checksums remain mandatory. The m4
archive missing from VideoLAN's mirror uses bounded, verified HTTPS fallbacks.
GNU make 4.4's FIFO jobserver and the host pkg-config macros are exposed to the
upstream build tools. No codec
dependency version is changed. The wrapper's official archive functions are
used with signing disabled for the framework and unused CPU slices omitted.

On macOS with Xcode 26.6, from the repository root:

```sh
bash scripts/build-vlckit.sh iphoneos
bash scripts/build-vlckit.sh iphonesimulator
xcodebuild -create-xcframework \
  -framework build/vlckit-output-iphoneos/VLCKit.framework \
  -framework build/vlckit-output-iphonesimulator/VLCKit.framework \
  -output vendor/vlckit/VLCKit.xcframework
cd ios && bundle exec pod install --deployment
```

The Actions library workflow caches compiled frameworks and incremental source
builds. Cache/artifact reuse checks the source revisions, additional patches,
SDK, Xcode and binary SHA-256. Change `source.json` when the intended build
configuration or source version changes. CocoaPods links this local framework;
it never substitutes the official binary that lacks the AV1 extension.

The device library build preserves complete modified VLC/VLCKit sources,
downloaded dependency source archives and the build recipe in the
`VLCKit-corresponding-source.tar.gz` artifact. Distribute corresponding sources
alongside a modified library, including when distributing beyond development
artifacts; retain them independently before Actions artifact expiry. This
directory's patch, source references and LGPL notice are also included in the
app's ThirdPartyNotices. The existing component licenses still apply.

The `av1-decoder` app check uses actual AV1 8/10-bit MKV and MP4 fixtures with
sparse keyframes, repeated accurate seeks and paused recovery. A simulator's
successful software fallback does not establish AV1 hardware playback speed on
an iPhone/iPad. Verify native `hardware=1` plus the selected `videotoolbox`
module on a supported physical device before reporting hardware performance.

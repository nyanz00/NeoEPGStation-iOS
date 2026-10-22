# Modified VLCKit / libVLC

VLCKit remains at `2e0868f5ed40fe59cd92f377645fdcc260c6e759`
(4.0.0a25). Its build recipe pins VLC to
`005e69e67a8730f128e44bde68437fbb048cf45f` and applies the wrapper's
`libvlc/patches/*.patch`. These sources are available at:

- https://github.com/videolan/vlckit/tree/2e0868f5ed40fe59cd92f377645fdcc260c6e759
- https://github.com/videolan/vlc/tree/005e69e67a8730f128e44bde68437fbb048cf45f

The additional LGPL-2.1-or-later patch and `av1.c.inc` in this directory add
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

`scripts/build-vlckit.sh` builds arm64 device and simulator slices separately.
The upstream deployment target is raised to iOS 18, matching this app. GNU
source downloads use the canonical HTTPS host instead of a redirect that can
select an expired mirror; upstream source checksums remain mandatory. No codec
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

# Third-party software

The optional checkpoint diagnostic uses the unchanged Metal LZ4 kernel from
rcomp-metal 0.4.0, published on crates.io. We use the upstream Apache-2.0
licensing option (Cargo.toml declares MIT OR Apache-2.0). The original source,
license, notices, crate checksum and a description of our new iOS host bridge
are included in `ThirdPartyNotices/RcompMetal`. The upstream macOS Rust host
and precompiled macOS metallib are not part of the running iOS dependency.

The optional AV1 checkpoint diagnostic statically includes an isolated, modified
BSD-2-Clause dav1d 1.5.4, LZ4 1.10.0 (BSD-2-Clause), and Zstandard 1.5.7
under its BSD-3-Clause option. Their notices, pinned revisions, source hashes
and the checkpoint modifications are in `ThirdPartyNotices/CheckpointDav1d`
and `ThirdPartyNotices/CheckpointCompression`. The diagnostic decoder and
compression functions use private namespaces and do not replace playback
engine symbols. See `docs/checkpoint-trial.md` for the diagnostic boundary.

The optional encoded-PLAY comparison screen uses AetherEngine 7.46.0,
revision `40193cefa7244c097519d219f84af1b9028c181c`, under LGPL-3.0 with its
Apple Store / DRM Exception. Source: https://github.com/superuser404notfound/AetherEngine/tree/40193cefa7244c097519d219f84af1b9028c181c
The engine carries a small Swift 6.2 compatibility patch: evaluate the hardware
capability synchronously and capture only the Boolean verdict in a routing
closure. Its source, SHA-256 and patch are retained in the notices and source
archive. FFmpegBuild supplies dynamically embedded FFmpeg,
dav1d, zimg and zvbi libraries with their own licenses; LibDovi supplies the
Dolby Vision parser under its upstream MIT option. Exact resolved source pins,
component license texts and upstream source/build recipes are retained in
`ThirdPartyNotices/AetherEngine` inside the app and the build artifact's
`AetherEngine-source-recipes.tar.gz`. FFmpegBuild's pinned build recipe names
the upstream source revisions and the applied patches. These components do not
inherit AetherEngine's store exception.

The initial application skeleton comes from the MIT-licensed
[React Native Community Template](https://github.com/react-native-community/template).
Its notice is preserved in `licenses/ReactNativeTemplate-MIT.txt`.
The current application uses Swift / UIKit and does not ship the React Native
runtime or JavaScript dependencies. The template notice remains for retained
project scaffolding.

The retired prototype used [react-native-url-polyfill](https://github.com/charpeni/react-native-url-polyfill)
4.0.0 under the MIT license. Its notice is preserved in
`licenses/ReactNativeURLPolyfill-MIT.txt` and included in the IPA.

The retired SVG wrapper used react-native-svg 15.15.5 (MIT), copyright (c)
[2015-2016] [Horcrux]. Its notice is retained in `licenses/ReactNativeSVG-MIT.txt`.
The current icon paths are drawn with UIKit and do not use that runtime.
Material icon paths match those used by NeoEPGStation Web: the MUI distribution
is MIT (copyright (c) 2014 Call-Em-All), and the underlying Google Material Design
icons are Apache-2.0. FilmstripBoxMultiple and TelevisionGuide are by the
Pictogrammers contributors under Apache-2.0. License texts are preserved in
`licenses/MUI-icons-MIT.txt` and `licenses/Apache-2.0.txt`.

VLCKit and libVLC are VideoLAN projects distributed under LGPL-2.1-or-later;
the bundled framework and its components have their own notices and licenses.
The original unmodified framework was downloaded from:

https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip

Wrapper source and packaging recipe:

https://github.com/videolan/vlckit/tree/2e0868f5ed40fe59cd92f377645fdcc260c6e759

The current framework is rebuilt from the pinned wrapper and VLC base:

https://github.com/videolan/vlc/tree/005e69e67a8730f128e44bde68437fbb048cf45f

The wrapper's upstream patches and the additional AV1 VideoToolbox patch are
applied before building. Source revisions, additional source/patches, LGPL text
and build/distribution instructions are in `vendor/vlckit/` and included in the
app's `ThirdPartyNotices`. The library build artifact also contains the complete
modified library and downloaded dependency sources.

Keep the archive's COPYING notices with distributed artifacts. Any modified
VideoLAN components must be accompanied by the corresponding source and patches.
The dependency and distribution requirements must be checked before a public
App Store release.

The diagnostic lsCOMP lossless adaptation is based on revision
`d920dd9dc8ddbd2684c777d1e2ba27397212e59c` of
https://github.com/szcompressor/lsCOMP . Copyright (c) 2025 UChicago Argonne
and University of Iowa. Its upstream BSD-3-Clause-style license, pinned
source files and source hashes are in `ThirdPartyNotices/LsCOMP`.
The CPU reference, new container and four-stage Metal implementation are
modified lossless-only code, with quantization and pooling disabled; they
are included in `ThirdPartyNotices/CheckpointDav1d`. The original CUDA
kernel is retained as source and is not executed on iOS.

The diagnostic Metal Zstandard backend adapts the BSD-3-Clause option of
Meta Zstandard 1.5.7's format, FSE and Huffman arithmetic for an iPhone Metal
encoder. Copyright (c) Meta Platforms, Inc. and affiliates. Its complete
license and modified encoder/bridge sources are retained in
`ThirdPartyNotices/CheckpointDav1d` (MetalZstd-LICENSE, metal-zstd*).
The bounded matcher, GPU scheduling and host bridge are new code. No
source or shader from gpu-zstd-comp is distributed or translated into this
backend. CPU preprocessing and CPU decompression remain outside the GPU encoder.
The parallel revision keeps the 64KiB match window, parses 4KiB parts, reuses
device buffers, cooperatively builds Huffman codes, and packs independent
FSE/Huffman tokens with GPU prefix sums. The scalar encoder is retained only
as a native diagnostic control, not an automatic runtime fallback.

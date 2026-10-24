# AV1 decode comparison lab

Opt in under Settings > App settings > Playback engine > AV1 decode comparison.
Open an encoded AV1 file using PLAY, then press Start. The ordinary VLC,
Aether and direct-AVPlayer selections keep their existing behavior. TS,
STREAMING, subtitles, comments, PiP and history are outside this lab.

Preparation reads a bounded initial real GOP plus up to one second of following
packets (96 MiB, 3,000 video packets, 65 media seconds, 90 seconds wall budget;
individual remote reads retain the still-extractor's finite timeout). Packet PTS
must be present. Unsupported inputs fail explicitly. The lab never downloads a
whole recording intentionally. Prepared packets are immutable and resident in
memory before any measurements. It also writes a disposable video-only MP4
with those same packets for the Aether baseline; this is stream copy, not a
re-encode. The bundled FFmpeg registers MP4/mov/HLS muxers, not a Matroska muxer.
The temporary clip is removed after the run.

Targets are 10%, 50% and 90% of the first actual GOP, repeated twice. Aether's
existing target-frame observation runs against the local clip, with no audio.
Native target pixel-buffer timing and untimed software output remain separate.
A baseline error is retained without preventing the raw decoder comparisons.

Direct tests create fresh libdav1d and hardware-required VideoToolbox sessions.
Initialization is reported separately from feed-to-target-output latency.
These are not warm decoder seek timings and not physical screen latency.
VideoToolbox input sample creation/copy and decoder submission are included;
this is a boundary comparison, not a pure silicon throughput benchmark.
The current method measures all required preroll frames without adding a new
frame-skipping optimization, second decoder or state checkpoint feature.

libdav1d supplies the first decoded target PTS and a post-timing 64x36 luma grid
fingerprint. Hardware results require a confirmed hardware-use property,
matching PTS/dimensions and a luma-grid mean difference <=2 in 10-bit units.
This is a sampled image check, not a full-frame bit-exact equivalence claim.
AV1 film grain or backend reconstruction differences can fail this check; such
rows are explicitly mismatches and must not enter successful latency summaries.
No conversion/hashing of the target image is included in decodeMs. Timeouts,
missing hardware, format/session rejection and missing target output are never
reported as fast successful measurements. Two fresh-decoder repetitions expose
startup variability but do not establish steady-state battery or thermal cost.

The result is saved as Documents/decode-benchmark.json and can be shared from
the lab screen. It contains numeric measurements/fixed tokens, not source URLs,
titles, credentials, frame images or media payloads. Backgrounding/closing cancels
the run; an in-flight synchronous native operation can finish before releasing
its resources. Standard playback is not redirected into these raw decoders.

The focused Actions scope `decode-trial` builds both SDKs and runs the real screen
with long-GOP AV1 8/10-bit fixtures, checks decoded target PTS and repeated luma
fingerprints, bounded preparation, result export and explicit hardware absence.
Simulator timings do not establish iPhone hardware performance. Device results
must be collected on the target phone before choosing a production change.

## Build 268 verification

Source `edcc50f99cc1a3911c07e81a702d7c6a76d4df9d`,
[Actions 40130827168](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/40130827168):
device/simulator builds, FFmpeg import isolation, source provenance and the
focused diagnostic-screen test passed. Both 8/10-bit fixtures have a real
24-second initial GOP. The lab completed six Aether observations and six dav1d
target outputs per fixture. Twelve hardware rows explicitly report unavailable
on this simulator; none is counted as a hardware performance result.

Independent FFmpeg extraction confirmed all twelve dav1d luma fingerprints.
The 24-fps fixtures use exact frame indices 58, 288 and 519 for the three targets,
with `extractplanes=y` and `-fps_mode passthrough`. Default output frame-rate
synchronization can select a neighboring image and is unsuitable as this oracle.
The 8-bit Aether observations have verified displayed pixel-buffer timestamps;
10-bit simulator observations retain the existing decoded-target-plus-untimed-
picture distinction and must not be described as measured on-screen latency.

The IPA ZIP CRC, embedded build number and complete engine patch manifest match
the verified source recipe. Artifact: `NeoEPGStation-build268.ipa`, SHA-256
`f8c2141c397f630a2a3759f732bd53756131855c535b0bc42c055cf8248b3644`.
Hardware-required VideoToolbox timing and picture matching on an AV1-capable
iPhone remain a device measurement, not a simulator-build claim.

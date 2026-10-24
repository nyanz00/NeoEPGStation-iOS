# Aether cached seek work and diagnostics

Scope: optional Aether encoded PLAY only. VLC, direct AVPlayer, TS and STREAMING
keep their current behavior. AetherEngine remains pinned at 7.46.0. The new
0005 source patch is diagnostic-only and preserves the engine's seek policy.
No new cache size or AVPlayer stall policy is selected without device evidence.

Confirmed unnecessary work: the 60 Hz adapter timer called updatePlayback and
updateDiagnostics every tick. Each function rasterizes a 60-point play/pause
image; updatePlayback also requests layout even when its integer-second labels
and playback state have not changed. The adapter now updates those controls on
state changes, keeps smooth slider updates and the 60 Hz target-frame probe,
and checks the picture before refreshing controls. Unchanged surface frames are
not reassigned during layout. This removes confirmed repeated UI work; it is
not proof that every slow hardware seek was caused by that work.

Success conditions: reduced controller update count on the identical synthetic
source, unchanged accurate target images for playing and paused seeks, no loss
of the software fallback, bounded per-seek sampling with correct time axes,
and no raw URL/header/title export. Simulator seek times do not establish a
physical device speed gain.

The new aether-seek workflow scope runs the same H.264 source with original
per-frame refresh and with change-driven refresh, then HEVC and AV1 optimized
cases. It validates every actual target picture and controller teardown. The
baseline flag exists only in simulator builds. Other-player and unrelated UI
matrices are excluded from this focused scope.

New exported events:
- aether.seekSnapshot: request/completion/picture plus 200/600 ms pending edges;
  display/item target, source origin/playlist shift, planned segment index,
  start/duration/offset, resident-index metadata, source/mux/server byte and
  request/restart counters, AVPlayer buffered target/ahead, timeControlStatus,
  waiting reason (0 none, 1 minimize stalls, 2 evaluate, 3 other), buffer flags.
- aether.segmentServed: numeric segment index, file fast-path flag, delivery
  result and complete server-handler duration. These may include prefetch, not
  only the target segment; match indices/times to snapshots. File fast-path is
  not a universal cache-hit flag; resident metadata is not proof of a surviving
  file. A missing event can mean AVPlayer already had that segment buffered.
- aether.seekUIWork and aether.uiSummary: actual refresh counts/time and timer
  gaps. Callback completion and actual target-picture verification stay separate.

Snapshots are asynchronous, never atomic pipeline stages. Request/finish times
identify their sampling interval; counter differences include concurrent prefetch.
AVFoundation getters run off-main with a 150 ms diagnostic deadline, at most one
worker in flight process-wide, even after a caller times out. Pending requests
coalesce; superseded/source-changed results are rejected. A busy or timed-out
read is marked unavailable. Admission opens again only when the actual worker
returns, so slow reads can recover without creating a queue of stuck threads. Playback does not await
these diagnostics. Existing periodic telemetry remains explicitly age-stamped.

Verified build 265, source e9db60ff38344fa0b7f4b5c132e2a95ccaf48690,
Actions run 40104159617: device/simulator builds, package/hash/provenance and
FFmpeg binding isolation passed. The focused test passed all four cases
(H.264 per-frame baseline, H.264 changed-state UI, HEVC and AV1), 48 controller
checks, 20 source-reference target images, and seek-associated diagnostic
snapshots for every operation. H.264 playback refreshes fell from 441 to 8 and
diagnostic refreshes from 441 to 1 on the same operation sequence. Measured UI
refresh work was about 984 ms vs 8.9 ms across those respective runs; run lengths
and simulator timing differ, so this is not a physical-device latency claim.

All four simulator cases selected the software route. Thus software fallback,
UI work reduction and diagnostic unavailability handling are exercised. The new
native loopback cache/AVPlayer snapshot and segment-serve metrics compile in
both binaries but were not exercised by those simulator cases. On-device
native diagnostic availability and actual seek-speed improvement remain open.

Installable artifact: NeoEPGStation-build265.ipa, SHA-256
`deb3cc01e7c6612126ba0a7f8d9c34aacf94c06edd71ef6eff10a94797862b8f`.

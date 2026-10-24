# Direct AVPlayer comparison

Settings > App settings > 再生エンジン selects 標準：VLC (default), 試験用：AetherEngine,
or 試験用：AVPlayer直接再生. Existing Aether opt-in preferences are preserved;
an explicit new selection takes precedence, including switching back to VLC.
The choice applies when opening the next recording. TS, ongoing recordings and
STREAMING retain their existing VLC path regardless of the trial selection.

Direct AVPlayer uses the existing server `/api/videos/{id}/web` endpoint. The
Web client also selects that endpoint for Apple mobile WebKit. Matroska is
remuxed to fast-start MP4 by the server with video/audio stream copy, not
re-encoded. A cold server cache needs preparation before the response; an
existing compatible source is served directly. No server changes are needed.
There is no on-device muxer or local HLS server in this comparison route.

The trial starts at zero, keeps the existing NeoPlayerChrome and connects
play/pause, time display, accurate timeline seeks, skip/double-tap, rotation,
program information and diagnostic export. Comment/subtitle/PiP/history,
zoom/navigation gestures and unconnected settings are sealed as in the Aether
comparison. Playback failure stays visible and suggests the standard engine;
there is no silent switch that could invalidate an engine comparison.

`avplayer.seekCompleted` records Apple's seek callback, separately from
`seek.videoResume`. The latter requires a fresh AVPlayerItemVideoOutput buffer
near the target and a display-ready AVPlayerLayer. It is an observed target
frame timestamp, not a physical-screen scanout measurement. Clock updates alone
cannot finish a measured seek. Capture includes timeControlStatus, fixed waiting
reason tokens and loaded buffer depth to distinguish buffering from notification
latency. Stale callbacks from superseded seeks are ignored. Close pauses,
cancels seeks, detaches the output/layer and releases the item/player. The trial
pauses in background and resumes according to the user's last play intent.
Diagnostics omit URLs, headers, titles and raw framework error descriptions.

Validation scope `avplayer-compare` builds device/simulator and runs preference
migration/routing tests plus direct HTTP Range H.264/HEVC Main 10 MP4 startup,
four playing seeks, one paused seek, actual target image comparisons and teardown.
The origin accepts only `/api/videos/1/web`, so accidentally selecting a raw
endpoint fails. Existing source-hashed image references verify the media target;
image conversion happens after latency measurements. AV1 hardware decoding and
relative seek speed require a physical device; simulator timing is not a speed
claim. The default VLC engine and Aether pipeline have no playback changes.

The HEVC MP4 fixture has video start 0.021 s and AAC start 0 s, unlike the
zero-origin MKV reference. Integer item-time seeks show the preceding video
frame (for example 19.979 at 20 s). Direct comparison uses separate source-
hashed MP4-time references for those frames. Target identities must still beat
all wrong targets with the original strict threshold; no matcher tolerance was
relaxed. The H.264 MP4 and original MKV references already share the same origin.

Build 263 (`efbc5be088e251f0961197a3d82b207c3c3c81b1`) passed device/simulator
builds, native preference/routing checks and both FFmpeg import isolation guards
in Actions run 40092182300. Run 40094013683 reused that exact application after
the test-only MP4 reference correction and passed both direct MP4 cases, all
24 controller checks and all 10 target-image checks, including paused seeks.
The original run's overall result was failed due to the reference mismatch;
the successful recheck supplies the functional verification. No additional IPA
was built. Real-device AV1 playback and perceived seek speed remain unverified.

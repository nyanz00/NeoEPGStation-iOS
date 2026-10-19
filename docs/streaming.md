# Recorded STREAMING

- Uses the existing recorded VOD HLS API, not PLAY's Range proxy.
- Source file and quality are chosen from server capabilities. PLAY remains available separately.
- TS segments are 6.006 seconds; encoded segments are 4 seconds. Buffer preferences store segment counts and display their corresponding seconds. Defaults: two segments ahead, approximately one minute retained behind.
- The HLS proxy uses a private loopback listener, authenticated same-origin upstream requests, disk segment retention capped at 256 MiB, and an independent server session per player/quality. Actual retained intervals feed the existing seek bar.
- HLS prepares the requested frame with output hidden and audio muted, then restores the user intent. VLC adaptive HLS did not supply a target video frame when kept start-paused in the first simulator probe.
- The playlist represents the whole recording. Initial resume, seek, reopen and quality changes use that whole-file clock, without adding the requested position to VLC's clock.
- Session heartbeat: PUT every ten seconds. Release: DELETE on close/quality change. Reopening the playlist re-registers an expired session.
- Comment workers use the original video API, not the HLS URL. Encoded ordinary subtitles are extracted separately and attached to VLC/libass, with no server-side burning. HLS-TS native ARIB availability depends on the selected server encoding profile retaining ARIB data.
- PiP combines the decoded video, VLC's scheduled subtitle regions, and the existing comment renderer.

## Focused verification

`check_scope=streaming` builds device and simulator applications, runs the existing parser/clock model checks and HLS manifest/settings checks, then exercises synthetic encoded/TS HLS through the real VLC player. The synthetic server records playlist arguments, segment fetches, deliberate failures, session heartbeats and releases. No private recordings or connection settings belong in these fixtures.

Hardware behavior, actual server encoding speed, radio transitions and operating-system PiP/background restrictions still require device confirmation. Simulator success is not evidence of those hardware conditions.

## Use

Open a recording detail, select STREAMING and a source file, choose a server-provided quality, then start viewing. The player settings expose independent HLS ahead/rewind choices; changing PLAY cache preferences does not change HLS retention. Streaming quality can be changed during playback while retaining the requested whole-recording position.

The ahead setting is a target, not a promise of immediate readiness: server encoding and available bandwidth can limit it. Retained ranges show downloaded complete segments. Retention also obeys the 256 MiB disk cap. Unsupported encrypted/init-segment HLS is rejected instead of forwarding resources outside the authenticated proxy.

The native recovery checks distinguish a reachable session API from media readiness. A twelve-second playlist outage with successful keep-alives must restore a decoded target frame within twenty seconds, issue at most ten failed playlist requests, and avoid the unrelated input deadline. Clock checks require early video/comment progress and exact native/app agreement after the bounded five-second startup guard, plus continued playback thereafter.

## Verified build

Build **211**, source `e6b1fab8fe1bc56676b04da2387f4f8511e29383`: [Actions run and downloadable IPA](https://github.com/nyanz00/NeoEPGStation-iOS/actions/runs/39318714143).

Device and simulator builds, native parser/clock/model checks and UI type checks passed. Real VLC simulator playback passed all 97 assertions: encoded HLS 25, TS HLS 24, existing H.264 TS PLAY 24, existing MPEG-2 TS PLAY 24. Server-side fixture assertions also passed for the injected media outage, bounded retries, retained target, quality modes, subtitle extraction and session heartbeat/release. These checks use synthetic media and a controlled API server; actual server encoding, hardware decoding, cellular handoffs and OS PiP remain device verification items.

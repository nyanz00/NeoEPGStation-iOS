# HLS clock investigation

This is an isolated diagnostic application, not the product player. Its small
Objective-C interface declarations call the unchanged VLCKit taken from a
verified simulator application. The workflow verifies the original application
source and its recorded checks before reusing the framework.

`fixtures.zip` contains synthetic solid-color video and silence only. Generate
it with `python tests/hls-clock-probe/generate-fixtures.py` on a machine with
FFmpeg and a working NVIDIA encoder. The committed archive was generated with
FFmpeg 7.1.1; it avoids installing a different FFmpeg version on the runner.
The SHA-256 file checks archive integrity. `origins.json` records ffprobe's
first segment timing and first video packet PTS/DTS.

The cases independently vary:

- Full media versus generation beginning at 48 seconds.
- Original timestamps versus timestamps restarted near zero.
- B-frame encoding with zero mux delay versus FFmpeg's default mux delay.
- MPEG-TS-to-HLS copy mux with or without preserving timestamps.
- Automatic HLS start at 49 seconds, with or without an additional native seek.

Console output and periodic JSON survive a library abort. Simulator console
exit codes alone do not prove playback passed; check `finished`, the samples
and any matching assertion. A completed probe is an observation, not a claim
that all seeking, captions, PiP, or device behavior has passed.

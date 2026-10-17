# TS PLAY position, comments and bundled font

TS PLAY uses whole-recording timestamps. It no longer adds a requested resume
time to the native input clock or derives a whole-file byte seek from a relative
input offset. A nonzero TS start opens paused, positions against the full file
duration, and confirms the native clock before releasing playback and comments.
An unknown-duration HTTP input uses VLC's existing byte-position fallback; this
is approximate for variable-bitrate TS. A failed arrival has a bounded deadline
and is reported rather than accepted as a successful restore.

The existing comment preparation setting still gates input opening. TS comments
are no longer held behind an incorrect start-time offset after preparation.

Commentary ASS and TS JSON comments both use Noto Sans JP Bold for measurement
and rasterization, including PiP. Ordinary subtitles and ARIB rendering are
unchanged. The font comes from notofonts/noto-cjk, tag Sans2.004,
`Sans/SubsetOTF/JP/NotoSansJP-Bold.otf` (PostScript name `NotoSansJP-Bold`).
SHA-256: `1b0edfb500b73a4fa8a4fcaae1bbbd403994e08e73e3e0da37e70d3853f42c5f`.
The SIL Open Font License is bundled with the application and kept in
`licenses/NotoSansJP-OFL.txt`.

Zoom feedback uses light on expansion and medium at original size, retaining
the existing short continuous tails. Releasing an enlarged pinch has no feedback.

## Focused verification

Actions `check_scope=ts-comments` builds device/simulator apps, runs native model
and type checks, verifies zoom/haptic settings and actual Japanese/Latin font
runs, and plays a synthetic constant-rate HTTP TS with nonzero PCR origin.
The TS probe checks initial resume at 49 seconds and paused reopen at 63 and
53 seconds, native clock arrival, immediate subsequent clock/video/comment
progress, and opening only after comment preparation. It does not run unrelated
iPad UI, rotation, ARIB timing or network fault suites. Simulator success does
not establish physical haptic feel or results on every broadcast TS file.

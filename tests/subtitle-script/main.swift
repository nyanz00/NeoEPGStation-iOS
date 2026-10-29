import Foundation
let original = "[Script Info]\nPlayResX: 1280\n[V4+ Styles]\nStyle: Keep,Arial,28\n[Events]\nDialogue: 0,0:00:01.00,0:00:05.00,Keep,,0,0,0,,{\\pos(100,200)}元の字幕"
precondition(NeoSubtitleScript.ass(original) == original, "ASS styles and overrides must stay verbatim")
let srt = NeoSubtitleScript.ass("1\r\n00:00:01,250 --> 00:00:03,500\r\n<b>Bold</b>\r\nSecond\r\n\r\n2\r\n00:01:00,000 --> 00:01:01,000\r\n日本語")
precondition(srt.contains("0:00:01.25,0:00:03.50") && srt.contains("{\\b1}Bold{\\b0}\\NSecond") && srt.contains("0:01:00.00,0:01:01.00"))
let vtt = NeoSubtitleScript.ass("WEBVTT\n\ncue\n00:01.000 --> 00:03.000 align:center\n<i>文字</i> &amp; text\n\n00:09.000 --> 00:08.000\nInvalid")
precondition(vtt.contains("{\\i1}文字{\\i0} & text") && !vtt.contains("Invalid"))
precondition(NeoSubtitleScript.ass("invalid").contains("[Events]"))
print("PASS: original ASS styles; SRT/WebVTT times, multiline, emphasis, entities and invalid cues")

import Foundation

let source = URL(string: "https://example.test/root/api/streams/recorded/1/vodhls/playlist?ss=8")!
let input = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-START:TIME-OFFSET=8,PRECISE=YES\n#EXTINF:4,\nsegments/0?mode=1\n#EXTINF:4,\nsegments/1?mode=1\n#EXTINF:1.5,\nsegments/2?mode=1\n#EXT-X-ENDLIST\n"
let manifest = try NeoHLSManifest(text: input, source: source)
precondition(manifest.duration == 9.5 && manifest.index(at: 7.9) == 1 && manifest.index(at: 8) == 2)
precondition(manifest.segments[0].url.path == "/root/api/streams/recorded/1/vodhls/segments/0")
let local = String(data: manifest.localPlaylist(route: "/secret"), encoding: .utf8)!
precondition(local.contains("/secret/segments/2.ts") && !local.contains("example.test") && local.contains("TIME-OFFSET=8"))
for invalid in [input.replacingOccurrences(of: "segments/0?mode=1", with: "https://other.test/video"),
  input.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""), input.replacingOccurrences(of: "#EXTM3U", with: "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128")] {
  precondition((try? NeoHLSManifest(text: invalid, source: source)) == nil)
}
precondition(NeoStreamBuffer.label(2, ts: false) == "8秒" && NeoStreamBuffer.label(2, ts: true) == "約12秒")
NeoStreamBuffer.save(3, ts: true, rewind: false)
precondition(NeoStreamBuffer.count(ts: true, rewind: false) == 3)
UserDefaults.standard.removeObject(forKey: NeoStreamBuffer.key(ts: true, rewind: false))
let config = try JSONDecoder().decode(NeoServerConfig.self, from: Data(#"{"encode":[],"streamConfig":{"recorded":{"ts":{"hls":["TS A","TS B"]},"encoded":{"hls":["Encoded A"]}}}}"#.utf8))
precondition(config.streamingQualities("ts") == ["TS A", "TS B"] && config.streamingQualities("encoded") == ["Encoded A"])
print("PASS: VOD timeline, safe segment routes, partial final segment, segment settings and quality config")

let transition = NeoStreamingClock()
transition.reset(at: 49000, host: 100)
precondition(transition.position(at: 50400, host: 100, running: true, rate: 1) == 49000)
precondition(transition.position(at: 49100, host: 100.1, running: true, rate: 1) == 49100)
precondition(transition.position(at: 48700, host: 100.2, running: true, rate: 1) == 49100)
transition.reset(at: 70000, host: 200)
precondition(transition.position(at: 64761, host: 200.03, running: true, rate: 1) == 70000)
precondition(transition.position(at: 71473, host: 200.05, running: false, rate: 1) == 70000)
precondition(transition.position(at: 70400, host: 200.4, running: true, rate: 1) == 70400)
precondition(transition.position(at: 72000, host: 202, running: true, rate: 1) == 72000)
transition.reset(at: 20000, host: 300)
precondition(transition.position(at: 20010, host: 300.1, running: false, rate: 1) == 20010)
precondition(transition.position(at: 99000, host: 306, running: true, rate: 1) == 99000)
print("PASS: PCR preroll, obsolete resume point, pause, explicit backward seek and bounded clock guard")

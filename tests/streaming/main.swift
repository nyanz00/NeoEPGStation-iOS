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

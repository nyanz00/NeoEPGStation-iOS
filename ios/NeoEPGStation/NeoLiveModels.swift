import Foundation

struct NeoLiveChannel: Codable, Equatable {
  let id: Int, name: String, channelType: String
  var serviceId: Int? = nil, type: Int? = nil, remoteControlKeyId: Int? = nil
  var hasLogoData: Bool? = nil
  var waveLabel: String { channelType.hasPrefix("GR-ALT") ? String(channelType.dropFirst(3)) : channelType }
  var defaultVisible: Bool {
    if let type, ![1,2,0xa1,0xa2,0xa5,0xa6,0xad].contains(type) { return false }
    let normalized = name.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:"[\\s　]+",with:"",options:.regularExpression).uppercased()
    return normalized.range(of:"^(NHK(DATA|データ)([0-9]|$)|707チャンネル$|放送大学ラジオ$|プレミアムナビ$|WOWOW.*(ご案内|案内チャンネル)|BS10(プレミアム)?(の)?ご案内|スカパー!?(ガイド|.*ご案内チャンネル))",options:.regularExpression) == nil
  }
}
struct NeoLiveProgram: Codable, Equatable {
  let id: Int, name: String, startAt: Double, endAt: Double
  var description: String? = nil, extended: String? = nil
  func progress(_ now: Double) -> Double { endAt > startAt ? min(1,max(0,(now-startAt)/(endAt-startAt))) : 0 }
}
struct NeoLiveSchedule: Codable, Equatable {
  let channel: NeoLiveChannel, programs: [NeoLiveProgram]
  var program: NeoLiveProgram? { programs.first }
  func context(base: URL) -> [String:Any] {
    var value: [String:Any] = ["live":true,"baseURL":base.absoluteString,"channelId":channel.id,
      "channelName":channel.name,"name":program?.name ?? channel.name,"videoFileType":"ts",
      "startAt":program?.startAt ?? 0,"endAt":program?.endAt ?? 0,"description":program?.description ?? "","extended":program?.extended ?? ""]
    if let program {
      value["startAt"] = program.startAt; value["endAt"] = program.endAt
      value["description"] = program.description ?? ""; value["extended"] = program.extended ?? ""
    }
    return value
  }
}
struct NeoLiveForce: Decodable { let channelId: Int; let force: Int? }
struct NeoLiveJikkyoInfo: Decodable {
  let watchSessionUrl: String?, commentSessionUrl: String?
}
struct NeoLiveOption: Equatable {
  let type: String, mode: Int, quality: String, unconverted: Bool
  var label: String { type == "m2tsll" ? "M2TS-LL" : "M2TS" }
  var dictionary: [String:Any] { ["type":type,"mode":mode,"quality":quality,"unconverted":unconverted] }
  static func available(_ config: NeoServerConfig) -> [NeoLiveOption] {
    guard config.isEnableTSLiveStream != false else { return [] }
    let ts = config.streamConfig?.live?.ts
    return (ts?.m2ts ?? []).enumerated().filter { !$0.element.name.isEmpty }.map {
      NeoLiveOption(type:"m2ts",mode:$0.offset,quality:$0.element.name,unconverted:$0.element.isUnconverted == true)
    } + (ts?.m2tsll ?? []).enumerated().filter { !$0.element.isEmpty }.map {
      NeoLiveOption(type:"m2tsll",mode:$0.offset,quality:$0.element,unconverted:false)
    }
  }
  func url(api: NeoAPI, channel: Int) -> URL {
    var parts = URLComponents(url:api.url("/streams/live/\(channel)/\(type)"),resolvingAgainstBaseURL:false)!
    parts.queryItems = [.init(name:"mode",value:String(mode)),.init(name:"quality",value:quality)]
    // Omitted overrides intentionally use the server's watch/config defaults.
    return parts.url!
  }
}

// Map a growing TS delivery clock onto VLC's input-relative playback clock.
// PCR is an existing timestamp, not a second decoder or pixel inspection.
final class NeoLivePCRClock {
  private var pending = Data(), first: Double?, previous: Double?, wraps = 0.0, pid: Int?
  private(set) var span = 0.0
  func reset() { pending.removeAll(); first = nil; previous = nil; wraps = 0; pid = nil; span = 0 }
  func observe(_ data: Data) {
    pending.append(data)
    var offset = 0
    while pending.count-offset >= 188 {
      if pending[offset] != 0x47 { offset += 1; continue }
      let adaptation = (pending[offset+3] >> 4) & 3
      let packetPID = Int(pending[offset+1] & 0x1f)*256+Int(pending[offset+2])
      if adaptation >= 2, pending[offset+4] >= 7, pending[offset+5] & 0x10 != 0, pid == nil || pid == packetPID {
        pid = packetPID
        let p = offset+6
        let ticks = UInt64(pending[p])<<25 | UInt64(pending[p+1])<<17 | UInt64(pending[p+2])<<9 | UInt64(pending[p+3])<<1 | UInt64(pending[p+4]>>7)
        let raw = Double(ticks)/90000
        if let previous, previous-raw > 40000 { wraps += 8589934592.0/90000 }
        previous = raw; let seconds = raw+wraps
        if first == nil { first = seconds }
        span = max(span,seconds-(first ?? seconds))
      }
      offset += 188
    }
    if offset > 0 { pending = Data(pending.dropFirst(offset)) }
  }
  func delay(playback: Double) -> Double { min(60,max(0,span-max(0,playback))) }
}

enum NeoLiveCommentCommand {
  static let colors = ["white":"#FFEAEA","red":"#F02840","pink":"#FD7E80","orange":"#FDA708","yellow":"#FFE133",
    "green":"#64DD17","cyan":"#00D4F5","blue":"#4763FF","purple":"#D500F9","black":"#1E1310",
    "white2":"#CCCC99","niconicowhite":"#CCCC99","red2":"#CC0033","truered":"#CC0033","pink2":"#FF33CC",
    "orange2":"#FF6600","passionorange":"#FF6600","yellow2":"#999900","madyellow":"#999900","green2":"#00CC66",
    "elementalgreen":"#00CC66","cyan2":"#00CCCC","blue2":"#3399FF","marineblue":"#3399FF","purple2":"#6633CC",
    "nobleviolet":"#6633CC","black2":"#666666"]
  static func row(_ chat: [String:Any], at time: Double) -> [String:Any]? {
    guard let text = chat["content"] as? String, !text.isEmpty, text.utf8.count <= 16384 else { return nil }
    if String(describing:chat["premium"] ?? "") == "3", text.range(of:"^/[a-z][a-z0-9_-]*(\\s|$)",options:[.regularExpression,.caseInsensitive]) != nil { return nil }
    var color = "#FFEAEA", position = "right", size = "medium"
    for value in (chat["mail"] as? String ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init) {
      if value.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil { color = value }
      else if let mapped = colors[value] { color = mapped }
      else if value == "ue" { position = "top" }
      else if value == "shita" { position = "bottom" }
      else if value == "naka" { position = "right" }
      else if ["big","small","medium"].contains(value) { size = value }
    }
    return ["time":max(0,time),"text":text,"color":color,"position":position,"size":size]
  }
}


import Foundation

func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
for count in 1...150 {
  for page in 1...count {
    let values = NeoPagination.mobile(page: page, count: count)
    expect(values.contains(page) && values.count == min(count, 5), "Mobile current page and count")
    expect(values.first! >= 1 && values.last! <= count, "No nonexistent page")
    expect(zip(values, values.dropFirst()).allSatisfy { $0.1 == $0.0 + 1 }, "Consecutive mobile pages")
    let desktop = NeoPagination.desktop(page: page, count: count, width: 720).compactMap { $0 }
    expect(desktop.first == 1 && desktop.last == count && desktop.contains(page), "Desktop endpoints and current page")
  }
}
expect(NeoPagination.mobile(page: 1, count: 10) == [1,2,3,4,5], "First page reference")
expect(NeoPagination.mobile(page: 7, count: 10) == [5,6,7,8,9], "Page seven reference")
expect(NeoPagination.mobile(page: 10, count: 10) == [6,7,8,9,10], "Last page")
let root = try NeoServerURL.normalize(" https://example.com/#/recorded ")
expect(root.absoluteString == "https://example.com", "SPA route removed")
expect(try NeoServerURL.normalize("https://example.com/epg/api/").absoluteString == "https://example.com/epg", "Reverse proxy path preserved")
for invalid in ["file:///tmp", "https://user:pass@example.com/", "https://example.com/?token=x", "https://example.com/#other", "not a url"] {
  do { _ = try NeoServerURL.normalize(invalid); fatalError("Accepted invalid URL") } catch {}
}
let start = 1791042600000.0 // 2026-10-04 00:50 JST
expect(NeoProgramText.interval(start: start, end: start + 1800000) == "10/04(日) 00:50 - 01:20 (30 m)", "Compact Web timestamp")
let decoded = try JSONDecoder().decode(NeoRecords.self, from: Data(#"{"total":1,"records":[{"id":1,"name":"Sample","startAt":1,"endAt":2,"isRecording":false,"videoFiles":[{"id":2,"name":"AV1","type":"encoded","size":352200000}]}]}"#.utf8))
expect(decoded.records[0].videoFiles?[0].id == 2, "PLAY file data decoded")
print("Native pagination, server URL, timestamp and recording model tests passed")

import Foundation

var assertionCount = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  assertionCount += 1
  if !condition() { fatalError("Date input test failed: \(message)") }
}

let formattingCases: [(String, String)] = [
  ("", ""),
  ("1", "1"),
  ("123", "123"),
  ("2024", "2024/"),
  ("20241", "2024/1"),
  ("202412", "2024/12/"),
  ("2024123", "2024/12/3"),
  ("20241231", "2024/12/31"),
  ("20241231999", "2024/12/31"),
  ("２０２４０２２９", "2024/02/29"),
  ("ab２０２４-０２-２９xy", "2024/02/29"),
  ("２０２４／０２／２９", "2024/02/29"),
  ("2024/1", "2024/1"),
]
for (input, expected) in formattingCases {
  expect(NeoDateInput.format(input) == expected, "format \(input) as \(expected)")
}

let displayCases: [(String, String)] = [
  ("2024-02-29", "2024/02/29"),
  ("0001-01-01", "0001/01/01"),
  ("9999-12-31", "9999/12/31"),
  ("2024/02/29", ""),
  ("2024-2-29", ""),
  ("", ""),
]
for (input, expected) in displayCases {
  expect(NeoDateInput.display(input) == expected, "display \(input) as \(expected)")
}

let editingCases: [(String, String, String)] = [
  ("2024/12/3", "2024/12/31", "2024/12/31"), // one-character insertion
  ("2024/02/29", "2024/02/2", "2024/02/2"), // shorter deletion is kept verbatim
  ("1", "", ""), // deletion to empty
  ("２０２４０２２９", "x２０２４０２２９", "2024/02/29"), // same-size replacement formats
]
for (previous, raw, expected) in editingCases {
  expect(NeoDateInput.editing(raw, previous: previous) == expected, "edit from \(previous) to \(raw)")
}

let parseCases: [(String, String?)] = [
  ("2024-02-29", "2024-02-29"),
  ("2024/02/29", "2024-02-29"),
  ("2024/02-29", "2024-02-29"), // Web regex accepts either separator at each position
  ("２０２４／０２／２９", "2024-02-29"),
  ("２０２４－０２－２９", "2024-02-29"),
  ("2000-02-29", "2000-02-29"),
  ("0001-01-01", "0001-01-01"),
  ("9999-12-31", "9999-12-31"),
  ("", nil),
  ("2024-02-2", nil),
  ("2024/2/29", nil),
  ("0000-01-01", nil),
  ("2024-00-10", nil),
  ("2024-13-10", nil),
  ("2024-01-00", nil),
  ("2024-01-32", nil),
  ("2024-02-30", nil),
  ("1900-02-29", nil),
  ("2100-02-29", nil),
  ("2023-02-29", nil),
  ("2024-04-31", nil),
  ("10000-01-01", nil),
  ("2024.02.29", nil),
  (" 2024-02-29", nil),
  ("2024-0a-29", nil),
]
for (input, expected) in parseCases {
  expect(NeoDateInput.parse(input) == expected, "parse \(input) as \(String(describing: expected))")
}

// Cover padded years, century boundaries and the supported range endpoints.
for year in [1, 99, 100, 400, 1582, 1900, 2000, 2026, 9999] {
  let unpaddedYear = String(year)
  let yearText = String(repeating: "0", count: 4 - unpaddedYear.count) + unpaddedYear
  let canonical = yearText + "-01-01"
  expect(NeoDateInput.parse(canonical) == canonical, "parse year \(yearText)")
  expect(NeoDateInput.format(yearText + "0101") == yearText + "/01/01", "format year \(yearText)")
  expect(NeoDateInput.display(canonical) == yearText + "/01/01", "display year \(yearText)")
}

print("Date input tests passed (\(assertionCount) assertions)")

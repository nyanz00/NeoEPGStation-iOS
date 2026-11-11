import Foundation

/// Web-parity formatting and parsing for recorded-search date text.
///
/// The canonical value is `YYYY-MM-DD`; the text shown to the user is
/// `YYYY/MM/DD`. Incomplete and invalid text is intentionally kept outside
/// this type's parsed value so a view can preserve it while the user edits.
enum NeoDateInput {
  /// Normalizes compatibility characters, keeps the first eight ASCII digits,
  /// and inserts `/` after the year and month as those digits are entered.
  static func format(_ input: String) -> String {
    let digits = asciiDigits(in: input).prefix(8)
    let text = String(digits)
    guard text.count >= 4 else { return text }
    if text.count == 4 { return text + "/" }
    if text.count < 6 { return String(text.prefix(4)) + "/" + String(text.dropFirst(4)) }
    if text.count == 6 { return String(text.prefix(4)) + "/" + String(text.suffix(2)) + "/" }
    return String(text.prefix(4)) + "/" + String(text.dropFirst(4).prefix(2)) + "/" + String(text.suffix(from: text.index(text.startIndex, offsetBy: 6)))
  }

  /// Parses a complete slash- or hyphen-separated date into `YYYY-MM-DD`.
  ///
  /// NFKC-compatible input such as full-width digits is accepted. The date
  /// must be a real proleptic Gregorian date in the year range 0001...9999;
  /// incomplete or invalid text returns `nil` so a caller can retain the raw
  /// editing text without sending an invalid filter value.
  static func parse(_ input: String) -> String? {
    let normalized = input.precomposedStringWithCompatibilityMapping
    let characters = Array(normalized)
    guard characters.count == 10,
          characters[4] == "/" || characters[4] == "-",
          characters[7] == "/" || characters[7] == "-" else { return nil }

    let yearText = String(characters[0..<4])
    let monthText = String(characters[5..<7])
    let dayText = String(characters[8..<10])
    guard yearText.unicodeScalars.allSatisfy(isASCIIDigit),
          monthText.unicodeScalars.allSatisfy(isASCIIDigit),
          dayText.unicodeScalars.allSatisfy(isASCIIDigit),
          let year = Int(yearText), let month = Int(monthText), let day = Int(dayText),
          year >= 1, month >= 1, month <= 12, day >= 1 else { return nil }

    let daysInMonth: Int
    switch month {
    case 2: daysInMonth = isLeapYear(year) ? 29 : 28
    case 4, 6, 9, 11: daysInMonth = 30
    default: daysInMonth = 31
    }
    guard day <= daysInMonth else { return nil }
    return yearText + "-" + monthText + "-" + dayText
  }

  /// Converts a canonical `YYYY-MM-DD` value to the slash-separated display
  /// form. As in the Web component, this checks the canonical shape only.
  static func display(_ canonicalValue: String) -> String {
    let characters = Array(canonicalValue)
    guard characters.count == 10,
          characters[4] == "-",
          String(characters[0..<4]).unicodeScalars.allSatisfy(isASCIIDigit),
          String(characters[5..<7]).unicodeScalars.allSatisfy(isASCIIDigit),
          String(characters[8..<10]).unicodeScalars.allSatisfy(isASCIIDigit) else { return "" }
    return String(characters[0..<4]) + "/" + String(characters[5..<7]) + "/" + String(characters[8..<10])
  }

  /// Applies the Web text-input edit rule: a shorter proposal is a deletion
  /// and is returned verbatim; otherwise format the inserted/replaced text.
  /// UTF-16 length matches JavaScript string-length behavior for this rule.
  static func editing(_ raw: String, previous: String) -> String {
    raw.utf16.count < previous.utf16.count ? raw : format(raw)
  }

  private static func asciiDigits(in input: String) -> String {
    String(String.UnicodeScalarView(input.precomposedStringWithCompatibilityMapping.unicodeScalars.filter(isASCIIDigit)))
  }

  private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 48 && scalar.value <= 57
  }

  private static func isLeapYear(_ year: Int) -> Bool {
    year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
  }
}

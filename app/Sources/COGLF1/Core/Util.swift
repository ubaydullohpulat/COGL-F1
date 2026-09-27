import Foundation
import Security

enum Keychain {
  private static let service = "com.cogl.f1"

  static func get(_ account: String) -> String? {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
    return String(data: d, encoding: .utf8)
  }

  static func set(_ account: String, _ value: String?) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    guard let value, !value.isEmpty else { return }
    var add = base
    add[kSecValueData as String] = Data(value.utf8)
    SecItemAdd(add as CFDictionary, nil)
  }
}

enum Fmt {
  static func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
  }

  static func duration(_ s: TimeInterval) -> String {
    if s < 1 { return String(format: "%.0f ms", s * 1000) }
    if s < 60 { return String(format: "%.1f s", s) }
    let m = Int(s) / 60, sec = Int(s) % 60
    return m < 60 ? "\(m)m \(sec)s" : "\(m / 60)h \(m % 60)m"
  }

  static func number(_ v: Double?, digits: Int = 3) -> String {
    guard let v, v.isFinite else { return "—" }
    let a = abs(v)
    if a != 0 && (a >= 1e6 || a < 1e-3) { return String(format: "%.\(digits)e", v) }
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = a >= 1000 ? 1 : digits
    f.minimumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
  }

  private static let isoFormatters: [DateFormatter] = {
    ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
     "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd"].map {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone(identifier: "UTC")
      f.dateFormat = $0
      return f
    }
  }()

  static func date(_ s: String) -> Date? {
    for f in isoFormatters { if let d = f.date(from: s) { return d } }
    return nil
  }

  /// "1 Mar 2025" for people, where shortDate is for tables.
  static func friendlyDate(_ s: String) -> String {
    guard let d = date(s) else { return s }
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
  }

  static func shortDate(_ s: String) -> String {
    guard let d = date(s) else { return s }
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    let hasTime = !s.hasSuffix("T00:00:00") && s.count > 10
    f.dateFormat = hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
    return f.string(from: d)
  }
}

/// Plain names for the pandas frequency codes the engine reports.
enum Freq {
  private static let bases: [(code: String, name: String, unit: String)] = [
    ("min", "Every minute", "minute"), ("T", "Every minute", "minute"), ("MS", "Monthly", "month"), ("ME", "Monthly", "month"),
    ("M", "Monthly", "month"), ("QS", "Quarterly", "quarter"), ("QE", "Quarterly", "quarter"), ("Q", "Quarterly", "quarter"),
    ("YS", "Yearly", "year"), ("YE", "Yearly", "year"), ("Y", "Yearly", "year"), ("D", "Daily", "day"),
    ("B", "Working days", "working day"), ("h", "Hourly", "hour"), ("H", "Hourly", "hour"), ("W", "Weekly", "week"),
    ("s", "Every second", "second"),
  ]

  private static func base(_ f: String?) -> (code: String, name: String, unit: String)? {
    guard let f else { return nil }
    return bases.first { f == $0.code || f.hasPrefix($0.code + "-") }
  }

  static func name(_ f: String) -> String { base(f)?.name ?? "Every \(f)" }

  /// "hours", "days"… or "steps" when the spacing has no everyday name.
  static func unit(_ f: String?, count: Int) -> String {
    guard let u = base(f)?.unit else { return count == 1 ? "step" : "steps" }
    return count == 1 ? u : u + "s"
  }

  static func presets(_ f: String?) -> [(title: String, steps: Int)] {
    switch base(f)?.unit {
    case "minute": return [("1 hour", 60), ("6 hours", 360), ("1 day", 1440)]
    case "hour": return [("1 day", 24), ("3 days", 72), ("1 week", 168)]
    case "day": return [("1 week", 7), ("1 month", 30), ("3 months", 90)]
    case "working day": return [("1 week", 5), ("1 month", 21), ("3 months", 63)]
    case "week": return [("1 month", 4), ("3 months", 13), ("1 year", 52)]
    case "month": return [("3 months", 3), ("6 months", 6), ("1 year", 12)]
    case "quarter": return [("1 year", 4), ("2 years", 8)]
    default: return []
    }
  }
}

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

  static func shortDate(_ s: String) -> String {
    guard let d = date(s) else { return s }
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    let hasTime = !s.hasSuffix("T00:00:00") && s.count > 10
    f.dateFormat = hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
    return f.string(from: d)
  }
}

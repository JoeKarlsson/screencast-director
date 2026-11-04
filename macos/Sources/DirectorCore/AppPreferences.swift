import Foundation
import Security

/// The app's settings and support folder, shared with the `director` CLI so an agent reads and
/// changes the same things the app's Settings window does. The app keeps its settings in its own
/// UserDefaults domain; the CLI reaches that domain by name. Tests point both at scratch copies with
/// `SD_DEFAULTS_DOMAIN` and `SD_SUPPORT_DIR`.
public enum AppPreferences {
  public static let appDomain = "com.joekarlsson.screencastdirector"

  public static var domain: String { ProcessInfo.processInfo.environment["SD_DEFAULTS_DOMAIN"] ?? appDomain }

  /// The app's settings. Inside the app that's `.standard` (a suite named after the running app's
  /// own bundle is refused).
  public static var defaults: UserDefaults {
    if Bundle.main.bundleIdentifier == domain { return .standard }
    guard let d = UserDefaults(suiteName: domain) else { fatalError("can't open the settings domain \(domain)") }
    return d
  }

  /// ~/Library/Application Support/Screencast Director: profiles, animations, sounds, music, effects.
  public static var supportFolder: URL {
    if let dir = ProcessInfo.processInfo.environment["SD_SUPPORT_DIR"] { return URL(fileURLWithPath: dir) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Screencast Director")
  }

  /// The Keychain service the app keeps API and S3 keys under.
  public static let keychainService = "com.joekarlsson.screencastdirector.ai"

  /// A key the app saved in the Keychain, or nil. (From the CLI, macOS asks once to allow it.)
  public static func keychainValue(_ account: String) -> String? {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

/// A setting `director settings` can read and change: the app's Settings window, minus API keys
/// (Keychain only) and per-session state (the window being recorded, library sort).
public struct AppSetting {
  public enum Kind {
    case bool, int(ClosedRange<Int>), number(ClosedRange<Double>), text, choice([String])
  }
  public let key: String
  public let kind: Kind
  public let defaultValue: String
  public let help: String

  public static let all: [AppSetting] = [
    AppSetting(key: "projectsFolder", kind: .text, defaultValue: "~/Movies/Screencast Director", help: "where recordings are saved"),
    AppSetting(key: "displayID", kind: .int(0...Int(Int32.max)), defaultValue: "0", help: "display to record (0 is the main one)"),
    AppSetting(key: "fps", kind: .int(1...120), defaultValue: "30", help: "recording frame rate"),
    AppSetting(key: "micID", kind: .text, defaultValue: "", help: "microphone device ID (empty: the system default)"),
    AppSetting(key: "cameraID", kind: .text, defaultValue: "", help: "camera device ID"),
    AppSetting(key: "useCamera", kind: .bool, defaultValue: "false", help: "record the camera too"),
    AppSetting(key: "countdown", kind: .int(0...10), defaultValue: "3", help: "seconds of 3-2-1 before recording"),
    AppSetting(key: "smoothCursor", kind: .bool, defaultValue: "true", help: "smooth the cursor's path"),
    AppSetting(key: "showSelfInRecordings", kind: .bool, defaultValue: "false", help: "record this app's own windows"),
    AppSetting(key: "showRecordingWidget", kind: .bool, defaultValue: "true", help: "floating widget while recording"),
    AppSetting(
      key: "pauseLevel", kind: .choice(PauseLevel.allCases.map(\.rawValue)), defaultValue: "normal", help: "how tightly new drafts cut pauses"),
    AppSetting(key: "polishVoice", kind: .bool, defaultValue: "false", help: "new drafts start with Normalize and Warm voice"),
    AppSetting(key: "autoName", kind: .bool, defaultValue: "true", help: "name new recordings from what's said"),
    AppSetting(key: "defaultProfile", kind: .text, defaultValue: "Personal", help: "profile new recordings get"),
    AppSetting(key: "previewVolume", kind: .number(0...1), defaultValue: "1", help: "editor preview volume"),
    AppSetting(key: "previewMuted", kind: .bool, defaultValue: "false", help: "mute the editor preview"),
    AppSetting(key: "ai.provider", kind: .choice(["claudeCode", "anthropic", "openAICompatible"]), defaultValue: "claudeCode", help: "who makes AI edits"),
    AppSetting(key: "ai.anthropicModel", kind: .text, defaultValue: "claude-opus-5-5", help: "model for the Anthropic API provider"),
    AppSetting(key: "ai.baseURL", kind: .text, defaultValue: "", help: "OpenAI-compatible endpoint"),
    AppSetting(key: "ai.model", kind: .text, defaultValue: "", help: "model for the OpenAI-compatible endpoint"),
    AppSetting(key: "ai.doubleCheck", kind: .bool, defaultValue: "true", help: "Claude checks its edit before finishing"),
    AppSetting(key: "s3Endpoint", kind: .text, defaultValue: "", help: "S3-compatible endpoint for Upload and Copy Link"),
    AppSetting(key: "s3Region", kind: .text, defaultValue: "us-east-1", help: "S3 region"),
    AppSetting(key: "s3Bucket", kind: .text, defaultValue: "", help: "S3 bucket"),
    AppSetting(key: "s3PublicBase", kind: .text, defaultValue: "", help: "public URL the bucket is served from"),
  ]

  public static func named(_ key: String) -> AppSetting? { all.first { $0.key == key } }

  /// The saved value as text, or the default when it was never set.
  public func value(in d: UserDefaults = AppPreferences.defaults) -> String {
    guard let v = d.object(forKey: key) else { return defaultValue }
    if case .bool = kind { return d.bool(forKey: key) ? "true" : "false" }
    return "\(v)"
  }

  /// Saves a value typed as the app reads it; throws on one the app wouldn't accept.
  public func set(_ text: String, in d: UserDefaults = AppPreferences.defaults) throws {
    func bad(_ want: String) -> DirectorError { DirectorError("\(key) takes \(want), not \"\(text)\"") }
    switch kind {
    case .bool:
      guard let b = ["true": true, "yes": true, "1": true, "false": false, "no": false, "0": false][text.lowercased()] else {
        throw bad("true or false")
      }
      d.set(b, forKey: key)
    case .int(let range):
      guard let n = Int(text), range.contains(n) else { throw bad("a whole number from \(range.lowerBound) to \(range.upperBound)") }
      d.set(n, forKey: key)
    case .number(let range):
      guard let n = Double(text), range.contains(n) else { throw bad("a number from \(range.lowerBound) to \(range.upperBound)") }
      d.set(Float(n), forKey: key)
    case .choice(let options):
      guard options.contains(text) else { throw bad("one of \(options.joined(separator: ", "))") }
      d.set(text, forKey: key)
    case .text:
      d.set(key == "projectsFolder" ? (text as NSString).expandingTildeInPath : text, forKey: key)
    }
  }
}

extension S3.Config {
  /// The bucket set up in the app's Settings > Sharing (keys from the Keychain), or nil until
  /// endpoint, bucket and both keys are filled in.
  public static func saved(_ d: UserDefaults = AppPreferences.defaults) -> S3.Config? {
    let endpoint = (d.string(forKey: "s3Endpoint") ?? "").trimmingCharacters(in: .whitespaces)
    let bucket = d.string(forKey: "s3Bucket") ?? ""
    guard let url = URL(string: endpoint), url.scheme != nil, !bucket.isEmpty,
      let access = AppPreferences.keychainValue("s3-access-key"), !access.isEmpty,
      let secret = AppPreferences.keychainValue("s3-secret-key"), !secret.isEmpty
    else { return nil }
    let region = d.string(forKey: "s3Region") ?? ""
    let base = d.string(forKey: "s3PublicBase") ?? ""
    return S3.Config(
      endpoint: url, region: region.isEmpty ? "us-east-1" : region, bucket: bucket, accessKey: access, secretKey: secret,
      publicBase: base.isEmpty ? nil : base)
  }
}

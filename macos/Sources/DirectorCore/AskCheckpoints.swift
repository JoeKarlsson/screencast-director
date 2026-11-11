import Foundation

/// The plan as it was before each AI ask, so the Claude box and `director asks` can rewind to it.
/// Kept as .history/asks/<ask id>.json, beside asks.json (the ask history the app saves: each ask's
/// `id`, `instruction` and, once rewound, `rewound: true`).
public enum AskCheckpoints {
  public static func asksURL(planURL: URL) -> URL { PlanHistory.directory(for: planURL).appendingPathComponent("asks.json") }

  static func url(_ id: UUID, planURL: URL) -> URL {
    PlanHistory.directory(for: planURL).appendingPathComponent("asks/\(id.uuidString).json")
  }

  /// Saves plan.json as it is now as ask `id`'s checkpoint.
  public static func save(planURL: URL, id: UUID) throws {
    let dest = url(id, planURL: planURL)
    try PathSafety.ownedFolder(".history/asks", in: planURL.deletingLastPathComponent())
    try Data(contentsOf: planURL).write(to: dest, options: .atomic)
  }

  public static func exists(before id: UUID, planURL: URL) -> Bool { FileManager.default.fileExists(atPath: url(id, planURL: planURL).path) }

  /// The plan before ask `id`.
  public static func plan(before id: UUID, planURL: URL) throws -> Plan { try Plan.load(url(id, planURL: planURL)) }

  /// Removes the checkpoints of asks no longer in the history.
  public static func prune(keeping ids: Set<UUID>, planURL: URL) throws {
    let dir = PlanHistory.directory(for: planURL).appendingPathComponent("asks")
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    try PathSafety.ownedFolder(".history/asks", in: planURL.deletingLastPathComponent())
    for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
      try FileManager.default.removeItem(at: file)
    }
  }

  /// The saved asks, oldest first, as asks.json has them.
  public static func asks(planURL: URL) throws -> [[String: Any]] {
    let url = asksURL(planURL: planURL)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] ?? []
  }

  /// Puts plan.json back to how it was before ask `n` (0 is the oldest) and marks that ask and the
  /// ones after it rewound, keeping asks.json's other keys. Returns the ask's instruction. The app
  /// does the same through its undo.
  @discardableResult
  public static func rewind(to n: Int, planURL: URL) throws -> String {
    var list = try asks(planURL: planURL)
    guard list.indices.contains(n) else { throw RewindError("there's no ask \(n + 1); there are \(list.count)") }
    guard let id = (list[n]["id"] as? String).flatMap(UUID.init(uuidString:)), exists(before: id, planURL: planURL)
    else { throw RewindError("ask \(n + 1) has no saved plan to go back to (it's from before rewinding existed)") }
    try plan(before: id, planURL: planURL).write(to: planURL)
    for i in n..<list.count { list[i]["rewound"] = true }
    try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
      .write(to: asksURL(planURL: planURL), options: .atomic)
    return list[n]["instruction"] as? String ?? ""
  }

  public struct RewindError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
  }
}

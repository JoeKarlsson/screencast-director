import Foundation

/// Openverse (openverse.org): openly licensed sound effects (mostly Freesound) and pictures
/// (Wikimedia, Flickr, museums...) searched through its public API, which needs no key (20 requests
/// a minute, 200 a day). Only licenses a video can use without asking are allowed: CC0 and the Public
/// Domain Mark need no credit; CC BY needs the attribution line in the video's description. NC, ND
/// and share-alike items are never offered.
public enum Openverse {
  public enum Media: String, Sendable {
    case sounds = "audio", images
  }

  /// One search result or downloaded item, as the API returns it.
  public struct Item: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var creator: String?
    public var license: String
    public var license_version: String?
    public var foreign_landing_url: String?
    public var url: String
    public var source: String?
    public var filetype: String?
    /// Milliseconds (sounds only).
    public var duration: Int?
    public var width: Int?
    public var height: Int?
    public var attribution: String?

    public var needsCredit: Bool { !Openverse.noCredit.contains(license) }

    /// The file type from the API, else from the URL.
    public var fileExtension: String {
      (filetype ?? (URL(string: url)?.pathExtension ?? "")).lowercased()
    }
  }

  static let noCredit: Set<String> = ["cc0", "pdm"]
  static let creditOK: Set<String> = ["by"]
  static let api = URL(string: "https://api.openverse.org/v1/")!
  /// Wikimedia refuses requests without a user agent.
  static let userAgent = "ScreencastDirector (macOS video editor)"

  /// The search request: credit-free licenses unless `allowCredit`, sounds under 30 s, 20 results
  /// (the most an anonymous request gets). `fileExtension` narrows pictures to one type ("gif").
  public static func searchURL(_ media: Media, query: String, allowCredit: Bool, fileExtension: String? = nil) -> URL {
    var c = URLComponents(url: api.appendingPathComponent("\(media.rawValue)/"), resolvingAgainstBaseURL: false)!
    let licenses = noCredit.union(allowCredit ? creditOK : []).sorted().joined(separator: ",")
    c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "license", value: licenses), URLQueryItem(name: "page_size", value: "20")]
    if media == .sounds { c.queryItems!.append(URLQueryItem(name: "length", value: "shortest")) }
    if let fileExtension { c.queryItems!.append(URLQueryItem(name: "extension", value: fileExtension)) }
    return c.url!
  }

  /// Results the app can use: sounds in a format the library plays, pictures B-roll can show.
  public static func search(_ media: Media, query: String, allowCredit: Bool, fileExtension: String? = nil) async throws -> [Item] {
    struct Page: Decodable { var results: [Item] }
    let url = searchURL(media, query: query, allowCredit: allowCredit, fileExtension: fileExtension)
    let page = try JSONDecoder().decode(Page.self, from: try await get(url))
    return page.results.filter { usable($0, media) }
  }

  /// One item by its id (from a search). Refuses a license a video can't use freely.
  public static func item(_ media: Media, id: String) async throws -> Item {
    guard UUID(uuidString: id) != nil else { throw DirectorError("\"\(id)\" isn't an Openverse id (they look like 130a70f2-4fa5-4600-8bca-eeec3c82edd3)") }
    let item = try JSONDecoder().decode(Item.self, from: try await get(api.appendingPathComponent("\(media.rawValue)/\(id)/")))
    guard noCredit.union(creditOK).contains(item.license) else {
      throw DirectorError("\(item.title ?? id) is licensed CC \(item.license.uppercased()), which a video can't use freely. Pick a CC0, public domain or CC BY one.")
    }
    guard usable(item, media) else { throw DirectorError("\(item.title ?? id) is a .\(item.fileExtension) file, which the app can't use") }
    return item
  }

  static func usable(_ item: Item, _ media: Media) -> Bool {
    (media == .sounds ? AudioLibrary.audioExtensions : Insert.imageExtensions).contains(item.fileExtension)
  }

  /// The file name to save it as: "Openverse - <title>" for a sound (" (CC BY)" flags one that needs
  /// credit), the title for a picture. Characters file names and plan paths can't hold become spaces.
  public static func fileName(_ item: Item, _ media: Media) -> String {
    let title = ((item.title ?? "") as NSString).deletingPathExtension
    var name = String(title.map { "/:?\\\"*<>|".contains($0) || $0.isNewline ? " " : $0 })
      .split(separator: " ").joined(separator: " ")
    name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
    if name.isEmpty { name = String(item.id.prefix(8)) }
    if media == .sounds {
      name = "Openverse - \(name)"
      if item.needsCredit { name += " (CC BY)" }
    }
    return "\(name).\(item.fileExtension)"
  }

  /// Downloads a sound into My Sounds' Openverse folder, so the picker lists it and a plan can name
  /// it as `sfx/<file>`. The library names sounds by file alone, so a name another sound has gets
  /// the id added; an id already downloaded is reused. Records its license next to it. Returns the
  /// plan path.
  public static func addSound(_ item: Item, library: AudioLibrary = AudioLibrary(.sounds, allowsWork: true)) async throws -> String {
    let folder = library.personal.appendingPathComponent("Openverse")
    if let file = recorded(item.id, in: folder), FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
      return "sfx/\(file)"
    }
    var name = fileName(item, .sounds)
    if try library.items().contains(where: { $0.item.file == name }) {
      name = "\((name as NSString).deletingPathExtension) \(item.id.prefix(8)).\(item.fileExtension)"
    }
    let data = try await get(URL(string: item.url)!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent(name))
    try record(item, file: name, in: folder)
    return "sfx/\(name)"
  }

  /// Downloads a picture into the project's broll/ folder and records its license there. Returns
  /// the plan path.
  public static func addImage(_ item: Item, project dir: URL) async throws -> String {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = temp.appendingPathComponent(fileName(item, .images))
    try await get(URL(string: item.url)!).write(to: file)
    let path = try Project.importFile(file, into: "broll", dir: dir)
    try record(item, file: (path as NSString).lastPathComponent, in: dir.appendingPathComponent("broll"))
    return path
  }

  static let licenseFile = "openverse-licenses.csv"
  static let licenseHeader = "file,id,title,creator,license,source page,attribution,downloaded\n"

  /// One quoted CSV row.
  static func csvRow(_ fields: [String]) -> String {
    fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
  }

  /// Appends the item's license to the folder's openverse-licenses.csv: the proof for a claim, and
  /// the credit line for a CC BY one.
  static func record(_ item: Item, file: String, in folder: URL) throws {
    let csv = folder.appendingPathComponent(licenseFile)
    let license = [item.license.uppercased(), item.license_version].compactMap { $0 }.joined(separator: " ")
    let row = csvRow([file, item.id, item.title ?? "", item.creator ?? "", license, item.foreign_landing_url ?? "", item.attribution ?? "",
                      ISO8601DateFormatter().string(from: Date())])
    if let h = FileHandle(forWritingAtPath: csv.path) {
      defer { try? h.close() }
      try h.seekToEnd()
      try h.write(contentsOf: Data(row.utf8))
    } else {
      try (licenseHeader + row).write(to: csv, atomically: true, encoding: .utf8)
    }
  }

  /// The file already downloaded for this id, from the folder's license record (file and id are
  /// the first two fields, neither of which can hold a quote).
  static func recorded(_ id: String, in folder: URL, file: String = licenseFile) -> String? {
    guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: "\"", omittingEmptySubsequences: false)
      if fields.count > 3, fields[3] == id { return String(fields[1]) }
    }
    return nil
  }

  static func get(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 429 { throw DirectorError("Openverse allows 20 requests a minute and 200 a day without an account; wait and try again") }
    guard (200..<300).contains(status) else {
      // The API explains a bad request in JSON `detail`; a gateway error is an HTML page, so just the status.
      let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"].map { ": \($0)" } ?? ""
      throw DirectorError("\(url.host ?? "the server") answered \(status) for \(url.absoluteString)\(detail)\(status >= 500 ? " (their side; try again in a minute)" : "")")
    }
    return data
  }
}

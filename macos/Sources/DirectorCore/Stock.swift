import Foundation

/// Video B-roll and GIFs from free stock libraries, downloaded into a project's broll/ as MP4s
/// (GIFs and WebM/Ogg clips are converted, since B-roll plays through AVFoundation), each logged with
/// its license in broll/stock-licenses.csv.
///
/// Video: Pexels (Pexels License, no credit; needs a free key), NASA (public domain), Wikimedia
/// Commons (CC0 and public domain; CC BY with `allowCredit`; never share-alike or NC) and the
/// Internet Archive's Prelinger collection (public domain vintage film; other Archive uploads
/// declare their own licenses, which are often wrong).
/// GIFs: Openverse (CC0 and public domain, as for pictures) everywhere, plus KLIPY (reaction GIFs,
/// mostly clips from TV and film, so personal videos only; needs a free key). GIPHY is left out:
/// its API terms forbid keeping copies of its GIFs.
public enum Stock {
  public enum Source: String, CaseIterable, Sendable {
    case pexels, nasa, commons, archive, klipy, openverse
  }

  public static let videoSources: [Source] = [.pexels, .nasa, .commons, .archive]

  /// The GIF libraries a video may use: no KLIPY in a work video.
  public static func gifSources(work: Bool) -> [Source] { work ? [.openverse] : [.klipy, .openverse] }

  /// One search result: `id` is "<source>:<the library's id>", which `get-video`/`get-gif` take.
  public struct Item: Equatable, Sendable {
    public var id: String
    public var title: String
    public var creator: String
    public var license: String
    public var needsCredit: Bool
    /// The item's page on its library, kept in the license record.
    public var page: String
    /// The file to download, when the search already knows it (NASA and the Archive look it up on download).
    public var file: String?
    public var width: Int?
    public var height: Int?
    public var seconds: Double?

    public var source: Source? { Source(rawValue: String(id.prefix { $0 != ":" })) }
    public var sourceID: String { String(id.drop { $0 != ":" }.dropFirst()) }
  }

  // MARK: keys

  /// A library's API key: the environment variable, else the Keychain item the app's other keys
  /// live under (`security add-generic-password -s com.joekarlsson.screencastdirector.ai -a pexels-api-key -w <key>`).
  public static func key(_ source: Source, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard let name = keyName(source) else { return nil }
    if let k = env["\(name.uppercased())_API_KEY"], !k.isEmpty { return k }
    return AppPreferences.keychainValue("\(name)-api-key").flatMap { $0.isEmpty ? nil : $0 }
  }

  static func keyName(_ source: Source) -> String? {
    switch source {
    case .pexels: "pexels"
    case .klipy: "klipy"
    default: nil
    }
  }

  static func missingKey(_ source: Source) -> DirectorError {
    let name = keyName(source) ?? source.rawValue
    let signup = source == .pexels ? "https://www.pexels.com/api/" : "https://partner.klipy.com/api-keys"
    return DirectorError(
      "\(source.rawValue) needs a free API key (\(signup)): set \(name.uppercased())_API_KEY, or save it in the Keychain with `security add-generic-password -s \(AppPreferences.keychainService) -a \(name)-api-key -w <key>`")
  }

  // MARK: search

  /// Searches each source in turn. A source that fails (no key, a network error) doesn't stop the
  /// rest: its error comes back in `problems`, one line per source.
  public static func search(_ sources: [Source], query: String, allowCredit: Bool) async -> (items: [Item], problems: [String]) {
    var items: [Item] = [], problems: [String] = []
    for source in sources {
      do {
        items += try await search(source, query: query, allowCredit: allowCredit)
      } catch {
        problems.append("\(source.rawValue): \(error.localizedDescription)")
      }
    }
    return (items, problems)
  }

  static func search(_ source: Source, query: String, allowCredit: Bool) async throws -> [Item] {
    switch source {
    case .pexels:
      guard let key = key(.pexels) else { throw missingKey(.pexels) }
      return try pexelsItems(await get(pexelsSearchURL(query), headers: ["Authorization": key]))
    case .nasa:
      return try nasaItems(await get(nasaSearchURL(query)))
    case .commons:
      return try commonsItems(await get(commonsSearchURL(query)), allowCredit: allowCredit)
    case .archive:
      return try archiveItems(await get(archiveSearchURL(query)))
    case .klipy:
      guard let key = key(.klipy) else { throw missingKey(.klipy) }
      return try klipyItems(await get(klipySearchURL(query, key: key)))
    case .openverse:
      return try await Openverse.search(.images, query: query, allowCredit: allowCredit, fileExtension: "gif").map(openverseItem)
    }
  }

  /// One item by its id, looked up again so a download never trusts a stale or made-up id.
  public static func item(_ id: String, allowCredit: Bool = true) async throws -> Item {
    let probe = Item(id: id, title: "", creator: "", license: "", needsCredit: false, page: "")
    guard let source = probe.source, !probe.sourceID.isEmpty else {
      throw DirectorError("\"\(id)\" isn't a stock id; they look like pexels:857195 or klipy:hello-hi-662, as `director stock` lists them")
    }
    let sid = probe.sourceID
    let enc = sid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sid
    let found: [Item]
    switch source {
    case .pexels:
      guard let key = key(.pexels) else { throw missingKey(.pexels) }
      found = try pexelsItems(await get(URL(string: "https://api.pexels.com/videos/videos/\(enc)")!, headers: ["Authorization": key]), single: true)
    case .nasa:
      var c = URLComponents(string: "https://images-api.nasa.gov/search")!
      c.queryItems = [URLQueryItem(name: "nasa_id", value: sid), URLQueryItem(name: "media_type", value: "video")]
      found = try nasaItems(await get(c.url!))
    case .commons:
      var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
      c.queryItems = commonsInfoQuery + [URLQueryItem(name: "titles", value: sid)]
      found = try commonsItems(await get(c.url!), allowCredit: allowCredit)
    case .archive:
      var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
      c.queryItems = archiveQuery("identifier:\"\(sid)\"")
      found = try archiveItems(await get(c.url!))
    case .klipy:
      guard let key = key(.klipy) else { throw missingKey(.klipy) }
      var c = URLComponents(string: "https://api.klipy.com/api/v1/\(key)/gifs/items")!
      c.queryItems = [URLQueryItem(name: "slugs", value: sid)]
      found = try klipyItems(await get(c.url!))
    case .openverse:
      found = [openverseItem(try await Openverse.item(.images, id: sid))]
    }
    guard let item = found.first(where: { $0.id == id }) ?? (found.count == 1 ? found.first : nil) else {
      throw DirectorError("\(source.rawValue) has no usable item \(sid) (gone, or under a license a video can't use freely)")
    }
    return item
  }

  // MARK: Pexels

  static func pexelsSearchURL(_ query: String) -> URL {
    var c = URLComponents(string: "https://api.pexels.com/videos/search")!
    c.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "per_page", value: "15")]
    return c.url!
  }

  /// A search page (`videos`), or one video when `single`.
  static func pexelsItems(_ data: Data, single: Bool = false) throws -> [Item] {
    struct File: Decodable { var file_type: String?; var width: Int?; var height: Int?; var link: String }
    struct User: Decodable { var name: String? }
    struct Video: Decodable { var id: Int; var url: String; var duration: Double?; var user: User?; var video_files: [File] }
    struct Page: Decodable { var videos: [Video] }
    let videos = single ? [try JSONDecoder().decode(Video.self, from: data)] : try JSONDecoder().decode(Page.self, from: data).videos
    return videos.compactMap { v in
      // The sharpest MP4 up to 4K (Pexels also offers 8K-wide files no export needs).
      guard let best = v.video_files.filter({ $0.file_type == "video/mp4" && ($0.width ?? 0) <= 3840 }).max(by: { ($0.width ?? 0) < ($1.width ?? 0) })
      else { return nil }
      // The page URL ends in a slug of the title: .../video/a-person-typing-on-a-laptop-857195/
      let slug = URL(string: v.url)?.lastPathComponent ?? ""
      let title = slug.split(separator: "-").dropLast().joined(separator: " ")
      return Item(
        id: "pexels:\(v.id)", title: title.isEmpty ? "Pexels \(v.id)" : title, creator: v.user?.name ?? "", license: "Pexels License",
        needsCredit: false, page: v.url, file: best.link, width: best.width, height: best.height, seconds: v.duration)
    }
  }

  // MARK: NASA

  static func nasaSearchURL(_ query: String) -> URL {
    var c = URLComponents(string: "https://images-api.nasa.gov/search")!
    c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "media_type", value: "video"), URLQueryItem(name: "page_size", value: "15")]
    return c.url!
  }

  /// NASA's own media is public domain. Footage credited to someone else (a launch provider's
  /// camera) can carry its own rights, so it's flagged to check and credit.
  static func nasaItems(_ data: Data) throws -> [Item] {
    struct Meta: Decodable { var nasa_id: String; var title: String?; var photographer: String?; var secondary_creator: String?; var center: String? }
    struct Entry: Decodable { var data: [Meta] }
    struct Collection: Decodable { var items: [Entry] }
    struct Root: Decodable { var collection: Collection }
    return try JSONDecoder().decode(Root.self, from: data).collection.items.compactMap { e in
      guard let m = e.data.first else { return nil }
      let credited = m.photographer ?? m.secondary_creator
      let ownMedia = credited.map { $0.localizedCaseInsensitiveContains("NASA") } ?? true
      let creator = credited ?? m.center.map { "NASA \($0)" } ?? "NASA"
      let page = "https://images.nasa.gov/details/\(m.nasa_id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.nasa_id)"
      return Item(
        id: "nasa:\(m.nasa_id)", title: m.title ?? m.nasa_id, creator: creator,
        license: ownMedia ? "NASA (public domain)" : "NASA library, filmed by \(creator): check its rights", needsCredit: !ownMedia, page: page)
    }
  }

  /// The MP4 to download from a NASA asset list: the large rendition (1080p or so), else the original, else any MP4.
  static func nasaFile(_ data: Data) throws -> String? {
    struct Href: Decodable { var href: String }
    struct Collection: Decodable { var items: [Href] }
    struct Root: Decodable { var collection: Collection }
    // The asset list gives http:// links, which the same host serves over https.
    let mp4s = try JSONDecoder().decode(Root.self, from: data).collection.items.map { $0.href.replacingOccurrences(of: "http://", with: "https://") }
      .filter { $0.lowercased().hasSuffix(".mp4") }
    for suffix in ["~large.mp4", "~orig.mp4", "~medium.mp4"] {
      if let f = mp4s.first(where: { $0.hasSuffix(suffix) }) { return f }
    }
    return mp4s.first
  }

  // MARK: Wikimedia Commons

  static let commonsInfoQuery = [
    URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "prop", value: "imageinfo"),
    URLQueryItem(name: "iiprop", value: "url|size|mime|extmetadata"), URLQueryItem(name: "iiextmetadatafilter", value: "License|LicenseShortName|Artist"),
  ]

  static func commonsSearchURL(_ query: String) -> URL {
    var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
    c.queryItems =
      commonsInfoQuery + [
        URLQueryItem(name: "generator", value: "search"), URLQueryItem(name: "gsrsearch", value: "filetype:video \(query)"),
        URLQueryItem(name: "gsrnamespace", value: "6"), URLQueryItem(name: "gsrlimit", value: "30"),
      ]
    return c.url!
  }

  /// Longer than this, a Commons video is a lecture or a documentary, not B-roll.
  static let commonsLongest = 300.0

  /// The license a Commons file's `License` code allows: nil for share-alike, NC, ND and anything
  /// unknown; CC BY only with `allowCredit`.
  static func commonsLicense(_ code: String, allowCredit: Bool) -> (name: String, credit: Bool)? {
    let c = code.lowercased()
    if c == "cc0" { return ("CC0", false) }
    if c == "pd" || c.hasPrefix("pd-") || c.hasPrefix("pdm") { return ("Public domain", false) }
    if allowCredit, c.hasPrefix("cc-by-"), !c.contains("sa"), !c.contains("nc"), !c.contains("nd") {
      return ("CC BY \(c.dropFirst("cc-by-".count))", true)
    }
    return nil
  }

  static func commonsItems(_ data: Data, allowCredit: Bool) throws -> [Item] {
    struct Value: Decodable { var value: String }
    struct Info: Decodable {
      var url: String; var descriptionurl: String; var width: Int?; var height: Int?; var duration: Double?
      var extmetadata: [String: Value]?
    }
    struct Page: Decodable { var title: String; var index: Int?; var imageinfo: [Info]? }
    struct Query: Decodable { var pages: [String: Page] }
    struct Root: Decodable { var query: Query? }
    let pages = (try JSONDecoder().decode(Root.self, from: data).query?.pages.values).map(Array.init) ?? []
    return pages.sorted { ($0.index ?? 0) < ($1.index ?? 0) }.compactMap { p in
      guard let info = p.imageinfo?.first, (info.duration ?? 0) <= commonsLongest,
        let license = commonsLicense(info.extmetadata?["License"]?.value ?? "", allowCredit: allowCredit)
      else { return nil }
      let name = String(p.title.dropFirst("File:".count))
      return Item(
        id: "commons:\(p.title)", title: (name as NSString).deletingPathExtension, creator: plainText(info.extmetadata?["Artist"]?.value ?? ""),
        license: license.name, needsCredit: license.credit, page: info.descriptionurl, file: info.url, width: info.width, height: info.height,
        seconds: info.duration)
    }
  }

  /// HTML (a Commons artist field) as plain text.
  static func plainText(_ html: String) -> String {
    let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let decoded = stripped.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  // MARK: Internet Archive (Prelinger)

  static func archiveQuery(_ q: String) -> [URLQueryItem] {
    [URLQueryItem(name: "q", value: "(\(q)) AND collection:prelinger AND mediatype:movies")]
      + ["identifier", "title", "creator", "licenseurl"].map { URLQueryItem(name: "fl[]", value: $0) }
      + [URLQueryItem(name: "rows", value: "15"), URLQueryItem(name: "output", value: "json")]
  }

  static func archiveSearchURL(_ query: String) -> URL {
    var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
    c.queryItems = archiveQuery(query)
    return c.url!
  }

  /// Prelinger films are public domain; one marked otherwise is left out.
  static func archiveItems(_ data: Data) throws -> [Item] {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let docs = (root?["response"] as? [String: Any])?["docs"] as? [[String: Any]] ?? []
    return docs.compactMap { d in
      guard let id = d["identifier"] as? String else { return nil }
      if let license = d["licenseurl"] as? String, !license.contains("publicdomain") { return nil }
      // creator is a string, or a list when there are several.
      let creator = (d["creator"] as? String) ?? (d["creator"] as? [String])?.joined(separator: ", ") ?? "Prelinger Archives"
      return Item(id: "archive:\(id)", title: d["title"] as? String ?? id, creator: creator, license: "Public domain", needsCredit: false,
                  page: "https://archive.org/details/\(id)")
    }
  }

  /// The MP4 to download from an Archive item's file list: the best H.264 derivative.
  static func archiveFile(_ data: Data, identifier: String) throws -> String? {
    struct File: Decodable { var name: String; var format: String? }
    struct Root: Decodable { var files: [File]? }
    let files = try JSONDecoder().decode(Root.self, from: data).files ?? []
    for format in ["h.264 HD", "h.264", "MPEG4", "512Kb MPEG4"] {
      if let f = files.first(where: { $0.format == format && $0.name.lowercased().hasSuffix(".mp4") }) {
        return "https://archive.org/download/\(identifier)/\(f.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.name)"
      }
    }
    return nil
  }

  // MARK: KLIPY

  /// A fixed customer id: the API wants one per user for its recents, which the CLI doesn't use.
  static func klipySearchURL(_ query: String, key: String) -> URL {
    var c = URLComponents(string: "https://api.klipy.com/api/v1/\(key)/gifs/search")!
    c.queryItems = [
      URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: "15"), URLQueryItem(name: "page", value: "1"),
      URLQueryItem(name: "customer_id", value: "screencast-director"), URLQueryItem(name: "content_filter", value: "medium"),
    ]
    return c.url!
  }

  /// Search and items answers: `data.data` is the list (`data` alone in some answers).
  static func klipyItems(_ data: Data) throws -> [Item] {
    struct Rendition: Decodable { var url: String; var width: Int?; var height: Int? }
    struct Size: Decodable { var mp4: Rendition?; var gif: Rendition? }
    struct Gif: Decodable { var slug: String; var title: String?; var file: [String: Size]? }
    struct Inner: Decodable { var data: [Gif] }
    enum Body: Decodable {
      case list([Gif])
      case page(Inner)
      init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let list = try? c.decode([Gif].self) { self = .list(list) } else { self = .page(try c.decode(Inner.self)) }
      }
      var gifs: [Gif] {
        switch self {
        case .list(let g): g
        case .page(let p): p.data
        }
      }
    }
    struct Root: Decodable { var result: Bool?; var data: Body?; var errors: [String: [String]]? }
    let root = try JSONDecoder().decode(Root.self, from: data)
    if root.result == false { throw DirectorError("KLIPY: \(root.errors?.values.flatMap { $0 }.joined(separator: " ") ?? "the request failed")") }
    return (root.data?.gifs ?? []).compactMap { g in
      // The MP4 when there is one (smaller, smoother), else the GIF; the biggest size offered.
      let sizes = ["hd", "md", "sm"].compactMap { g.file?[$0] }
      guard let pick = sizes.lazy.compactMap({ $0.mp4 ?? $0.gif }).first else { return nil }
      return Item(
        id: "klipy:\(g.slug)", title: g.title ?? g.slug, creator: "KLIPY", license: "KLIPY (personal videos only)", needsCredit: false,
        page: "https://klipy.com/gifs/\(g.slug)", file: pick.url, width: pick.width, height: pick.height)
    }
  }

  // MARK: Openverse GIFs

  static func openverseItem(_ o: Openverse.Item) -> Item {
    Item(
      id: "openverse:\(o.id)", title: ((o.title ?? "") as NSString).deletingPathExtension, creator: o.creator ?? "",
      license: ([o.license.uppercased()] + [o.license_version].compactMap { $0 }).joined(separator: " "), needsCredit: o.needsCredit,
      page: o.foreign_landing_url ?? o.url, file: o.url, width: o.width, height: o.height)
  }

  // MARK: download

  /// A GIF loops for this long, since a B-roll clip shorter than its slot holds its last frame (and
  /// a one-frame GIF would be too short to show at all).
  static let gifLongest = 30.0

  /// Downloads an item into the project's broll/ as an MP4 and records its license. A GIF is
  /// refused in a work video when it comes from KLIPY. An id already downloaded is reused.
  /// Returns the plan path.
  public static func add(_ item: Item, project dir: URL, work: Bool, log: (String) -> Void = { _ in }) async throws -> String {
    if work, item.source == .klipy {
      throw DirectorError("KLIPY GIFs are mostly clips from TV and film, so work videos don't use them; pick an openverse: GIF instead")
    }
    let broll = dir.appendingPathComponent("broll")
    if let file = Openverse.recorded(item.id, in: broll, file: licenseFile), FileManager.default.fileExists(atPath: broll.appendingPathComponent(file).path) {
      return "broll/\(file)"
    }
    guard let url = try await downloadURL(item).flatMap(URL.init(string:)) else {
      throw DirectorError("\(item.id) has no MP4 to download")
    }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let ext = url.pathExtension.lowercased()
    let raw = temp.appendingPathComponent("download.\(ext.isEmpty ? "bin" : ext)")
    log("Downloading \(item.title)...")
    try await download(url, to: raw)
    let out = temp.appendingPathComponent("\(fileName(item.title, fallback: item.sourceID)).mp4")
    // KLIPY's reactions come as MP4s but are GIFs all the same: they loop too.
    let isGIF = ext == "gif" || item.source == .klipy
    if ["mp4", "m4v", "mov"].contains(ext) && !isGIF {
      try FileManager.default.moveItem(at: raw, to: out)
    } else {
      log(isGIF ? "Converting the GIF to a looping MP4..." : "Converting the .\(ext) to MP4...")
      try convertToMP4(raw, to: out, loop: isGIF)
    }
    let path = try Project.importFile(out, into: "broll", dir: dir)
    try record(item, file: (path as NSString).lastPathComponent, in: broll)
    return path
  }

  /// The file URL: from the search, or for NASA and the Archive from the item's file list.
  static func downloadURL(_ item: Item) async throws -> String? {
    if let f = item.file { return f }
    let sid = item.sourceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.sourceID
    switch item.source {
    case .nasa: return try nasaFile(await get(URL(string: "https://images-api.nasa.gov/asset/\(sid)")!))
    case .archive: return try archiveFile(await get(URL(string: "https://archive.org/metadata/\(sid)")!), identifier: item.sourceID)
    default: return nil
    }
  }

  /// A title as a file name: characters paths can't hold become spaces, at most 80 characters.
  static func fileName(_ title: String, fallback: String) -> String {
    let name = String(String(title.map { "/:?\\\"*<>|".contains($0) || $0.isNewline ? " " : $0 }).split(separator: " ").joined(separator: " ").prefix(80))
      .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? String(fallback.prefix(40)) : name
  }

  /// ffmpeg's arguments for an H.264 MP4 B-roll can play: even dimensions, no sound, and a GIF
  /// looped for `gifLongest` seconds.
  static func ffmpegArguments(_ input: URL, _ output: URL, loop: Bool) -> [String] {
    (loop ? ["-stream_loop", "-1"] : []) + ["-y", "-v", "error", "-i", input.path]
      + (loop ? ["-t", "\(Int(gifLongest))"] : [])
      + ["-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-movflags", "+faststart", output.path]
  }

  static func convertToMP4(_ input: URL, to output: URL, loop: Bool) throws {
    guard let ffmpeg = Tools.ffmpeg else { throw DirectorError("converting \(input.pathExtension) to MP4 needs ffmpeg (brew install ffmpeg)") }
    let proc = Process()
    proc.executableURL = ffmpeg
    proc.arguments = ffmpegArguments(input, output, loop: loop)
    let err = Pipe()
    proc.standardError = err
    proc.standardOutput = FileHandle.nullDevice
    try proc.run()
    let message = err.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      throw DirectorError("ffmpeg couldn't convert \(input.lastPathComponent): \(String(decoding: message.suffix(400), as: UTF8.self))")
    }
  }

  static let licenseFile = "stock-licenses.csv"

  /// Appends the item's license to broll/stock-licenses.csv (the same columns as Openverse's record).
  static func record(_ item: Item, file: String, in folder: URL) throws {
    let csv = folder.appendingPathComponent(licenseFile)
    let row = Openverse.csvRow([
      file, item.id, item.title, item.creator, item.license, item.page, item.needsCredit ? "\(item.title) by \(item.creator), \(item.license)" : "",
      ISO8601DateFormatter().string(from: Date()),
    ])
    if let h = FileHandle(forWritingAtPath: csv.path) {
      defer { try? h.close() }
      try h.seekToEnd()
      try h.write(contentsOf: Data(row.utf8))
    } else {
      try (Openverse.licenseHeader + row).write(to: csv, atomically: true, encoding: .utf8)
    }
  }

  // MARK: HTTP

  static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue(Openverse.userAgent, forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    let (data, response) = try await withoutURL(url) { try await URLSession.shared.data(for: request) }
    try check(response, url: url, body: data)
    return data
  }

  /// Streams a (possibly large) file to disk instead of memory.
  static func download(_ url: URL, to file: URL) async throws {
    var request = URLRequest(url: url)
    request.setValue(Openverse.userAgent, forHTTPHeaderField: "User-Agent")
    let (temp, response) = try await withoutURL(url) { try await URLSession.shared.download(for: request) }
    try check(response, url: url, body: nil)
    try FileManager.default.moveItem(at: temp, to: file)
  }

  /// A network error names the host only: URLError carries the whole URL, and KLIPY's has the key in it.
  static func withoutURL<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let e as URLError {
      throw DirectorError("couldn't reach \(url.host ?? "the server"): \(e.code == .notConnectedToInternet ? "no internet connection" : "network error \(e.code.rawValue)")")
    }
  }

  static func check(_ response: URLResponse, url: URL, body: Data?) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard !(200..<300).contains(status) else { return }
    // Never echo a URL that carries a key (KLIPY puts it in the path).
    let host = url.host ?? "the server"
    if status == 401 || status == 403 { throw DirectorError("\(host) refused the request (\(status)); check the API key") }
    if status == 429 { throw DirectorError("\(host) is rate limiting (429); wait a while and try again") }
    let detail = body.flatMap { String(data: $0.prefix(200), encoding: .utf8) }.map { ": \($0)" } ?? ""
    throw DirectorError("\(host) answered \(status)\(detail)")
  }
}

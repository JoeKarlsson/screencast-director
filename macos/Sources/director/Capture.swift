import AppKit
import DirectorCore
import WebKit

/// `director capture`: opens a website in an offscreen WKWebView and keeps what an animation can use:
/// its logo (an inline SVG or image in the header, else its touch icon) saved to the video's
/// `animations/logos/` under a name templates can use, and a screenshot of the page in `broll/`.
enum Capture {
  /// Finds logo candidates, best first: inline SVGs and images marked as a logo or sitting in the
  /// header, then the touch icon and favicons, then the share image. Returns {title, theme, logos}.
  static let probe = """
    (() => {
      const abs = u => { try { return new URL(u, location.href).href; } catch (e) { return null; } };
      const words = e => [e.id, typeof e.className === "string" ? e.className : (e.className && e.className.baseVal) || "",
        e.getAttribute("alt"), e.getAttribute("aria-label"), e.getAttribute("src"), e.getAttribute("title")].join(" ");
      const logos = [];
      for (const e of document.querySelectorAll("svg, img")) {
        const r = e.getBoundingClientRect();
        if (r.width < 16 || r.height < 8 || r.top > 400) continue;
        const named = /logo|brand/i.test(words(e)) || !!e.closest("[class*=logo i], [id*=logo i], [aria-label*=logo i]");
        const home = !!e.closest("a[href='/'], a[href='" + location.origin + "/'], header, nav");
        if (!named && !home) continue;
        const score = (named ? 4 : 0) + (home ? 2 : 0) - r.top / 400;
        if (e.tagName.toLowerCase() === "svg") {
          const svg = e.cloneNode(true);
          svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
          // currentColor and CSS-set fills would turn black once the SVG stands alone.
          svg.setAttribute("style", `color: ${getComputedStyle(e).color}`);
          if (!svg.getAttribute("viewBox")) svg.setAttribute("viewBox", `0 0 ${r.width} ${r.height}`);
          logos.push({ svg: svg.outerHTML, score });
        } else if (e.currentSrc || e.src) {
          logos.push({ url: abs(e.currentSrc || e.src), score });
        }
      }
      for (const l of document.querySelectorAll("link[rel~=apple-touch-icon], link[rel~=icon]")) {
        const size = parseInt((l.getAttribute("sizes") || "0").split("x")[0]) || 0;
        logos.push({ url: abs(l.href), score: (/apple/.test(l.rel) ? 1 : 0) + size / 1000 - 1 });
      }
      const og = document.querySelector("meta[property='og:image']");
      if (og) logos.push({ url: abs(og.content), score: -3 });
      logos.sort((a, b) => b.score - a.score);
      const theme = document.querySelector("meta[name=theme-color]");
      return JSON.stringify({ title: document.title, theme: theme ? theme.content : null, logos: logos.filter(l => l.svg || l.url) });
    })()
    """

  struct Found: Decodable {
    struct Logo: Decodable { let svg: String?, url: String?, score: Double }
    let title: String
    let theme: String?
    let logos: [Logo]
  }

  /// "stripe.com" → "Stripe", for the logo's name when none is given.
  static func name(for url: URL) -> String {
    let host = (url.host ?? url.deletingPathExtension().lastPathComponent).replacingOccurrences(of: "www.", with: "")
    let first = host.split(separator: ".").first.map(String.init) ?? host
    return first.prefix(1).uppercased() + first.dropFirst()
  }

  @MainActor
  static func run(_ dir: URL, url: URL, name: String?, log: (String) -> Void) async throws {
    let page = Animate.Page(width: 1440, height: 900)
    try await page.open(url)
    // Let late scripts and fonts settle before reading the page.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    guard let json = try await page.web.evaluateJavaScript(probe) as? String else { throw DirectorError("couldn't read \(url.absoluteString)") }
    let found = try JSONDecoder().decode(Found.self, from: Data(json.utf8))
    let logoName = name ?? Capture.name(for: url)
    let slug = logoName.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)

    let logosDir = AnimationSources.videoFolder(dir).appendingPathComponent("logos")
    try FileManager.default.createDirectory(at: logosDir, withIntermediateDirectories: true)
    var saved: String?
    for logo in found.logos {
      if let svg = logo.svg {
        saved = "\(slug).svg"
        try Data(svg.utf8).write(to: logosDir.appendingPathComponent(saved!))
        break
      }
      guard let src = logo.url.flatMap(URL.init(string:)), let (data, response) = try? await URLSession.shared.data(from: src), !data.isEmpty,
        (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true, NSImage(data: data) != nil || src.pathExtension == "svg"
      else { continue }
      let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased()
      saved = "\(slug).\(ext)"
      try data.write(to: logosDir.appendingPathComponent(saved!))
      break
    }
    if let saved {
      let map = logosDir.appendingPathComponent("logos.json")
      var names = FileManager.default.fileExists(atPath: map.path) ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: map)) : [:]
      names[logoName] = saved
      let enc = JSONEncoder()
      enc.outputFormatting = [.prettyPrinted, .sortedKeys]
      try enc.encode(names).write(to: map)
      log("logo \"\(logoName)\": animations/logos/\(saved) (use \"\(logoName)\" as a logo in an animation's data)")
    } else {
      log("no logo found on \(url.absoluteString)")
    }

    let broll = dir.appendingPathComponent("broll")
    try FileManager.default.createDirectory(at: broll, withIntermediateDirectories: true)
    let shot = broll.appendingPathComponent("\(slug)-site.png")
    try Publish.writePNG(try await page.snapshot(), to: shot)
    log("screenshot: broll/\(shot.lastPathComponent)")
    if let theme = found.theme { log("theme color: \(theme)") }
  }
}

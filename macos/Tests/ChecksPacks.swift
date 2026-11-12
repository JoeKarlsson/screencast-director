import Foundation

// Packs (install, conflicts, refusals, remove, export), animation themes (lookup, freeze, digest)
// and mark sets. Called from Checks.main; run with macos/test.sh.

func packChecks() {
  let fm = FileManager.default
  let tmp = fm.temporaryDirectory.appendingPathComponent("sd-packs-\(UUID().uuidString)")
  defer { try? fm.removeItem(at: tmp) }
  func write(_ text: String, _ rel: String, in dir: URL) {
    let url = dir.appendingPathComponent(rel)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }
  func read(_ rel: String, in dir: URL) -> String? { try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) }
  func throwsMessage(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch { return error.localizedDescription }
  }

  // A pack with a profile (its font beside it), a theme, an effect and a README.
  let pack = tmp.appendingPathComponent("My Look")
  write(##"{"name": "My Look", "version": "1.0"}"##, "pack.json", in: pack)
  write("read me", "README.md", in: pack)
  let style = ##""style": {"background": ["#000000"], "padding": 0, "radius": 4, "transition": 0.8}"##
  write(##"{"name": "Mine", \##(style), "look": {"fontFiles": ["fonts/A.ttf"], "animationTheme": "mine"}}"##, "Profiles/Mine/profile.json", in: pack)
  write("font", "Profiles/Mine/fonts/A.ttf", in: pack)
  write(##"{"title": "Mine", "css": "theme.css", "scripts": ["theme.js"], "marks": "marks.json", "coverMarks": true}"##, "Animations/themes/mine/theme.json", in: pack)
  write("html.theme-mine { --paper: #000; }", "Animations/themes/mine/theme.css", in: pack)
  write("THEMES.mine = {};", "Animations/themes/mine/theme.js", in: pack)
  write(##"{"oval": {"viewBox": "0 0 10 10", "path": "M0,0 L10,10"}}"##, "Animations/themes/mine/marks.json", in: pack)
  write("ignored", ".git/HEAD", in: pack)

  let support = tmp.appendingPathComponent("support")
  try? fm.createDirectory(at: support, withIntermediateDirectories: true)
  let (manifest, plan) = (try? Packs.install(pack, into: support)) ?? (Packs.Manifest(name: "?"), Packs.Plan())
  expect(manifest.name == "My Look" && plan.new.count == 6 && plan.conflicts.isEmpty, "a pack installs its files (\(plan))")
  expect(read("Profiles/Mine/fonts/A.ttf", in: support) == "font" && read("README.md", in: support) == nil && read(".git/HEAD", in: support) == nil,
    "into the support folder, without its README or dot files")
  expect(Packs.installed(in: support).map(\.name) == ["My Look"], "and is listed as installed")
  expect(ProfileLibrary(root: support.appendingPathComponent("Profiles")).names().contains("Mine"), "its profile shows up")

  // Installing again changes nothing; a changed file is a conflict until replace.
  let again = try? Packs.install(pack, into: support)
  expect(again?.1.same.count == 6 && again?.1.new.isEmpty == true, "the same pack again skips its identical files")
  write("my edit", "Animations/themes/mine/theme.css", in: support)
  let conflict = throwsMessage { try Packs.install(pack, into: support) }
  expect(conflict?.contains("Animations/themes/mine/theme.css") == true && read("Animations/themes/mine/theme.css", in: support) == "my edit",
    "a file that differs stops the install, named, and stays as it was (\(conflict ?? "no error"))")
  _ = try? Packs.install(pack, into: support, replace: true)
  expect(read("Animations/themes/mine/theme.css", in: support) == "html.theme-mine { --paper: #000; }", "replace overwrites it")

  // Refused: a symlink, something unknown at the top, no pack.json.
  let linked = tmp.appendingPathComponent("linked")
  write(##"{"name": "Linked"}"##, "pack.json", in: linked)
  try? fm.createDirectory(at: linked.appendingPathComponent("Music"), withIntermediateDirectories: true)
  try? fm.createSymbolicLink(at: linked.appendingPathComponent("Music/secret.m4a"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
  expect(throwsMessage { try Packs.install(linked, into: support) }?.contains("symlink") == true, "a pack with a symlink is refused")
  let odd = tmp.appendingPathComponent("odd")
  write(##"{"name": "Odd"}"##, "pack.json", in: odd)
  write("x", "Library/evil.plist", in: odd)
  expect(throwsMessage { try Packs.install(odd, into: support) }?.contains("Library") == true, "a pack with an unknown top folder is refused")
  expect(read("Library/evil.plist", in: support) == nil, "and copies nothing")
  let bare = tmp.appendingPathComponent("bare")
  write("x", "Music/a.m4a", in: bare)
  expect(throwsMessage { try Packs.install(bare, into: support) }?.contains("pack.json") == true, "a folder with no pack.json isn't a pack")

  // A zip whose listing leaves the pack is refused before anything unpacks.
  let slip = tmp.appendingPathComponent("slip")
  write("x", "inner/evil.txt", in: slip)
  let slipZip = tmp.appendingPathComponent("slip.sdpack")
  let zip = Process()
  zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
  zip.currentDirectoryURL = slip.appendingPathComponent("inner")
  zip.arguments = ["-q", slipZip.path, "../inner/evil.txt"]
  try? zip.run()
  zip.waitUntilExit()
  expect(throwsMessage { try Packs.install(slipZip, into: support) }?.contains("leaves the pack") == true, "a zip with a ../ path is refused")

  // Themes: found in the support folder, frozen into a video, hashed the same before and after.
  let project = tmp.appendingPathComponent("video")
  try? fm.createDirectory(at: project, withIntermediateDirectories: true)
  let themes = ThemeSources(project: project, personal: support.appendingPathComponent("Animations/themes"))
  expect(themes.available().map(\.name) == ["", "terminal", "mine"], "the theme list is paper, terminal, then installed ones (\(themes.available().map(\.name)))")
  let before = themes.digest("mine")
  expect(!before.isEmpty && themes.digest("terminal").isEmpty && themes.digest(nil).isEmpty, "a pack theme has a digest; built-in ones don't")
  expect((try? themes.freeze("mine")) == true && read("animations/themes/mine/theme.js", in: project) == "THEMES.mine = {};", "a theme freezes into the video")
  expect(themes.digest("mine") == before, "with the same digest as the library's")
  write("THEMES.mine = { tick() {} };", "Animations/themes/mine/theme.js", in: support)
  expect(themes.digest("mine") == before && (try? themes.load("mine"))?.scripts.first?.source == "THEMES.mine = {};",
    "a library change after that doesn't touch the video's copy")
  expect((try? themes.load("terminal")) == nil, "a built-in theme has nothing to load")
  expect(throwsMessage { _ = try themes.load("gone") }?.contains("isn't installed") == true, "a theme that isn't anywhere says so")
  expect((try? themes.marks(for: "gone")) == .builtIn, "and native drawing uses the app's marks for it")
  write(##"{"title": "Escape", "css": "../../../../secret.css"}"##, "Animations/themes/escape/theme.json", in: support)
  expect(throwsMessage { _ = try themes.load("escape") }?.contains("isn't a file") == true, "a theme file outside its folder is refused")
  let linkedTheme = tmp.appendingPathComponent("video2")
  try? fm.createDirectory(at: linkedTheme.appendingPathComponent("animations"), withIntermediateDirectories: true)
  try? fm.createSymbolicLink(at: linkedTheme.appendingPathComponent("animations/themes"), withDestinationURL: tmp)
  expect(throwsMessage { _ = try ThemeSources(project: linkedTheme, personal: support.appendingPathComponent("Animations/themes")).freeze("mine") }?.contains("symlink") == true,
    "freezing never writes through a symlinked themes folder")

  // Marks: a theme's replace the app's by name; the rest stay the app's; bad ones are named.
  let marks = (try? themes.marks(for: "mine")) ?? .builtIn
  expect(marks["oval"].size == CGSize(width: 10, height: 10) && marks["coil"].strokes == MarkSet.builtIn["coil"].strokes, "a theme's oval replaces the app's, the coil stays")
  expect(MarkSet.builtIn["burstDense"].strokes == MarkSet.builtIn["burst"].strokes, "burstDense (frozen templates' name) is the burst")
  expect(marks.json["oval"]?["viewBox"] == "0 0 10 10" && marks.json["burstDense"] != nil, "the page gets every mark, burstDense included")
  for name in ["oval", "burst", "coil", "rays", "underline", "asterisk"] {
    let s = MarkSet.builtIn[name], xs = s.strokes.flatMap { $0 }.map(\.x), ys = s.strokes.flatMap { $0 }.map(\.y)
    expect(!s.strokes.isEmpty && (xs.min() ?? -1) >= -2 && (xs.max() ?? .infinity) <= s.size.width + 2 && (ys.min() ?? -1) >= -2 && (ys.max() ?? .infinity) <= s.size.height + 2,
      "the app's \(name) parses and stays in its box")
  }
  write(##"{"oval": {"viewBox": "0 0 0 10", "path": "M0,0 L1,1"}}"##, "bad/marks.json", in: tmp)
  expect(throwsMessage { _ = try MarkSet.load(tmp.appendingPathComponent("bad/marks.json")) }?.contains("\"oval\"") == true, "a bad mark is named")

  // Remove takes away what it installed, except files changed since.
  write("changed by me", "Profiles/Mine/fonts/A.ttf", in: support)
  let kept = (try? Packs.remove("My Look", from: support)) ?? []
  let removedTheme = read("Animations/themes/mine/theme.css", in: support) == nil
  expect(kept == ["Animations/themes/mine/theme.js", "Profiles/Mine/fonts/A.ttf"] && removedTheme && Packs.installed(in: support).isEmpty,
    "removing a pack deletes its files, keeps ones you changed (\(kept))")

  // Export: a profile whose files live elsewhere comes out with them beside it, and installs.
  write(##"{"name": "Here", \##(style), "look": {"fontFiles": ["fonts/B.ttf"]}}"##, "Profiles/Here/profile.json", in: support)
  write("font", "Profiles/Here/fonts/B.ttf", in: support)
  let herePack = tmp.appendingPathComponent("Here Pack")
  _ = try? Packs.export(profiles: ["Here"], work: false, to: herePack, from: support)
  let here = try? JSONDecoder().decode(Profile.self, from: Data(contentsOf: herePack.appendingPathComponent("Profiles/Here/profile.json")))
  expect(here?.look.fontFiles == ["fonts/B.ttf"] && read("Profiles/Here/profile.json", in: herePack) == read("Profiles/Here/profile.json", in: support) && (try? fm.contentsOfDirectory(atPath: herePack.appendingPathComponent("Profiles/Here/fonts").path)) == ["B.ttf"],
    "a profile whose files are already beside it exports as it is, nothing copied twice (\(here?.look.fontFiles ?? []))")
  let elsewhere = tmp.appendingPathComponent("elsewhere")
  write("lut", "grade.cube", in: elsewhere)
  write(##"{"name": "Away", \##(style), "look": {}, "camera": {"grade": {"lut": "\##(elsewhere.path)/grade.cube"}}}"##,
    "Profiles/Away/profile.json", in: support)
  let out = tmp.appendingPathComponent("Away Pack.sdpack")
  let exported = throwsMessage { try Packs.export(profiles: ["Away"], work: false, to: out, from: support) }
  expect(exported == nil && fm.fileExists(atPath: out.path), "a profile exports to a .sdpack (\(exported ?? ""))")
  let fresh = tmp.appendingPathComponent("fresh")
  try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
  let installedAway = try? Packs.install(out, into: fresh)
  let away = try? Profile.load(fresh.appendingPathComponent("Profiles/Away"))
  expect(installedAway?.0.name == "Away Pack" && away?.camera?.grade?.lut == fresh.appendingPathComponent("Profiles/Away/luts/grade.cube").path
    && read("Profiles/Away/luts/grade.cube", in: fresh) == "lut", "and installs on another Mac with its LUT beside it (\(away?.camera?.grade?.lut ?? "none"))")
}

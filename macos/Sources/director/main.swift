import CoreImage
import DirectorCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// director: headless commands on a project folder. The app bundles it so Claude can run `describe`.
//
//   director analyze  <dir>                transcript.json + motion.json
//   director plan     <dir> [--force]      first-draft plan.json
//   director describe <dir>                the plan as a readable timeline
//   director render   <dir> [out.mp4]      export (default <dir>/out.mp4)
//   director still    <dir> <frame> <png> [--preset id]  one output frame, for checking an edit
//   director profile  <dir> <profileDir>   apply a profile (look + style) to the plan
//   director render   <dir> [out.mp4] [--preset id]   presets: youtube-4k youtube-1080 vertical square feed

let usage = """
  usage:
    director analyze  <dir>
    director plan     <dir> [--force]
    director describe <dir>
    director render   <dir> [out.mp4]
    director still    <dir> <frame> <out.png> [--preset id]
    director profile  <dir> <profileDir>
    director publish  <dir> [--title "..."] [--preset id]   captions.srt, chapters, transcript, thumbnails
    presets: \(ExportPreset.all.map(\.id).joined(separator: " "))
  """

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data((msg + "\n").utf8))
  exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail(usage) }
let dir = URL(fileURLWithPath: args[1]).standardizedFileURL

/// The plan, reshaped by --preset if given (the saved plan is untouched).
func planFor(_ project: Project) throws -> Plan {
  let plan = try Plan.load(project.planURL)
  guard let i = args.firstIndex(of: "--preset") else { return plan }
  guard i + 1 < args.count, let preset = ExportPreset.all.first(where: { $0.id == args[i + 1] }) else { fail(usage) }
  return preset.applied(to: plan)
}
let flags: Set<String> = ["--preset", "--title"]
let positional = args.enumerated().filter { i, a in !flags.contains(a) && (i == 0 || !flags.contains(args[i - 1])) }.map(\.element)

func stillFrame(_ project: Project, _ plan: Plan, frame: Int, to out: URL) async throws {
  let built = try await buildComposition(project: project, plan: plan)
  let image = try await stillImage(built, frame: frame)
  guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("can't write \(out.path)")
  }
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
}

do {
  switch args[0] {
  case "analyze":
    try await analyze(dir) { print($0) }
    print("Analysis done: transcript.json, motion.json")
  case "plan":
    let project = try Project.load(dir)
    if FileManager.default.fileExists(atPath: project.planURL.path), args.dropFirst(2).first != "--force" {
      fail("\(project.planURL.path) exists (it may hold edits). Pass --force to regenerate it.")
    }
    let plan = buildPlan(project)
    try plan.write(to: project.planURL)
    print("wrote \(project.planURL.path): \(plan.segments.count) segments, \(plan.zooms.count) zooms")
  case "debug":
    let project = try Project.load(dir)
    let built = try await buildComposition(project: project, plan: try Plan.load(project.planURL))
    print("asset duration", built.asset.duration.seconds, "frames", built.scene.frameCount)
    for t in built.asset.tracks { print(t.trackID, t.mediaType.rawValue, t.timeRange.start.seconds, t.timeRange.duration.seconds, t.segments.count) }
    for i in built.videoComposition.instructions { print("instr", i.timeRange.start.seconds, i.timeRange.duration.seconds) }
  case "describe":
    let project = try Project.load(dir)
    print(describe(project, try Plan.load(project.planURL)))
  case "render":
    let project = try Project.load(dir)
    let out = positional.count > 2 ? URL(fileURLWithPath: positional[2]) : dir.appendingPathComponent("out.mp4")
    let built = try await buildComposition(project: project, plan: try planFor(project))
    let started = Date()
    try await export(built, to: out) { p in
      FileHandle.standardError.write(Data("\(Int(p * 100))%\n".utf8))
    }
    print(String(format: "Rendered %@ in %.1fs", out.path, Date().timeIntervalSince(started)))
  case "still":
    guard positional.count == 4, let frame = Int(positional[2]) else { fail(usage) }
    let project = try Project.load(dir)
    try await stillFrame(project, try planFor(project), frame: frame, to: URL(fileURLWithPath: positional[3]))
    print(positional[3])
  case "publish":
    let project = try Project.load(dir)
    let title = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? dir.lastPathComponent
    let files = try await Publish.run(project: project, plan: try planFor(project), title: title) { print($0) }
    files.forEach { print("wrote \($0.path)") }
  case "profile":
    guard positional.count == 3 else { fail(usage) }
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    let profile = try Profile.load(URL(fileURLWithPath: positional[2]))
    profile.apply(to: &plan)
    try plan.write(to: project.planURL)
    print("applied profile \(profile.name)")
  default:
    fail(usage)
  }
} catch {
  fail("director: \(error.localizedDescription)\n\(error)")
}

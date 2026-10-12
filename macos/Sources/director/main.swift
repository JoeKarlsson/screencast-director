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
//   director still    <dir> <frame> <png>  one output frame, for checking an edit

let usage = """
  usage:
    director analyze  <dir>
    director plan     <dir> [--force]
    director describe <dir>
    director render   <dir> [out.mp4]
    director still    <dir> <frame> <out.png>
  """

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data((msg + "\n").utf8))
  exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail(usage) }
let dir = URL(fileURLWithPath: args[1]).standardizedFileURL

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
    let out = args.count > 2 ? URL(fileURLWithPath: args[2]) : dir.appendingPathComponent("out.mp4")
    let built = try await buildComposition(project: project, plan: try Plan.load(project.planURL))
    let started = Date()
    try await export(built, to: out) { p in
      FileHandle.standardError.write(Data("\(Int(p * 100))%\n".utf8))
    }
    print(String(format: "Rendered %@ in %.1fs", out.path, Date().timeIntervalSince(started)))
  case "still":
    guard args.count == 4, let frame = Int(args[2]) else { fail(usage) }
    let project = try Project.load(dir)
    try await stillFrame(project, try Plan.load(project.planURL), frame: frame, to: URL(fileURLWithPath: args[3]))
    print(args[3])
  default:
    fail(usage)
  }
} catch {
  fail("director: \(error.localizedDescription)\n\(error)")
}

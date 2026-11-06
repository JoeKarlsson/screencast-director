import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Everything for posting a video: captions (SRT), chapters, an output-timed transcript for
/// writing a description, and thumbnails.
public enum Publish: Sendable {
  /// Writes publish/captions.srt, publish/chapters.txt (when titles allow), publish/transcript.txt and
  /// publish/thumbnail-N.png. Returns the files written.
  /// `coverAt`: source seconds to make the covers from, instead of the best-scoring faces.
  public static func run(project: Project, plan: Plan, title: String, coverAt: [Double]? = nil, log: (String) -> Void = { _ in }) async throws -> [URL] {
    let out = project.dir.appendingPathComponent("publish")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let scene = Scene(plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)
    var files: [URL] = []

    let srtURL = out.appendingPathComponent("captions.srt")
    try srt(scene).write(to: srtURL, atomically: true, encoding: .utf8)
    files.append(srtURL)
    let tURL = out.appendingPathComponent("transcript.txt")
    try timedTranscript(scene).write(to: tURL, atomically: true, encoding: .utf8)
    files.append(tURL)
    if let ch = chapters(scene) {
      let u = out.appendingPathComponent("chapters.txt")
      try ch.write(to: u, atomically: true, encoding: .utf8)
      files.append(u)
    }

    log("Finding your best camera frames…")
    // Moments picked on the command line, else the ones saved in the plan, else the best faces.
    let faces = try await bestFaces(project: project, plan: plan, at: coverAt ?? plan.coverAt)
    let built = try await buildComposition(project: project, plan: plan)
    // One thumbnail per good face (vertical covers for a vertical video, the title beside the face
    // otherwise); without a camera, one per title moment (or the middle) over the screen.
    if !faces.isEmpty {
      let vertical = plan.output.height > plan.output.width
      for (i, f) in faces.enumerated() {
        log("Composing \(vertical ? "cover" : "thumbnail") \(i + 1) of \(faces.count)…")
        // Graded like the video's camera, so a halftone room has the same light behind it.
        let person = gradedLikeVideo(f.image, scene: built.scene)
        let made = vertical
          ? verticalThumbnail(plan: plan, person: person, faceX: f.faceX, title: title)
          : landscapeThumbnail(plan: plan, person: person, faceX: f.faceX, title: title)
        guard let thumb = made else { continue }
        let u = out.appendingPathComponent("thumbnail-\(i + 1).png")
        try writePNG(thumb, to: u)
        files.append(u)
      }
      return files
    }
    var moments: [(Double, CGImage?)] = faces.map { ($0.sourceTime, $0.image) }
    if moments.isEmpty {
      let titled = plan.callouts.map { $0.start + 0.5 }
      moments = (titled.isEmpty ? [plan.segments[plan.segments.count / 2].start] : Array(titled.prefix(3))).map { ($0, nil) }
    }
    let srcAsset = AVURLAsset(url: project.dir.appendingPathComponent(plan.source.video))
    let srcGen = AVAssetImageGenerator(asset: srcAsset)
    srcGen.maximumSize = CGSize(width: 1920, height: 1920)
    for (i, m) in moments.enumerated() {
      log("Composing thumbnail \(i + 1) of \(moments.count)…")
      guard let screen = try? await srcGen.image(at: CMTime(seconds: m.0, preferredTimescale: 600)).image,
        let thumb = thumbnail(scene: built.scene, screen: screen, person: m.1, title: title)
      else { continue }
      let u = out.appendingPathComponent("thumbnail-\(i + 1).png")
      try writePNG(thumb, to: u)
      files.append(u)
    }
    return files
  }
}

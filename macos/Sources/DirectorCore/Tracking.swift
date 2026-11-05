import AVFoundation
import Foundation
import Vision

/// Things Vision finds on the camera (the face, each hand, the person, a salient object such as
/// something held up), for effects that outline and label them. Found once per camera file at
/// `step` seconds apart and kept in `tracking.json` next to it.
public struct Tracking: Equatable, Sendable {
  public enum Kind: Int, Sendable {
    case face = 1, hand = 2, person = 3, object = 4
    /// On the screen layer: the pointer and recent clicks.
    case pointer = 10, click = 11
  }

  /// One found thing: `id` is the same for the same thing from sample to sample (kind × 10 + which
  /// one), the box is 0..1 of the camera frame with y down, `confidence` is Vision's 0..1.
  public struct Box: Equatable, Sendable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var confidence: Double
    public var kind: Int { id / 10 }
  }
  public struct Sample: Equatable, Sendable {
    public var t: Double
    public var boxes: [Box]
  }

  public static let fileName = "tracking.json"
  public static let step = 0.1
  /// Changing what's tracked changes this, so older files are found again.
  static let version = 2

  /// Samples in camera seconds, in order.
  public var samples: [Sample]

  /// The boxes at camera time `t`, each moved linearly between the samples around it. A box in
  /// only one of the two samples shows only within half a step of that sample, so it doesn't
  /// slide in from nowhere.
  public func boxes(at t: Double) -> [Box] {
    guard let first = samples.first, let last = samples.last, t >= first.t - Tracking.step, t <= last.t + Tracking.step else { return [] }
    var lo = 0, hi = samples.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
    }
    let a = samples[lo]
    guard lo + 1 < samples.count, t > a.t else { return a.boxes }
    let b = samples[lo + 1]
    let k = (t - a.t) / max(1e-6, b.t - a.t)
    func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * k }
    let later = Dictionary(b.boxes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    var out: [Box] = []
    var seen = Set<Int>()
    for p in a.boxes {
      seen.insert(p.id)
      if let q = later[p.id] {
        out.append(Box(id: p.id, x: mix(p.x, q.x), y: mix(p.y, q.y), w: mix(p.w, q.w), h: mix(p.h, q.h), confidence: mix(p.confidence, q.confidence)))
      } else if k < 0.5 {
        out.append(p)
      }
    }
    if k >= 0.5 { out += b.boxes.filter { !seen.contains($0.id) } }
    return out.sorted { $0.id < $1.id }
  }

  /// The camera's tracking, read from `tracking.json` or found and saved there when it's missing,
  /// older than the camera file, or from an older version.
  public static func camera(_ project: Project, video: String) async throws -> Tracking {
    let src = project.dir.appendingPathComponent(video)
    let out = project.dir.appendingPathComponent(fileName)
    if let saved = try? read(out, video: video), let a = modified(out), let b = modified(src), a >= b { return saved }
    FileHandle.standardError.write(Data("Tracking the camera for effects (once per recording)...\n".utf8))
    let tracking = try await find(in: src)
    try write(tracking, video: video, to: out)
    return tracking
  }

  private static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  /// Runs Vision on frames `step` seconds apart.
  static func find(in url: URL) async throws -> Tracking {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw DirectorError("\(url.lastPathComponent) has no video to track.")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    var samples: [Sample] = []
    var next = 0.0
    while let buf = output.copyNextSampleBuffer() {
      let t = CMSampleBufferGetPresentationTimeStamp(buf).seconds
      guard t >= next - 0.002, let px = CMSampleBufferGetImageBuffer(buf) else { continue }
      next = t + step
      let faces = VNDetectFaceRectanglesRequest()
      let hands = VNDetectHumanHandPoseRequest()
      hands.maximumHandCount = 2
      let people = VNDetectHumanRectanglesRequest()
      people.upperBodyOnly = true
      let salient = VNGenerateObjectnessBasedSaliencyImageRequest()
      try VNImageRequestHandler(cvPixelBuffer: px).perform([faces, hands, people, salient])
      samples.append(
        Sample(
          t: t,
          boxes: boxes(
            faces: faces.results ?? [], hands: hands.results ?? [], people: people.results ?? [],
            salient: salient.results?.first?.salientObjects ?? [])))
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return Tracking(samples: samples)
  }

  /// Vision's normalized rect (y up) as a box (y down).
  static func box(_ id: Int, _ r: CGRect, _ confidence: Float) -> Box {
    Box(id: id, x: Double(r.minX), y: 1 - Double(r.maxY), w: Double(r.width), h: Double(r.height), confidence: Double(confidence))
  }

  /// The boxes of one frame: the biggest face, up to two hands (around their joints, with a margin),
  /// the biggest person, and up to two salient objects in a hand (something held up to the camera)
  /// that aren't the face. Salient things away from the hands are mostly the room behind.
  static func boxes(
    faces: [VNFaceObservation], hands: [VNHumanHandPoseObservation], people: [VNHumanObservation], salient: [VNRectangleObservation]
  ) -> [Box] {
    var out: [Box] = []
    let face = faces.max { $0.boundingBox.width < $1.boundingBox.width }
    if let face { out.append(box(Kind.face.rawValue * 10, face.boundingBox, face.confidence)) }
    let handBoxes: [(CGRect, Float)] = hands.compactMap { hand in
      guard let joints = try? hand.recognizedPoints(.all).values.filter({ $0.confidence >= 0.3 }), joints.count >= 4 else { return nil }
      let xs = joints.map(\.location.x), ys = joints.map(\.location.y)
      let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
      let pad = max(r.width, r.height) * 0.2
      return (r.insetBy(dx: -pad, dy: -pad), hand.confidence)
    }
    for (i, h) in handBoxes.sorted(by: { $0.0.midX < $1.0.midX }).prefix(2).enumerated() {
      out.append(box(Kind.hand.rawValue * 10 + i, h.0, h.1))
    }
    if let person = people.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
      out.append(box(Kind.person.rawValue * 10, person.boundingBox, person.confidence))
    }
    func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    let objects = salient.filter { o in
      let r = o.boundingBox
      guard area(r) < 0.5, handBoxes.contains(where: { r.intersects($0.0) }) else { return false }
      guard let f = face?.boundingBox else { return true }
      return area(r.intersection(f)) < 0.3 * area(r)
    }
    for (i, o) in objects.sorted(by: { $0.confidence > $1.confidence }).prefix(2).enumerated() {
      out.append(box(Kind.object.rawValue * 10 + i, o.boundingBox, o.confidence))
    }
    return out
  }

  /// `{"version", "video", "step", "samples": [[t, id, x, y, w, h, confidence, ...]]}`.
  static func write(_ tracking: Tracking, video: String, to url: URL) throws {
    func r(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
    let rows: [[Double]] = tracking.samples.map { s in
      [r(s.t)] + s.boxes.flatMap { [Double($0.id), r($0.x), r($0.y), r($0.w), r($0.h), r($0.confidence)] }
    }
    let json: [String: Any] = ["version": version, "video": video, "step": step, "samples": rows]
    try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
  }

  /// The saved tracking, or nil when it's for another camera file or an older version.
  static func read(_ url: URL, video: String) throws -> Tracking? {
    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      json["version"] as? Int == version, json["video"] as? String == video, let rows = json["samples"] as? [[Double]]
    else { return nil }
    return Tracking(
      // Closure types spelled out: CI's compiler gives up inferring this one ("unable to type-check").
      samples: rows.compactMap { (row: [Double]) -> Sample? in
        guard let t = row.first, (row.count - 1) % 6 == 0 else { return nil }
        let boxes = stride(from: 1, to: row.count, by: 6).map { (i: Int) -> Box in
          Box(id: Int(row[i]), x: row[i + 1], y: row[i + 2], w: row[i + 3], h: row[i + 4], confidence: row[i + 5])
        }
        return Sample(t: t, boxes: boxes)
      })
  }
}

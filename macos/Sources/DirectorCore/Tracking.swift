import AVFoundation
import Foundation
import Vision

/// Points Vision follows on the camera (body joints and fingertips), for effects that draw tracking
/// boxes. Found once per camera file at `step` seconds apart and kept in `tracking.json` next to it.
public struct Tracking: Equatable {
  /// One followed point: `id` names what it is (the same id is the same joint in every sample), x and
  /// y are 0..1 of the camera frame with y down, `size` is a box size as a fraction of the frame height.
  public struct Point: Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var size: Double
  }
  public struct Sample: Equatable {
    public var t: Double
    public var points: [Point]
  }

  public static let fileName = "tracking.json"
  public static let step = 0.1
  /// Changing what's tracked changes this, so older files are found again.
  static let version = 1

  /// Samples in camera seconds, in order.
  public var samples: [Sample]

  static let bodyJoints: [VNHumanBodyPoseObservation.JointName] = [
    .nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck, .leftShoulder, .rightShoulder,
    .leftElbow, .rightElbow, .leftWrist, .rightWrist,
  ]
  static let handJoints: [VNHumanHandPoseObservation.JointName] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
  /// Ids 0-11 are `bodyJoints`; each hand's fingertips follow, 20-24 and 30-34.
  static func handID(hand: Int, joint: Int) -> Int { 20 + hand * 10 + joint }

  /// The points at camera time `t`, each moved linearly between the samples around it. A point
  /// in only one of the two samples shows only within half a step of that sample, so it doesn't
  /// slide from nowhere.
  public func points(at t: Double) -> [Point] {
    guard let first = samples.first, let last = samples.last, t >= first.t - Tracking.step, t <= last.t + Tracking.step else { return [] }
    var lo = 0, hi = samples.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
    }
    let a = samples[lo]
    guard lo + 1 < samples.count, t > a.t else { return a.points }
    let b = samples[lo + 1]
    let k = (t - a.t) / max(1e-6, b.t - a.t)
    let later = Dictionary(b.points.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
    var out: [Point] = []
    var seen = Set<Int>()
    for p in a.points {
      seen.insert(p.id)
      if let q = later[p.id] {
        out.append(Point(id: p.id, x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k, size: p.size + (q.size - p.size) * k))
      } else if k < 0.5 {
        out.append(p)
      }
    }
    if k >= 0.5 { out += b.points.filter { !seen.contains($0.id) } }
    return out.sorted { $0.id < $1.id }
  }

  /// The camera's tracking, read from `tracking.json` or found and saved there when it's missing
  /// or older than the camera file.
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

  /// Runs Vision body and hand pose on frames `step` seconds apart.
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
      let body = VNDetectHumanBodyPoseRequest()
      let hands = VNDetectHumanHandPoseRequest()
      hands.maximumHandCount = 2
      try VNImageRequestHandler(cvPixelBuffer: px).perform([body, hands])
      let height = Double(CVPixelBufferGetHeight(px)), width = Double(CVPixelBufferGetWidth(px))
      samples.append(Sample(t: t, points: points(body: body.results ?? [], hands: hands.results ?? [], aspect: width / height)))
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return Tracking(samples: samples)
  }

  /// The tracked points of one frame. Box sizes scale with the person: a joint's box is a quarter
  /// of the shoulder width (or two eye widths when the shoulders aren't seen), a fingertip's half that.
  static func points(body: [VNHumanBodyPoseObservation], hands: [VNHumanHandPoseObservation], aspect: Double) -> [Point] {
    let minConfidence: Float = 0.3
    var out: [Point] = []
    // The biggest person is the speaker.
    let person = body.max { ($0.availableJointNames.count) < ($1.availableJointNames.count) }
    let joints = (try? person?.recognizedPoints(.all)) ?? [:]
    func seen(_ name: VNHumanBodyPoseObservation.JointName) -> VNRecognizedPoint? {
      guard let p = joints[name], p.confidence >= minConfidence else { return nil }
      return p
    }
    // Distances in frame-height units (x is scaled by the aspect so both axes match).
    func distance(_ a: VNRecognizedPoint, _ b: VNRecognizedPoint) -> Double {
      hypot((a.location.x - b.location.x) * aspect, a.location.y - b.location.y)
    }
    var scale = 0.06
    if let l = seen(.leftShoulder), let r = seen(.rightShoulder) {
      scale = distance(l, r) / 4
    } else if let l = seen(.leftEye), let r = seen(.rightEye) {
      scale = distance(l, r) * 2
    }
    for (i, name) in bodyJoints.enumerated() {
      guard let p = seen(name) else { continue }
      out.append(Point(id: i, x: Double(p.location.x), y: 1 - Double(p.location.y), size: scale))
    }
    let handList = hands.sorted { (try? $0.recognizedPoint(.wrist).location.x) ?? 0 < (try? $1.recognizedPoint(.wrist).location.x) ?? 0 }
    for (h, hand) in handList.prefix(2).enumerated() {
      for (j, name) in handJoints.enumerated() {
        guard let p = try? hand.recognizedPoint(name), p.confidence >= minConfidence else { continue }
        out.append(Point(id: handID(hand: h, joint: j), x: Double(p.location.x), y: 1 - Double(p.location.y), size: scale / 2))
      }
    }
    return out
  }

  /// `{"version", "video", "step", "samples": [[t, id, x, y, size, id, x, y, size, ...]]}`.
  static func write(_ tracking: Tracking, video: String, to url: URL) throws {
    func r(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
    let rows: [[Double]] = tracking.samples.map { s in
      [r(s.t)] + s.points.flatMap { [Double($0.id), r($0.x), r($0.y), r($0.size)] }
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
      samples: rows.compactMap { row in
        guard let t = row.first, (row.count - 1) % 4 == 0 else { return nil }
        let points = stride(from: 1, to: row.count, by: 4).map { i in
          Point(id: Int(row[i]), x: row[i + 1], y: row[i + 2], size: row[i + 3])
        }
        return Sample(t: t, points: points)
      })
  }
}

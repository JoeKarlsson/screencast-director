import CoreImage
import Foundation
import Metal

/// An effect a plan uses: a shader from an effect folder, applied to one layer of every frame.
public struct EffectUse: Codable, Equatable {
  /// The effect folder's name (letters, digits, `-` and `_`).
  public var name: String
  /// `screen`, `camera` or `frame` (everything under the titles and captions). nil is the effect's own.
  public var layer: String?
  /// Values for the effect's params by name; a param left out uses its default.
  public var params: [String: Double]?

  public init(name: String, layer: String? = nil, params: [String: Double]? = nil) {
    self.name = name
    self.layer = layer
    self.params = params
  }
}

/// An effect drawn only between two source times, with its own settings.
public struct EffectRange: Codable, Equatable {
  public var start: Double
  public var end: Double
  /// The effect folder's name.
  public var name: String
  /// `screen`, `camera` or `frame`; nil is the effect's own.
  public var layer: String?
  /// Values for the effect's params by name; a param left out uses its default.
  public var params: [String: Double]?
  public var note: String?

  public init(start: Double, end: Double, name: String, layer: String? = nil, params: [String: Double]? = nil, note: String? = nil) {
    self.start = start
    self.end = end
    self.name = name
    self.layer = layer
    self.params = params
    self.note = note
  }

  public var use: EffectUse { EffectUse(name: name, layer: layer, params: params) }
}

/// `effect.json` in an effect folder, next to `effect.metal`.
public struct EffectManifest: Codable, Equatable {
  public struct Param: Codable, Equatable {
    public var name: String
    public var `default`: Double
    public var min: Double?
    public var max: Double?
  }
  public var title: String
  /// The layer it's made for: `screen`, `camera` or `frame`.
  public var layer: String
  /// How many pixels away from a pixel the shader reads (for shifts and blurs). Reads further than
  /// this come back clamped to the edge of the tile Core Image hands over. nil is 0.
  public var reach: Int?
  /// Floats the shader reads as `p[0]`, `p[1]`, … in this order.
  public var params: [Param]?
  /// Whether the shader reads `blobs`, the points followed on its layer (body joints and fingertips
  /// on the camera, the pointer and recent clicks on the screen). Tracking the camera takes a pass
  /// over it the first time, so only effects that ask get it.
  public var tracking: Bool?
}

/// Where effects come from, first match wins: the video's own `effects/` folder (a frozen copy), then
/// the personal library (~/Library/Application Support/Screencast Director/Effects). Each effect is a
/// folder `<name>/` holding `effect.json` and `effect.metal`. None are built into the app: they're
/// plugins, so a strong look like glitching stays out of the core.
public struct EffectSources {
  public let project: URL?
  public let personal: URL

  public static var personalFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Screencast Director/Effects")
  }

  public init(project: URL?, personal: URL = EffectSources.personalFolder) {
    self.project = project
    self.personal = personal
  }

  public static func videoFolder(_ project: URL) -> URL { project.appendingPathComponent("effects") }

  public static func isValidName(_ name: String) -> Bool {
    !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }

  /// The effects you can use: the video's frozen ones and the personal library's, by name.
  public func available() -> [String] {
    let candidates = (project.map { [EffectSources.videoFolder($0)] } ?? []) + [personal]
    let names = candidates.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
    return Set(names.filter { folder($0) != nil }).sorted()
  }

  /// An effect's `effect.json`, or nil when it isn't anywhere or can't be read.
  public func manifest(_ name: String) -> EffectManifest? {
    guard let dir = folder(name) else { return nil }
    return try? JSONDecoder().decode(EffectManifest.self, from: Data(contentsOf: dir.appendingPathComponent("effect.json")))
  }

  /// The folder an effect loads from, or nil when no folder has it.
  public func folder(_ name: String) -> URL? {
    guard EffectSources.isValidName(name) else { return nil }
    let candidates = (project.map { [EffectSources.videoFolder($0)] } ?? []) + [personal]
    return candidates.map { $0.appendingPathComponent(name) }.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("effect.metal").path)
    }
  }

  /// Copies the library's effect into the video's folder unless it's already there, so changing the
  /// library later never changes a finished video. Returns whether it copied.
  @discardableResult
  public func freeze(_ name: String) throws -> Bool {
    guard let project, EffectSources.isValidName(name) else { return false }
    let fm = FileManager.default
    let dst = EffectSources.videoFolder(project).appendingPathComponent(name)
    let src = personal.appendingPathComponent(name)
    guard !fm.fileExists(atPath: dst.appendingPathComponent("effect.metal").path),
      fm.fileExists(atPath: src.appendingPathComponent("effect.metal").path)
    else { return false }
    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: dst)
    try fm.copyItem(at: src, to: dst)
    return true
  }
}

/// What an effect knows about the moment it draws (output time). The layout matches `Signals` in
/// `Effects.prelude` after its `size`: Metal aligns a float2 to 8 bytes, so `click` comes first,
/// right after `size`, and the rest are single floats with no padding.
public struct EffectSignals: Equatable {
  /// Where the last click was (screen fractions, y down).
  public var clickX: Float = 0.5
  public var clickY: Float = 0.5
  /// Seconds into the output video, and the output frame.
  public var time: Float = 0
  public var frame: Float = 0
  /// Seconds since the last click (1e6 before the first).
  public var sinceClick: Float = 1e6
  /// Seconds to the nearest visible change, before or after: a cut between clips, B-roll or an
  /// animation starting or ending, a layout change or a punch-in.
  public var toCut: Float = 1e6
  /// Playback speed of the clip on screen (1 is real time).
  public var speed: Float = 1
  /// When that nearest change happens, in output seconds (-1 when there's none): the same for every
  /// frame around one change and different for the next, so an effect can vary from cut to cut.
  public var cutTime: Float = -1
  /// Which change that is, counting from 0 at the first, in play order (-1 when there's none).
  public var cutIndex: Float = -1
  /// What that change is (`CutKind`), so an effect can save its big moments for the ones that matter.
  public var cutKind: Float = -1
  /// How many entries `blobs` holds for this layer (set per layer when the effect is drawn).
  public var blobs: Float = 0

  public enum CutKind: Float {
    case cut = 0, jumpBack = 1, broll = 2, layout = 3, punchIn = 4, section = 5
    /// Which name a frame gets when several changes land on it.
    var rank: Int {
      switch self {
      case .jumpBack: return 5
      case .section: return 4
      case .broll: return 3
      case .cut: return 2
      case .layout: return 1
      case .punchIn: return 0
      }
    }
  }

  public init() {}
}

/// An effect compiled for this plan.
public final class LoadedEffect: @unchecked Sendable {
  public let name: String
  public let layer: String
  let reach: Int
  let pipeline: MTLComputePipelineState
  let params: [Float]
  public let tracking: Bool

  init(name: String, layer: String, reach: Int, pipeline: MTLComputePipelineState, params: [Float], tracking: Bool) {
    self.name = name
    self.layer = layer
    self.reach = reach
    self.pipeline = pipeline
    self.params = params
    self.tracking = tracking
  }

  /// The image with the effect drawn on it, for this frame's signals and the blobs followed on its
  /// layer (in the layer's pixels, y down).
  func apply(_ image: CIImage, signals: EffectSignals, blobs: [EffectBlob] = []) -> CIImage {
    let extent = image.extent.integral
    guard extent.width >= 1, extent.height >= 1, !image.extent.isInfinite else { return image }
    var s = signals
    let blobs = tracking ? Array(blobs.prefix(Effects.maxBlobs)) : []
    s.blobs = Float(blobs.count)
    // Metal needs a buffer even when there's nothing in it.
    var blobData = Data()
    for b in blobs.isEmpty ? [EffectBlob(x: 0, y: 0, size: 0, id: -1)] : blobs {
      var v = SIMD4<Float>(b.x, b.y, b.size, b.id)
      blobData += withUnsafeBytes(of: &v) { Data($0) }
    }
    var size = SIMD2<Float>(Float(extent.width), Float(extent.height))
    let packed = withUnsafeBytes(of: &size) { Data($0) } + withUnsafeBytes(of: &s) { Data($0) }
    do {
      // Shaders see the colors as they look (sRGB-encoded), not Core Image's linear working space.
      let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
      let drawn = try EffectKernel.apply(withExtent: extent, inputs: [encoded], arguments: ["effect": self, "extent": extent, "signals": packed, "blobs": blobData])
      return drawn.applyingFilter("CISRGBToneCurveToLinear")
    } catch {
      // apply only checks the arguments built just above, so this is a bug here, not in the effect.
      FileHandle.standardError.write(Data("effect \(name) didn't run: \(error.localizedDescription)\n".utf8))
      return image
    }
  }
}

/// A point an effect can draw a tracking box on: its center and box size in the layer's pixels (y
/// down) and what it is (`id`, the same for the same joint or pointer from frame to frame).
public struct EffectBlob: Equatable {
  public var x: Float
  public var y: Float
  public var size: Float
  public var id: Float
}

public enum Effects {
  public static let layers = ["screen", "camera", "frame"]
  /// At most this many blobs reach a shader.
  public static let maxBlobs = 32

  /// Declarations every effect.metal gets in front of it. An effect defines
  /// `float4 effect(Layer src, float2 pos, Signals s, constant float *p)`, returning the color at
  /// `pos` (pixels from the layer's top-left corner, at the pixel's center); `src.read(pos)` reads the
  /// layer there, clamped to its edges. Colors are sRGB-encoded 0...1, as they look on screen.
  public static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct Signals {
      float2 size;          // the layer's size in pixels
      float2 click;         // where the last click was, 0..1 of the screen, y down
      float time;           // seconds into the output video
      float frame;          // output frame
      float sinceClick;     // seconds since the last click (1e6 before the first)
      float toCut;          // seconds to the nearest cut, B-roll, layout change or punch-in
      float speed;          // playback speed of the clip on screen
      float cutTime;        // when that nearest change happens, in output seconds (-1 with none)
      float cutIndex;       // which change that is: 0 for the first, in play order (-1 with none)
      float cutKind;        // 0 cut, 1 jump back (to an earlier moment, after a cold open), 2 B-roll or
                            // an animation, 3 layout change, 4 punch-in, 5 new section (a chapter or slate title)
      float blobs;          // how many entries blobs holds (0 unless effect.json has "tracking": true)
    };

    struct Layer {
      texture2d<float, access::read> tex;
      int2 origin;          // the layer's top-left corner in tex
      float2 size;
      // The points followed on this layer, s.blobs of them: xy the center in the layer's pixels (y
      // down), z a box size in pixels, w its id (camera: 0 nose, 1-2 eyes, 3-4 ears, 5 neck, 6-7
      // shoulders, 8-9 elbows, 10-11 wrists, 20-24 and 30-34 the fingertips of each hand; screen: 100
      // the pointer, 101 and up recent clicks).
      constant float4 *blobs;
      float4 read(float2 pos) const {
        float2 q = clamp(floor(pos), float2(0), size - 1);
        int2 t = clamp(int2(q) + origin, int2(0), int2(tex.get_width() - 1, tex.get_height() - 1));
        return tex.read(uint2(t));
      }
    };
    inline float hash(float2 q) { return fract(sin(dot(q, float2(127.1, 311.7))) * 43758.5453); }
    inline float luma(float4 c) { return dot(c.rgb, float3(0.299, 0.587, 0.114)); }

    """

  static let entry = """

    struct SDOrigins { int2 input; int2 output; };
    kernel void sd_effect(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant Signals &s [[buffer(0)]],
                          constant float *p [[buffer(1)]],
                          constant SDOrigins &o [[buffer(2)]],
                          constant float4 *blobs [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
      Layer layer = { src, o.input, s.size, blobs };
      float2 pos = float2(int2(gid) + o.output) + 0.5;
      dst.write(effect(layer, pos, s, p), gid);
    }
    """

  /// Compiles each effect the plan uses, freezing library effects into the video first. Throws,
  /// naming the effect, when one is missing, has a bad manifest or doesn't compile.
  public static func load(_ uses: [EffectUse], sources: EffectSources) throws -> [LoadedEffect] {
    guard !uses.isEmpty else { return [] }
    guard let device = MTLCreateSystemDefaultDevice() else { throw DirectorError("Effects need a Metal GPU, and this Mac has none.") }
    return try uses.map { use in
      guard EffectSources.isValidName(use.name) else {
        throw DirectorError("Effect name \"\(use.name)\" can only use letters, digits, - and _.")
      }
      try sources.freeze(use.name)
      guard let folder = sources.folder(use.name) else {
        throw DirectorError("Effect \"\(use.name)\" isn't in the video's effects/ folder or in \(sources.personal.path).")
      }
      let manifest: EffectManifest
      do {
        manifest = try JSONDecoder().decode(EffectManifest.self, from: Data(contentsOf: folder.appendingPathComponent("effect.json")))
      } catch {
        throw DirectorError("Effect \"\(use.name)\": effect.json can't be read: \(error.localizedDescription)")
      }
      let layer = use.layer ?? manifest.layer
      guard layers.contains(layer) else {
        throw DirectorError("Effect \"\(use.name)\": layer \"\(layer)\" isn't one of \(layers.joined(separator: ", ")).")
      }
      let declared = Set((manifest.params ?? []).map(\.name))
      if let unknown = use.params?.keys.sorted().first(where: { !declared.contains($0) }) {
        throw DirectorError("Effect \"\(use.name)\" has no param \"\(unknown)\" (it has \(declared.sorted().joined(separator: ", "))).")
      }
      let source = try String(contentsOf: folder.appendingPathComponent("effect.metal"), encoding: .utf8)
      let pipeline: MTLComputePipelineState
      do {
        let library = try device.makeLibrary(source: prelude + source + entry, options: nil)
        guard let fn = library.makeFunction(name: "sd_effect") else { throw DirectorError("no kernel") }
        pipeline = try device.makeComputePipelineState(function: fn)
      } catch {
        throw DirectorError("Effect \"\(use.name)\" doesn't compile: \(error.localizedDescription)")
      }
      let params = (manifest.params ?? []).map { p -> Float in
        let v = use.params?[p.name] ?? p.default
        return Float(Swift.min(p.max ?? .infinity, Swift.max(p.min ?? -.infinity, v)))
      }
      return LoadedEffect(name: use.name, layer: layer, reach: max(0, manifest.reach ?? 0), pipeline: pipeline, params: params, tracking: manifest.tracking == true)
    }
  }
}

/// Runs an effect's compiled shader inside Core Image, so it draws the same in preview and export.
final class EffectKernel: CIImageProcessorKernel {
  override class var outputFormat: CIFormat { .RGBAh }
  override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

  override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
    let reach = CGFloat((arguments?["effect"] as? LoadedEffect)?.reach ?? 0)
    return outputRect.insetBy(dx: -reach, dy: -reach)
  }

  override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
    guard let effect = arguments?["effect"] as? LoadedEffect, let extent = arguments?["extent"] as? CGRect,
      let signals = arguments?["signals"] as? Data, let blobs = arguments?["blobs"] as? Data, let input = inputs?.first,
      let src = input.metalTexture, let dst = output.metalTexture, let buffer = output.metalCommandBuffer,
      let encoder = buffer.makeComputeCommandEncoder()
    else { throw DirectorError("An effect was asked to draw without its textures.") }
    // Texture rows run top down; regions and the extent are Core Image rects, bottom up.
    var origins: [Int32] = [
      Int32((extent.minX - input.region.minX).rounded()), Int32((input.region.maxY - extent.maxY).rounded()),
      Int32((output.region.minX - extent.minX).rounded()), Int32((extent.maxY - output.region.maxY).rounded()),
    ]
    var params = effect.params.isEmpty ? [Float(0)] : effect.params
    encoder.setComputePipelineState(effect.pipeline)
    encoder.setTexture(src, index: 0)
    encoder.setTexture(dst, index: 1)
    signals.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
    encoder.setBytes(&params, length: params.count * 4, index: 1)
    encoder.setBytes(&origins, length: origins.count * 4, index: 2)
    blobs.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
    let w = effect.pipeline.threadExecutionWidth
    let h = max(1, effect.pipeline.maxTotalThreadsPerThreadgroup / w)
    encoder.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    encoder.endEncoding()
  }
}

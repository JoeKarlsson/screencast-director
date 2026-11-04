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
  /// Seconds to the nearest cut between clips, before or after.
  public var toCut: Float = 1e6
  /// Playback speed of the clip on screen (1 is real time).
  public var speed: Float = 1

  public init() {}
}

/// An effect compiled for this plan.
public final class LoadedEffect: @unchecked Sendable {
  public let name: String
  public let layer: String
  let reach: Int
  let pipeline: MTLComputePipelineState
  let params: [Float]

  init(name: String, layer: String, reach: Int, pipeline: MTLComputePipelineState, params: [Float]) {
    self.name = name
    self.layer = layer
    self.reach = reach
    self.pipeline = pipeline
    self.params = params
  }

  /// The image with the effect drawn on it, for this frame's signals.
  func apply(_ image: CIImage, signals: EffectSignals) -> CIImage {
    let extent = image.extent.integral
    guard extent.width >= 1, extent.height >= 1, !image.extent.isInfinite else { return image }
    var s = signals
    var size = SIMD2<Float>(Float(extent.width), Float(extent.height))
    let packed = withUnsafeBytes(of: &size) { Data($0) } + withUnsafeBytes(of: &s) { Data($0) }
    do {
      // Shaders see the colors as they look (sRGB-encoded), not Core Image's linear working space.
      let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
      let drawn = try EffectKernel.apply(withExtent: extent, inputs: [encoded], arguments: ["effect": self, "extent": extent, "signals": packed])
      return drawn.applyingFilter("CISRGBToneCurveToLinear")
    } catch {
      // apply only checks the arguments built just above, so this is a bug here, not in the effect.
      FileHandle.standardError.write(Data("effect \(name) didn't run: \(error.localizedDescription)\n".utf8))
      return image
    }
  }
}

public enum Effects {
  public static let layers = ["screen", "camera", "frame"]

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
      float toCut;          // seconds to the nearest cut between clips
      float speed;          // playback speed of the clip on screen
    };
    struct Layer {
      texture2d<float, access::read> tex;
      int2 origin;          // the layer's top-left corner in tex
      float2 size;
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
                          uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
      Layer layer = { src, o.input, s.size };
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
      return LoadedEffect(name: use.name, layer: layer, reach: max(0, manifest.reach ?? 0), pipeline: pipeline, params: params)
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
      let signals = arguments?["signals"] as? Data, let input = inputs?.first,
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
    let w = effect.pipeline.threadExecutionWidth
    let h = max(1, effect.pipeline.maxTotalThreadsPerThreadgroup / w)
    encoder.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    encoder.endEncoding()
  }
}

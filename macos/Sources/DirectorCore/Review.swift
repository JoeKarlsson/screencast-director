import Foundation

/// One thing an AI edit changed, which the user can keep or undo on its own.
public struct PlanChange: Identifiable {
  public let id = UUID()
  /// clips, zoom, layout, title, annotation, insert, animation, sound or style.
  public let kind: String
  public let label: String
  /// Where it is, in source seconds (nil for style changes).
  public let range: (Double, Double)?
  /// Puts this one change back the way it was, leaving the rest of the edit.
  public let revert: (inout Plan) -> Void
}

/// The changes between two plans, item by item for zooms, layouts, titles, annotations, B-roll,
/// animations and sound effects, as one
/// change for the clips (cuts and speed), and one for everything about the look.
public func planChanges(from old: Plan, to new: Plan) -> [PlanChange] {
  var out: [PlanChange] = []
  if old.segments != new.segments {
    var onlyClips = old
    onlyClips.segments = new.segments
    let ranges = changedRanges(from: old, to: onlyClips)
    let before = planSeconds(old), after = planSeconds(new)
    let oldSegments = old.segments
    out.append(
      PlanChange(
        kind: "clips", label: "Cuts and speed (\(fmtTime(before)) → \(fmtTime(after)))",
        range: ranges.first.map { ($0.0, ranges.last!.1) }, revert: { $0.segments = oldSegments }))
  }
  func items<T: Equatable>(
    _ path: WritableKeyPath<Plan, [T]>, kind: String, _ describe: @escaping (T) -> String, _ range: @escaping (T) -> (Double, Double)
  ) {
    let a = old[keyPath: path], b = new[keyPath: path]
    var removed = a.filter { !b.contains($0) }
    for item in b where !a.contains(item) {
      // An added item over a removed one is the same item, changed.
      let r = range(item)
      if let i = removed.firstIndex(where: { let o = range($0); return o.0 < r.1 && r.0 < o.1 }) {
        let was = removed.remove(at: i)
        out.append(
          PlanChange(kind: kind, label: "Changed \(describe(item))", range: r) { p in
            if let j = p[keyPath: path].firstIndex(of: item) { p[keyPath: path][j] = was }
          })
      } else {
        out.append(
          PlanChange(kind: kind, label: "Added \(describe(item))", range: r) { p in
            if let j = p[keyPath: path].firstIndex(of: item) { p[keyPath: path].remove(at: j) }
          })
      }
    }
    for item in removed {
      out.append(PlanChange(kind: kind, label: "Removed \(describe(item))", range: range(item)) { $0[keyPath: path].append(item) })
    }
  }
  items(\.zooms, kind: "zoom", { "zoom \($0.scale.formatted())× at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.layouts, kind: "layout", { "\($0.mode.rawValue) layout at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.callouts, kind: "title", { "\($0.style ?? "title") “\($0.text)”" }, { ($0.start, $0.end) })
  items(\.insertList, kind: "insert", { "B-roll \(($0.file as NSString).lastPathComponent) at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.annotationList, kind: "annotation", { "\($0.kind)\($0.text.map { " “\($0)”" } ?? "") at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.animationList, kind: "animation", { "\($0.template) animation at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.effectRangeList, kind: "effect", { "\($0.name) effect at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.sfxList, kind: "sound", { "sound \(($0.file as NSString).lastPathComponent) at \(fmtTime($0.t))" }, { ($0.t, $0.t) })
  if old.withTimedItems(from: new) != new {
    let was = old
    out.append(PlanChange(kind: "style", label: "Style, captions and settings", range: nil) { p in p = was.withTimedItems(from: p) })
  }
  return out.sorted { ($0.range?.0 ?? .infinity) < ($1.range?.0 ?? .infinity) }
}

extension Plan {
  /// `annotations` as a plain list (empty when there are none).
  public var annotationList: [Annotation] {
    get { annotations ?? [] }
    set { annotations = newValue.isEmpty ? nil : newValue }
  }

  /// `inserts` as a plain list (empty when there are none).
  public var insertList: [Insert] {
    get { inserts ?? [] }
    set { inserts = newValue.isEmpty ? nil : newValue }
  }

  /// `markers` as a plain list (empty when there are none), kept in time order.
  public var markerList: [Marker] {
    get { markers ?? [] }
    set { markers = newValue.isEmpty ? nil : newValue.sorted { $0.t < $1.t } }
  }

  /// `audio`, starting from the defaults when the plan has none.
  public var audioSettings: AudioSettings {
    get { audio ?? AudioSettings() }
    set { audio = newValue }
  }

  /// `cursor`, starting from the defaults when the plan has none.
  public var cursorSettings: CursorSettings {
    get { cursor ?? CursorSettings() }
    set { cursor = newValue }
  }

  /// `effectRanges` as a plain list (empty when there are none).
  public var effectRangeList: [EffectRange] {
    get { effectRanges ?? [] }
    set { effectRanges = newValue.isEmpty ? nil : newValue }
  }

  /// `sfx` as a plain list (empty when there are none).
  public var sfxList: [SoundEffect] {
    get { sfx ?? [] }
    set { sfx = newValue.isEmpty ? nil : newValue }
  }

  /// This plan with `other`'s clips and timed items: everything planChanges reviews item by item,
  /// so what's left differing is the look and settings.
  func withTimedItems(from other: Plan) -> Plan {
    var p = self
    p.segments = other.segments
    p.zooms = other.zooms
    p.layouts = other.layouts
    p.callouts = other.callouts
    p.annotations = other.annotations
    p.inserts = other.inserts
    p.animations = other.animations
    p.sfx = other.sfx
    p.effectRanges = other.effectRanges
    return p
  }
}

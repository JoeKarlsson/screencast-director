import Foundation

/// One thing an AI edit changed, which the user can keep or undo on its own.
public struct PlanChange: Identifiable {
  public let id = UUID()
  /// clips, zoom, layout, title, annotation or style.
  public let kind: String
  public let label: String
  /// Where it is, in source seconds (nil for style changes).
  public let range: (Double, Double)?
  /// Puts this one change back the way it was, leaving the rest of the edit.
  public let revert: (inout Plan) -> Void
}

/// The changes between two plans, item by item for zooms, layouts, titles and annotations, as one
/// change for the clips (cuts and speed), and one for everything about the look.
public func planChanges(from old: Plan, to new: Plan) -> [PlanChange] {
  var out: [PlanChange] = []
  if old.segments != new.segments {
    let ranges = changedRanges(from: Plan.withOnly(segments: old), to: Plan.withOnly(segments: new))
    let before = Double(planFrames(old)) / Double(old.output.fps), after = Double(planFrames(new)) / Double(new.output.fps)
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
  items(\.annotationList, kind: "annotation", { "\($0.kind)\($0.text.map { " “\($0)”" } ?? "") at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  var look = old
  look.segments = new.segments
  look.zooms = new.zooms
  look.layouts = new.layouts
  look.callouts = new.callouts
  look.annotations = new.annotations
  if look != new {
    let was = old
    out.append(
      PlanChange(kind: "style", label: "Style, captions and settings", range: nil) { p in
        let keep = p
        p = was
        p.segments = keep.segments
        p.zooms = keep.zooms
        p.layouts = keep.layouts
        p.callouts = keep.callouts
        p.annotations = keep.annotations
      })
  }
  return out.sorted { ($0.range?.0 ?? .infinity) < ($1.range?.0 ?? .infinity) }
}

extension Plan {
  /// `annotations` as a plain list (empty when there are none).
  public var annotationList: [Annotation] {
    get { annotations ?? [] }
    set { annotations = newValue.isEmpty ? nil : newValue }
  }

  /// A copy with only these segments differing from an empty edit, for changedRanges.
  static func withOnly(segments p: Plan) -> Plan {
    var q = p
    q.zooms = []
    q.layouts = []
    q.callouts = []
    q.annotations = nil
    return q
  }
}

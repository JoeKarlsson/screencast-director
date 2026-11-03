import Foundation

/// Project folders ordered by when each was last opened, newest first. `opened` maps a folder's
/// standardized path to its last-opened time; folders never opened follow, in their given order.
public func byLastOpened(_ projects: [URL], opened: [String: Double]) -> [URL] {
  projects.enumerated()
    .map { (index: $0.offset, url: $0.element, at: opened[$0.element.standardizedFileURL.path]) }
    .sorted { a, b in
      switch (a.at, b.at) {
      case let (x?, y?): return x > y
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): return a.index < b.index
      }
    }
    .map(\.url)
}

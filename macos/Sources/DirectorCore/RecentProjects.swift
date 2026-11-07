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

/// The projects the app lists: every project in the projects folder, plus projects elsewhere that
/// were opened in the app (made with `sd import` or `director join` in another folder), so they stay
/// findable. A project is a folder with a `source.json`; opened folders that are gone are left out.
/// Newest first by creation date.
public func libraryProjects(folder: URL, opened: [String: Double]) -> [URL] {
  let fm = FileManager.default
  let inFolder = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
  let known = Set(inFolder.map(\.standardizedFileURL.path))
  let elsewhere = opened.keys.filter { !known.contains($0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
  func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
  return (inFolder + elsewhere)
    .filter { fm.fileExists(atPath: $0.appendingPathComponent("source.json").path) }
    .sorted { created($0) > created($1) }
}

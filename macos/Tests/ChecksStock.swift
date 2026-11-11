import AVFoundation
import Foundation
import ImageIO

/// Stock video and GIFs: each library's answer read into items (captured shapes, trimmed), only
/// licenses a video can use, the file picked to download, and no KLIPY GIF in a work video.
func stockChecks() {
  // An API's id stands in for an empty title as a file name, so it's cleaned the same way.
  expect(Stock.fileName("", fallback: "../../../SD-ESCAPE") == ".. .. .. SD-ESCAPE" && Stock.fileName("", fallback: "..") == "download",
    "a fallback id can't hold a path (\(Stock.fileName("", fallback: "../../../SD-ESCAPE")))")
  expect(Stock.ffmpegArguments(URL(fileURLWithPath: "/t/in.gif"), URL(fileURLWithPath: "/t/out.mp4"), loop: true).contains("-protocol_whitelist"),
    "ffmpeg opens only local files")
  let csvFolder = FileManager.default.temporaryDirectory.appendingPathComponent("sd-csv-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: csvFolder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: csvFolder) }
  try? (Openverse.licenseHeader + Openverse.csvRow(["../../x.mp4", "a"]) + Openverse.csvRow(["ok.mp4", "b"])).write(
    to: csvFolder.appendingPathComponent(Openverse.licenseFile), atomically: true, encoding: .utf8)
  expect(Openverse.recorded("a", in: csvFolder) == nil && Openverse.recorded("b", in: csvFolder) == "ok.mp4", "a license record only names files in its folder")
  let zshrc = csvFolder.appendingPathComponent("victim.txt")
  try? Data("ORIGINAL".utf8).write(to: zshrc)
  try? FileManager.default.createSymbolicLink(atPath: csvFolder.appendingPathComponent(Stock.licenseFile).path, withDestinationPath: zshrc.path)
  let item = Stock.Item(id: "openverse:x", title: "t $(x)", creator: "c", license: "CC0", needsCredit: false, page: "p")
  expect((try? Stock.record(item, file: "x.mp4", in: csvFolder)) == nil && (try? String(contentsOf: zshrc, encoding: .utf8)) == "ORIGINAL",
    "a license row never goes through a symlinked CSV")
  func data(_ s: String) -> Data { Data(s.utf8) }
  do {
    let nasa = try Stock.nasaItems(data(#"""
      {"collection":{"items":[{"data":[{"nasa_id":"a","title":"Spacewalk","center":"JSC"}]},{"data":[{"nasa_id":"b","title":"Launch","photographer":"Rocket Lab"}]}]}}
      """#))
    expect(nasa.map(\.needsCredit) == [false, true] && nasa[1].license.contains("check"), "NASA: its own media is public domain, a partner's is flagged (\(nasa.map(\.license)))")
    let nasaFile = try Stock.nasaFile(data(#"{"collection":{"items":[{"href":"http://n/x~orig.mp4"},{"href":"http://n/x~large.mp4"},{"href":"http://n/x.vtt"}]}}"#))
    expect(nasaFile == "https://n/x~large.mp4", "NASA: the large MP4, over https (\(nasaFile ?? "nil"))")

    expect(Stock.commonsLicense("cc-by-sa-4.0", allowCredit: true) == nil, "Commons: share-alike is never offered")
    expect(
      Stock.commonsLicense("cc-by-4.0", allowCredit: false) == nil && Stock.commonsLicense("cc-by-4.0", allowCredit: true)?.credit == true,
      "Commons: CC BY only with --credit-ok, and it needs credit")
    expect(
      Stock.commonsLicense("pd-usgov", allowCredit: false)?.credit == false && Stock.commonsLicense("cc0", allowCredit: false) != nil,
      "Commons: CC0 and public domain need no credit")
    let commons = try Stock.commonsItems(data(#"""
      {"query":{"pages":{"1":{"title":"File:Short.webm","index":2,"imageinfo":[{"url":"https://u/s.webm","descriptionurl":"https://c/s","duration":11,
        "extmetadata":{"License":{"value":"cc0"},"Artist":{"value":"<a href=\"x\">Me &amp; You</a>"}}}]},
        "2":{"title":"File:Lecture.webm","index":1,"imageinfo":[{"url":"https://u/l.webm","descriptionurl":"https://c/l","duration":2000,"extmetadata":{"License":{"value":"cc0"}}}]}}}}
      """#), allowCredit: false)
    expect(commons.map(\.id) == ["commons:File:Short.webm"] && commons.first?.creator == "Me & You", "Commons: long videos are left out and the artist's HTML is stripped (\(commons))")

    let archive = try Stock.archiveItems(data(#"""
      {"response":{"docs":[{"identifier":"a","title":"A","licenseurl":"http://creativecommons.org/publicdomain/mark/1.0/"},
        {"identifier":"b","licenseurl":"http://creativecommons.org/licenses/by-nc/3.0/"},{"identifier":"c","creator":["X","Y"]}]}}
      """#))
    expect(archive.map(\.id) == ["archive:a", "archive:c"] && archive[1].creator == "X, Y", "Archive: a film marked other than public domain is left out (\(archive))")
    let archiveFile = try Stock.archiveFile(data(#"{"files":[{"name":"a_512kb.mp4","format":"512Kb MPEG4"},{"name":"a film.mp4","format":"h.264"}]}"#), identifier: "a")
    expect(archiveFile == "https://archive.org/download/a/a%20film.mp4", "Archive: the H.264 derivative (\(archiveFile ?? "nil"))")

    let klipy = try Stock.klipyItems(data(#"""
      {"result":true,"data":{"data":[{"slug":"hello-hi-662","title":"Hello","file":{"hd":{"gif":{"url":"https://k/h.gif","width":498,"height":498},"mp4":{"url":"https://k/h.mp4","width":498,"height":498}}}},
        {"slug":"gif-only","file":{"md":{"gif":{"url":"https://k/m.gif"}}}}],"current_page":1,"has_next":true}}
      """#))
    expect(klipy.map(\.file) == ["https://k/h.mp4", "https://k/m.gif"] && klipy.first?.id == "klipy:hello-hi-662", "KLIPY: the MP4 over the GIF, the biggest size offered (\(klipy))")
    let flat = try Stock.klipyItems(data(#"{"result":true,"data":[{"slug":"s","file":{"sm":{"gif":{"url":"https://k/s.gif"}}}}]}"#))
    expect(flat.count == 1, "KLIPY: an items answer with the list right under data")
    do {
      _ = try Stock.klipyItems(data(#"{"result":false,"errors":{"message":["The provided API key is invalid."]}}"#))
      expect(false, "KLIPY: a refused key throws")
    } catch {
      expect(error.localizedDescription.contains("API key is invalid"), "KLIPY: a refused key says why (\(error.localizedDescription))")
    }
  } catch {
    expect(false, "stock answers parse: \(error)")
  }

  // KLIPY is personal-only: not searched for, and refused before any download, in a work video.
  expect(Stock.gifSources(work: true) == [.openverse] && Stock.gifSources(work: false) == [.klipy, .openverse], "work videos search Openverse GIFs only")
  let klipyItem = Stock.Item(id: "klipy:x", title: "x", creator: "", license: "", needsCredit: false, page: "", file: "https://k/x.mp4")
  let refusal = blocking { try await Stock.add(klipyItem, project: FileManager.default.temporaryDirectory, work: true) }
  if case .failure(let error) = refusal {
    expect(error.localizedDescription.contains("work videos don't use them"), "a KLIPY GIF is refused in a work video (\(error.localizedDescription))")
  } else {
    expect(false, "a KLIPY GIF is refused in a work video")
  }

  // A one-frame GIF becomes 30 s of video, not a clip too short to show.
  let gifDir = FileManager.default.temporaryDirectory.appendingPathComponent("stock-gif-\(UUID())")
  defer { try? FileManager.default.removeItem(at: gifDir) }
  do {
    try FileManager.default.createDirectory(at: gifDir, withIntermediateDirectories: true)
    let gif = gifDir.appendingPathComponent("still.gif"), mp4 = gifDir.appendingPathComponent("still.mp4")
    let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let dest = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    expect(CGImageDestinationFinalize(dest), "a one-frame GIF is written")
    try Stock.convertToMP4(gif, to: mp4, loop: true)
    let seconds = try blocking { try await AVURLAsset(url: mp4).load(.duration).seconds }.get()
    expect(abs(seconds - Stock.gifLongest) < 0.5, "a one-frame GIF loops into \(Stock.gifLongest) s of video (\(seconds) s)")
  } catch {
    expect(false, "converting a one-frame GIF: \(error)")
  }
  expect(!Stock.ffmpegArguments(URL(fileURLWithPath: "/a.webm"), URL(fileURLWithPath: "/a.mp4"), loop: false).contains("-stream_loop"), "a video plays once")

  // A network error never shows the URL, which carries KLIPY's key.
  let offline = blocking { try await Stock.get(URL(string: "http://127.0.0.1:9/secret-key/gifs")!) }
  if case .failure(let error) = offline {
    expect(!"\(error)".contains("secret-key") && error.localizedDescription.contains("127.0.0.1"), "a network error names the host only (\(error))")
  } else {
    expect(false, "a request to a closed port fails")
  }
  expect((try? Stock.klipyKey(env: ["KLIPY_API_KEY": "k"], saved: { "app" })) == "k", "KLIPY's key from the environment wins over the app's")
  expect((try? Stock.klipyKey(env: [:], saved: { "app" })) == "app", "without the environment, the key saved in the app's Settings is used")
  expect((try? Stock.klipyKey(env: [:], saved: { nil })) == nil, "no key anywhere is an error")
  expect(Openverse.searchURL(.images, query: "x", allowCredit: false, fileExtension: "gif").query?.contains("extension=gif") == true, "Openverse GIF search asks for GIFs")
}

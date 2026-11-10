import Foundation

/// Stock video and GIFs: each library's answer read into items (captured shapes, trimmed), only
/// licenses a video can use, the file picked to download, and no KLIPY GIF in a work video.
func stockChecks() {
  func data(_ s: String) -> Data { Data(s.utf8) }
  do {
    let pexels = try Stock.pexelsItems(data(#"""
      {"videos":[{"id":857195,"url":"https://www.pexels.com/video/a-person-typing-on-a-laptop-857195/","duration":12,"user":{"name":"Ann"},
        "video_files":[{"file_type":"video/mp4","width":1280,"height":720,"link":"https://p/hd.mp4"},
                       {"file_type":"video/mp4","width":7680,"height":4320,"link":"https://p/8k.mp4"},
                       {"file_type":"video/mp4","width":3840,"height":2160,"link":"https://p/4k.mp4"}]}]}
      """#))
    expect(pexels.first?.file == "https://p/4k.mp4" && pexels.first?.title == "a person typing on a laptop", "Pexels: the sharpest MP4 up to 4K, titled from the page slug (\(pexels))")

    let nasa = try Stock.nasaItems(data(#"""
      {"collection":{"items":[{"data":[{"nasa_id":"a","title":"Spacewalk","center":"JSC"}]},{"data":[{"nasa_id":"b","title":"Launch","photographer":"Rocket Lab"}]}]}}
      """#))
    expect(nasa.map(\.needsCredit) == [false, true] && nasa[1].license.contains("check"), "NASA: its own media is public domain, a partner's is flagged (\(nasa.map(\.license)))")
    let nasaFile = try Stock.nasaFile(data(#"{"collection":{"items":[{"href":"http://n/x~orig.mp4"},{"href":"http://n/x~large.mp4"},{"href":"http://n/x.vtt"}]}}"#))
    expect(nasaFile == "https://n/x~large.mp4", "NASA: the large MP4, over https (\(nasaFile ?? "nil"))")

    expect(Stock.commonsLicense("cc-by-sa-4.0", allowCredit: true) == nil, "Commons: share-alike is never offered")
    expect(Stock.commonsLicense("cc-by-4.0", allowCredit: false) == nil && Stock.commonsLicense("cc-by-4.0", allowCredit: true)?.credit == true, "Commons: CC BY only with --credit-ok, and it needs credit")
    expect(Stock.commonsLicense("pd-usgov", allowCredit: false)?.credit == false && Stock.commonsLicense("cc0", allowCredit: false) != nil, "Commons: CC0 and public domain need no credit")
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
    expect(try Stock.klipyItems(data(#"{"result":true,"data":[{"slug":"s","file":{"sm":{"gif":{"url":"https://k/s.gif"}}}}]}"#)).count == 1, "KLIPY: an items answer with the list right under data")
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

  let gifArgs = Stock.ffmpegArguments(URL(fileURLWithPath: "/a.gif"), URL(fileURLWithPath: "/a.mp4"), loop: true)
  expect(gifArgs.prefix(2) == ["-stream_loop", "9"] && gifArgs.contains("30"), "a GIF loops ten times, at most 30 s")
  expect(!Stock.ffmpegArguments(URL(fileURLWithPath: "/a.webm"), URL(fileURLWithPath: "/a.mp4"), loop: false).contains("-stream_loop"), "a video plays once")
  expect(Stock.key(.pexels, env: ["PEXELS_API_KEY": "k"]) == "k" && Stock.key(.nasa, env: [:]) == nil, "keys come from the environment; keyless sources have none")
  expect(Openverse.searchURL(.images, query: "x", allowCredit: false, fileExtension: "gif").query?.contains("extension=gif") == true, "Openverse GIF search asks for GIFs")
}

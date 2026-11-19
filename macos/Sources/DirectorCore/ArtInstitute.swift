import Foundation

/// The Art Institute of Chicago's public API (no key): its public-domain artworks, whose images it
/// releases under CC0. Results come as Openverse items, so `stock images`/`get-image` treat them alike.
public enum ArtInstitute {
  static let api = "https://api.artic.edu/api/v1/artworks"
  static let fields = "id,title,artist_title,image_id,is_public_domain,thumbnail"

  static func searchURL(_ query: String) -> URL {
    var c = URLComponents(string: "\(api)/search")!
    c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "fields", value: fields)]
    return c.url!
  }

  public static func search(_ query: String) async throws -> [Openverse.Item] {
    try items(await Stock.get(searchURL(query)))
  }

  /// One artwork by its id (`aic:27992`), refused unless it's public domain with an image.
  public static func item(_ id: String) async throws -> Openverse.Item {
    guard id.hasPrefix("aic:"), let n = Int(id.dropFirst(4)) else { throw DirectorError("\"\(id)\" isn't an Art Institute id; they look like aic:27992") }
    guard let item = try items(await Stock.get(URL(string: "\(api)/\(n)?fields=\(fields)")!)).first else {
      throw DirectorError("the Art Institute's \(id) isn't public domain or has no image")
    }
    return item
  }

  /// Search and single-artwork answers. A search pads a query few works match with unrelated ones at
  /// a fraction of the top score, so those under a quarter of it are left out.
  static func items(_ data: Data) throws -> [Openverse.Item] {
    struct Thumb: Decodable { var width: Int?; var height: Int? }
    struct Work: Decodable {
      var _score: Double?; var id: Int; var title: String?; var artist_title: String?; var image_id: String?
      var is_public_domain: Bool?; var thumbnail: Thumb?
    }
    enum Body: Decodable {
      case one(Work), many([Work])
      init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let list = try? c.decode([Work].self) { self = .many(list) } else { self = .one(try c.decode(Work.self)) }
      }
    }
    struct Root: Decodable { var data: Body }
    let works: [Work]
    switch try JSONDecoder().decode(Root.self, from: data).data {
    case .one(let w): works = [w]
    case .many(let list): works = list
    }
    let floor = (works.first?._score ?? 0) / 4
    return works.compactMap { w in
      guard w.is_public_domain == true, let image = w.image_id, let fullWidth = w.thumbnail?.width, (w._score ?? floor) >= floor else { return nil }
      let width = imageWidth(fullWidth)
      return Openverse.Item(
        id: "aic:\(w.id)", title: w.title, creator: w.artist_title, license: "cc0", foreign_landing_url: "https://www.artic.edu/artworks/\(w.id)",
        url: "https://www.artic.edu/iiif/2/\(image)/full/\(width),/0/default.jpg", source: "Art Institute of Chicago", filetype: "jpg",
        width: width, height: w.thumbnail?.height.map { $0 * width / fullWidth })
    }
  }

  /// The width to ask its image server for: it serves 1686 or 843 px wide (other widths redirect
  /// to 843 or are refused) and never upscales, so a smaller image comes at its own size.
  static func imageWidth(_ full: Int) -> Int { full >= 1686 ? 1686 : full >= 843 ? 843 : full }
}

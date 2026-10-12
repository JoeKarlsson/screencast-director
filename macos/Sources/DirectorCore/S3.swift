import CryptoKit
import Foundation

/// Uploads to any S3-compatible store (AWS S3, MinIO, R2, B2) with a SigV4-signed PUT.
public enum S3 {
  public struct Config {
    /// e.g. http://minio.local:9000 or https://s3.us-east-1.amazonaws.com. Path-style addressing.
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var accessKey: String
    public var secretKey: String
    /// Where the bucket is readable from (e.g. https://media.example.com); nil uses endpoint/bucket.
    public var publicBase: String?
    public init(endpoint: URL, region: String = "us-east-1", bucket: String, accessKey: String, secretKey: String, publicBase: String? = nil) {
      self.endpoint = endpoint
      self.region = region
      self.bucket = bucket
      self.accessKey = accessKey
      self.secretKey = secretKey
      self.publicBase = publicBase
    }
  }

  public enum UploadError: LocalizedError {
    case http(Int, String)
    public var errorDescription: String? {
      switch self {
      case .http(let code, let body): return "Upload failed (HTTP \(code)): \(body.prefix(300))"
      }
    }
  }

  /// The object URL for a PUT (path style: endpoint/bucket/key).
  public static func objectURL(_ c: Config, key: String) -> URL {
    URL(string: c.endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + uriEncode(c.bucket) + "/" + uriEncode(key, keepSlash: true))!
  }

  /// Where viewers fetch the object.
  public static func publicURL(_ c: Config, key: String) -> URL {
    guard let base = c.publicBase?.trimmingCharacters(in: .whitespaces), !base.isEmpty else { return objectURL(c, key: key) }
    return URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + uriEncode(key, keepSlash: true))!
  }

  public static func contentType(_ url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "mp4", "m4v": return "video/mp4"
    case "mov": return "video/quicktime"
    case "gif": return "image/gif"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "srt": return "application/x-subrip"
    case "txt", "md": return "text/plain; charset=utf-8"
    default: return "application/octet-stream"
    }
  }

  /// A key that won't collide and can't be guessed from the name and time:
  /// "<name>-<time>-<8 random hex>.<ext>", lowercase, dashes for anything unusual.
  public static func key(for file: URL, name: String, date: Date = Date(), nonce: String = randomHex(4)) -> String {
    let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
      .split(separator: "-").joined(separator: "-")
    return "\(slug.isEmpty ? "video" : slug)-\(Int(date.timeIntervalSince1970))-\(nonce).\(file.pathExtension.lowercased())"
  }

  /// `bytes` random bytes as lowercase hex.
  public static func randomHex(_ bytes: Int) -> String {
    var g = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
  }

  /// PUTs a file and returns its public URL.
  public static func upload(_ file: URL, key: String, config c: Config, session: URLSession = .shared) async throws -> URL {
    let hash = try sha256Hex(file: file)
    var req = URLRequest(url: objectURL(c, key: key))
    req.httpMethod = "PUT"
    let headers = [
      "content-type": contentType(file),
      "x-amz-content-sha256": hash,
    ]
    let signed = SigV4.sign(
      method: "PUT", url: req.url!, headers: headers, payloadHash: hash, date: Date(), accessKey: c.accessKey,
      secretKey: c.secretKey, region: c.region, service: "s3")
    for (k, v) in signed.headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, response) = try await session.upload(for: req, fromFile: file)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw UploadError.http(code, String(decoding: data, as: UTF8.self)) }
    return publicURL(c, key: key)
  }

  static func sha256Hex(file: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: file)
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// AWS URI encoding: everything but A-Z a-z 0-9 - _ . ~ is percent-encoded (and "/" unless `keepSlash`).
  static func uriEncode(_ s: String, keepSlash: Bool = false) -> String {
    var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    if keepSlash { allowed.insert("/") }
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
  }
}

/// AWS Signature Version 4 (header-based), as in the S3 "Signature Calculations for the
/// Authorization Header" docs.
public enum SigV4 {
  public struct Signed {
    /// Headers to send: the ones passed in plus host, x-amz-date and authorization.
    public var headers: [String: String]
    public var canonicalRequest: String
    public var stringToSign: String
    public var signature: String
  }

  public static func sign(
    method: String, url: URL, headers: [String: String], payloadHash: String, date: Date, accessKey: String, secretKey: String,
    region: String, service: String
  ) -> Signed {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let amzDate = f.string(from: date)
    let day = String(amzDate.prefix(8))

    var all: [String: String] = [:]
    for (k, v) in headers { all[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
    var host = url.host ?? ""
    if let port = url.port, !((url.scheme == "http" && port == 80) || (url.scheme == "https" && port == 443)) { host += ":\(port)" }
    all["host"] = host
    all["x-amz-date"] = amzDate
    all["x-amz-content-sha256"] = payloadHash
    let names = all.keys.sorted()
    let signedHeaders = names.joined(separator: ";")
    let canonicalHeaders = names.map { "\($0):\(all[$0]!)\n" }.joined()

    // The path as sent (already encoded by S3.objectURL), and the query sorted by name.
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
    let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
      .map { (S3.uriEncode($0.name), S3.uriEncode($0.value ?? "")) }.sorted { $0 < $1 }
      .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    let canonicalRequest = [method, path.isEmpty ? "/" : path, query, canonicalHeaders, signedHeaders, payloadHash]
      .joined(separator: "\n")

    let scope = "\(day)/\(region)/\(service)/aws4_request"
    let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
    let key = signingKey(secret: secretKey, day: day, region: region, service: service)
    let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

    var out = all
    out["authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    return Signed(headers: out, canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature)
  }

  public static func signingKey(secret: String, day: String, region: String, service: String) -> SymmetricKey {
    func h(_ key: SymmetricKey, _ s: String) -> SymmetricKey {
      SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key)))
    }
    return h(h(h(h(SymmetricKey(data: Data("AWS4\(secret)".utf8)), day), region), service), "aws4_request")
  }

  static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
}

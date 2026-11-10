import Foundation

// Secrets on screen (Secrets.swift): what the patterns catch and leave alone, and when the edit
// shows one unblurred. The OCR scan itself is in Tests/Media.swift. Called from Checks.main.

func secretChecks() {
  func found(_ s: String) -> [String] { Secrets.matches(s).map { "\($0.kind): \(s[$0.range])" } }
  expect(found("export OPENAI_API_KEY=sk-proj-Ab12Cd34E†56Gh78") == ["api key: sk-proj-Ab12Cd34E†56Gh78"], "a key with an OCR slip is one api key")
  expect(found("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE") == ["api key: AKIAIOSFODNN7EXAMPLE"], "an AWS key")
  expect(found("Server=db;User Id=joe;Password=Hunter2!;") == ["secret: Hunter2!"], "a connection string's password, not its label")
  expect(found("\"client_secret\": \"9f8aXq2LmN\"") == ["secret: 9f8aXq2LmN"], "a JSON secret's value")
  expect(found("postgres://joe:s3cretpw@db.example.com/app") == ["password: s3cretpw"], "a URL's password, not an email")
  expect(found("mail joe@example.com today") == ["email: joe@example.com"], "an email")
  expect(found("-----BEGIN RSA PRIVATE KEY-----").first == "private key: -----BEGIN RSA PRIVATE KEY-----", "a private key")
  expect(found("token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N") .count == 1, "a JWT once")
  expect(found("XyZ9aB8cD7eF6gH5iJ4kL3mN2oP1qR0s") == ["token: XyZ9aB8cD7eF6gH5iJ4kL3mN2oP1qR0s"], "a bare random key")
  for harmless in [
    "commit 3f9a2b7c1d0e4f5a6b7c8d9e0f1a2b3c4d5e6f7a", "id 123e4567-e89b-12d3-a456-426614174000", "Password: ••••••••", "password=****",
    "Enter your password", "the_quick_brown_fox_jumps_over_lazy_dogs", "Password: <password>",
  ] {
    expect(found(harmless).isEmpty, "leaves alone: \(harmless) (\(found(harmless)))")
  }
  let statusBar = "www.linkedin.com/feed/?highlightedUpdateUrn=urn:li:activity:7521990970293407746&dashCommentUrn=Xy9aB8cD7eF6gH5iJ4kL3mN2oP1qR0sTu"
  expect(found(statusBar).isEmpty, "long IDs in a URL aren't keys (\(found(statusBar)))")
  expect(found("02934077468hiabliahtedUndateTvpe-REACTED").isEmpty, "a broken-up URL's numeric ID isn't a key")
  expect(found("https://api.example.com/v1?access_token=Zq81Lm0p") == ["secret: Zq81Lm0p"], "a labeled token in a URL still is")
  expect(Secrets.mask("sk-proj-Ab12Cd34") == "sk-p…d34" && Secrets.mask("abc") == "•••", "masks keep only the ends")

  // The same secret in the same place, read slightly differently, is one finding; a gap ends it.
  let hit = Secrets.Hit(kind: "secret", masked: "Hunt…et!", x: 0.3, y: 0.5, w: 0.2, h: 0.03)
  var wobble = hit
  wobble.masked = "Hunt…et."
  wobble.x = 0.301
  let merged = Secrets.merge([(1, [hit]), (2, [wobble]), (3, []), (4, [hit])], step: 1)
  expect(merged.count == 2 && merged[0].start == 0 && merged[0].end == 3 && merged[1].start == 3 && merged[1].end == 5, "one finding per stretch on screen (\(merged))")

  // A column of emails up together (a table) is one blur.
  let rows = (0..<5).map { Secrets.Finding(kind: "email", masked: "te_u…com", start: 8, end: 12, x: 0.6, y: 0.4 + Double($0) * 0.04, w: 0.1, h: 0.025) }
  let column = Secrets.stacked(rows + [Secrets.Finding(kind: "email", masked: "x@…om", start: 8, end: 12, x: 0.2, y: 0.4, w: 0.1, h: 0.025)])
  expect(column.count == 2 && column.contains { abs($0.y - 0.4) < 1e-9 && abs($0.h - 0.185) < 1e-9 && $0.x == 0.6 && $0.masked == "te_u…com and 4 more" }, "a column of emails is one finding (\(column))")

  // The edit shows it unblurred until a blur covers every kept moment; cut stretches don't count.
  var plan = buildPlan(
    Project(dir: URL(fileURLWithPath: "/tmp"), source: Project.Source(video: "s.mp4", width: 1920, height: 1080, duration: 20, captureStart: nil, camera: nil)))
  plan.segments = [Segment(start: 0, end: 5, speed: 1), Segment(start: 10, end: 20, speed: 1)]
  plan.annotations = nil
  let f = Secrets.Finding(kind: "api key", masked: "sk-p…d34", start: 4, end: 11, x: 0.1, y: 0.2, w: 0.3, h: 0.04)
  let cut = Secrets.Finding(kind: "email", masked: "jo…om", start: 6, end: 9, x: 0.1, y: 0.5, w: 0.2, h: 0.03)
  expect(Secrets.uncovered([f, cut], plan: plan).map(\.index) == [0], "a secret in a cut is fine, a shown one isn't")
  plan.annotations = [Annotation(start: 4, end: 5, kind: "blur", x: 0.05, y: 0.15, w: 0.4, h: 0.1)]
  expect(Secrets.uncovered([f], plan: plan).count == 1, "a blur over part of the time doesn't cover it")
  let blurs = Secrets.blurs(for: [f, cut], plan: plan)
  expect(
    blurs.count == 1 && blurs[0].enter?.preset == "none" && blurs[0].exit?.preset == "none" && blurs[0].note?.contains("sk-p…d34") == true,
    "--blur adds one hard-edged blur per shown secret (\(blurs))")
  plan.annotations! += blurs
  expect(Secrets.uncovered([f], plan: plan).isEmpty, "then nothing is shown")
  var allowed = f
  allowed.allowed = true
  plan.annotations = nil
  expect(Secrets.uncovered([allowed], plan: plan).isEmpty, "an allowed one is never flagged")
  expect(Secrets.keepingAllowed([f], from: [allowed]).first?.allowed == true, "a rescan keeps the allowed mark")
}

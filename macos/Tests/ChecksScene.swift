import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Scene drawing: captions, marks, cards, watermark, cursor and grading, checked by pixel. Called from
// Checks.main; run with macos/test.sh.
// swiftlint:disable function_body_length

/// The pixels of a rect (Core Image coordinates), row by row from the bottom, as [r, g, b] in 0...1.
private func strip(_ image: CIImage, _ rect: CGRect) -> [[Double]] {
  let w = Int(rect.width), h = Int(rect.height)
  var px = [UInt8](repeating: 0, count: 4 * w * h)
  CIContext().render(image, toBitmap: &px, rowBytes: 4 * w, bounds: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  return (0..<(w * h)).map { i in (0..<3).map { Double(px[4 * i + $0]) / 255 } }
}

private func near(_ a: [Double], _ b: [Double], _ tolerance: Double = 0.08) -> Bool {
  zip(a, b).allSatisfy { abs($0 - $1) < tolerance }
}

/// A solid-color PNG written to a temp file, for watermarks and card logos.
private func solidPNG(red: Double, green: Double, blue: Double, width: Int, height: Int) -> String {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("sd-scene-\(UUID().uuidString).png")
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
  return url.path
}

func sceneDrawingChecks() {
  let gray = [0.5, 0.5, 0.5]
  let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 12, captureStart: nil, camera: nil)
  var base = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp"), source: src))
  base.segments = [Segment(start: 0, end: 12, speed: 1)]
  base.zooms = []
  base.clickRipples = false
  base.shortcutChips = false
  let H = 1080.0
  /// A pixel in top-left coordinates, like the overlays are drawn.
  func at(_ img: CIImage, _ x: Double, _ y: Double) -> [Double] { pixel(img, x: x, y: H - y - 1) }
  func render(_ plan: Plan, frame: Int, words: [Word] = [], shortcuts: [InputEvent] = [], cursor: [InputEvent] = [], camera: CIImage? = nil) -> CIImage {
    Scene(plan: plan, words: words, clicks: [], shortcuts: shortcuts, cursorPath: cursor).render(frame: frame, screen: screen, camera: camera)
  }
  // Where a point of the recording (fractions) lands in the frame, top-left coordinates.
  let screenBox = layoutBoxes(.screen, plan: base).screen
  let map = Scene(plan: base, words: [], clicks: [], shortcuts: []).screenMap(screenBox, CameraState(scale: 1, x: 0.5, y: 0.5))
  func onScreen(_ fx: Double, _ fy: Double) -> (x: Double, y: Double) { (map.tx + map.k * fx * 1920, map.ty + map.k * fy * 1080) }
  let plain = render(base, frame: 90)
  expect(near(at(plain, 960, 540), gray, 0.02), "the plain screen card shows the screen (\(at(plain, 960, 540)))")

  // Captions: a dark pill near the bottom with the words in white; none before the words are said.
  var captioned = base
  captioned.captions = Plan.Captions(enabled: true, maxWords: 7, style: nil)
  let said = [Word(text: "hello", start: 2, end: 2.5), Word(text: "world", start: 2.6, end: 3.2)]
  let captionRow = CGRect(x: 560, y: 60, width: 800, height: 120)  // the bottom band, in Core Image coordinates
  func counts(_ img: CIImage, _ rect: CGRect) -> (dark: Int, white: Int, yellow: Int) {
    let px = strip(img, rect)
    return (px.filter { $0.max()! < 0.3 }.count, px.filter { $0.min()! > 0.9 }.count, px.filter { $0[0] > 0.85 && $0[1] > 0.75 && $0[2] < 0.3 }.count)
  }
  let withCaption = counts(render(captioned, frame: 85, words: said), captionRow)
  let beforeCaption = counts(render(captioned, frame: 30, words: said), captionRow)
  // Bold captions get a box only when asked; dragged captions draw where they were put.
  var boldCaptions = captioned
  boldCaptions.captions.style = "bold"
  let boldBare = counts(render(boldCaptions, frame: 85, words: said), captionRow)
  boldCaptions.captions.box = true
  let boldBoxed = counts(render(boldCaptions, frame: 85, words: said), captionRow)
  expect(boldBoxed.dark > boldBare.dark + 3000, "a box behind bold captions when captions.box is on (\(boldBare.dark) -> \(boldBoxed.dark))")
  var movedCaptions = captioned
  movedCaptions.captions.x = 0.3
  movedCaptions.captions.y = 0.15
  let movedFrame = render(movedCaptions, frame: 85, words: said)
  let topLeftRow = CGRect(x: 276, y: 1080 - 0.15 * 1080 - 40, width: 600, height: 80)
  let movedTop = counts(movedFrame, topLeftRow), movedBottom = counts(movedFrame, captionRow)
  expect(movedTop.white > 200 && movedBottom.white == 0 && movedBottom.dark == 0,
    "captions draw where captions.x/y put them (top \(movedTop), bottom \(movedBottom))")
  expect(Fonts.choices(nil).isEmpty, "no font choices without a look")
  // A word wider than the caption box shrinks to fit on one line instead of breaking mid-word.
  let longWord = NSMutableAttributedString(attributedString: Scene.text("CUSTOMIZABILITY", size: 92, weight: .heavy))
  longWord.append(Scene.text(" OVER", size: 92, weight: .heavy))
  let wordRanges = [NSRange(location: 0, length: 15), NSRange(location: 16, length: 4)]
  Scene.shrinkToFitWords(longWord, wordRanges, maxWidth: 600)
  let longWidth = Scene.measure(longWord.attributedSubstring(from: wordRanges[0]), maxWidth: .greatestFiniteMagnitude).width
  expect(longWidth <= 600 && longWidth > 540, "a too-wide caption word shrinks just enough to fit (\(longWidth))")
  expect(withCaption.dark > 2000 && withCaption.white > 200, "a caption pill with white words is drawn (\(withCaption))")
  expect(beforeCaption.dark == 0 && beforeCaption.white == 0, "no caption before the words are said (\(beforeCaption))")
  // Karaoke marks the word being said with a yellow box (fillMark); the plain pill has none.
  captioned.captions.style = "karaoke"
  let karaoke = counts(render(captioned, frame: 85, words: said), captionRow)
  expect(karaoke.yellow > 500 && withCaption.yellow == 0, "karaoke marks the current word (\(karaoke.yellow) yellow pixels)")
  // Word pop: a word not yet said is hidden, so the page shows less text before "world" than after it
  // (the word being said is yellow, the rest white).
  captioned.captions.style = "pop"
  func text(_ c: (dark: Int, white: Int, yellow: Int)) -> Int { c.white + c.yellow }
  let popEarly = text(counts(render(captioned, frame: 65, words: said), captionRow))
  let popLate = text(counts(render(captioned, frame: 85, words: said), captionRow))
  expect(popEarly > 50 && popLate > popEarly + 50, "word pop shows each word as it's said (\(popEarly) then \(popLate) white pixels)")

  // Typing reveal: by character it cuts mid-word, by word it shows whole words; hidden text keeps its place.
  let line = Scene.text("one two three four", size: 40, weight: .bold)
  func hiddenFrom(_ s: NSAttributedString) -> Int {
    let key = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    for i in 0..<s.length {
      // swiftlint:disable:next force_cast
      if let c = s.attribute(key, at: i, effectiveRange: nil), (c as! CGColor).alpha == 0 { return i }
    }
    return s.length
  }
  let byChar = Scene.revealed(line, share: 0.5, byWord: false), byWord = Scene.revealed(line, share: 0.5, byWord: true)
  expect(hiddenFrom(byChar) == 9 && byChar.string == line.string, "half by character hides from character 9 (\(hiddenFrom(byChar)))")
  expect(hiddenFrom(byWord) == 8, "half by word shows \"one two \" (\(hiddenFrom(byWord)))")
  expect(hiddenFrom(Scene.revealed(line, share: 1, byWord: true)) == line.length, "a full share shows everything")

  // Titles: the default title is a dark pill at the top; a lower third has its accent bar at the left;
  // a typewriter title shows fewer letters early than when it's done.
  var titled = base
  titled.callouts = [Callout(start: 1, end: 5, text: "A title")]
  let titleBand = CGRect(x: 760, y: H - 160, width: 400, height: 110)
  let titleNow = counts(render(titled, frame: 90), titleBand), titleGone = counts(render(titled, frame: 200), titleBand)
  expect(titleNow.dark > 2000 && titleNow.white > 100, "a title pill is drawn at the top (\(titleNow))")
  expect(titleGone.dark == 0, "the title is gone after its end (\(titleGone))")
  titled.callouts = [Callout(start: 1, end: 5, text: "Lower third", style: "lower-third")]
  let barColor = at(render(titled, frame: 90), 92, H * 0.74 - 30)
  expect(near(barColor, [0.47, 0.63, 1], 0.06), "a lower third has the accent bar at its left (\(barColor))")
  titled.callouts = [Callout(start: 1, end: 5, text: "Typing this title out", enter: Motion(preset: "typewriter", seconds: 2))]
  let typedEarly = counts(render(titled, frame: 45), titleBand).white, typedDone = counts(render(titled, frame: 120), titleBand).white
  expect(typedEarly < typedDone - 50, "a typewriter title types in (\(typedEarly) then \(typedDone) white pixels)")

  // Key chips: a dark pill with the shortcut, low in the frame, for 1.2 s.
  var chipped = base
  chipped.shortcutChips = true
  let keys = [InputEvent(t: 2, type: .key, x: 0.5, y: 0.5, label: "⌘K")]
  let chipBand = CGRect(x: 860, y: H * 0.2, width: 200, height: 90)
  let chipNow = counts(render(chipped, frame: 70, shortcuts: keys), chipBand), chipLater = counts(render(chipped, frame: 120, shortcuts: keys), chipBand)
  expect(chipNow.dark > 1000 && chipNow.white > 50 && chipLater.dark == 0, "a key chip shows briefly (\(chipNow), then \(chipLater))")

  // Annotations on the middle of the screen: (0.4, 0.4, 0.2, 0.2).
  let markTL = onScreen(0.4, 0.4), markBR = onScreen(0.6, 0.6)
  let markMid = onScreen(0.5, 0.5)
  func marked(_ kind: String, text: String? = nil) -> (shown: CIImage, before: CIImage) {
    var p = base
    p.annotations = [Annotation(start: 2, end: 6, kind: kind, x: 0.4, y: 0.4, w: 0.2, h: 0.2, text: text)]
    return (render(p, frame: 120), render(p, frame: 30))
  }
  let spot = marked("spotlight")
  let away = onScreen(0.1, 0.1)
  let dimmed = at(spot.shown, away.x, away.y), lit = at(spot.shown, markMid.x, markMid.y)
  expect(dimmed[0] < 0.4 && near(lit, gray, 0.02), "a spotlight dims around the mark only (\(dimmed), \(lit))")
  expect(near(at(spot.before, away.x, away.y), gray, 0.02), "no spotlight before its start")
  let marker = marked("highlight").shown
  let tinted = at(marker, markMid.x, markMid.y)
  expect(tinted[0] > 0.6 && tinted[0] > tinted[2] + 0.2, "a highlight tints the mark yellow (\(tinted))")
  let boxed = marked("box", text: "Here").shown
  let edge = at(boxed, markTL.x - 6, markMid.y)
  expect(edge[0] > 0.85 && edge[2] < 0.3 && near(at(boxed, markMid.x, markMid.y), gray, 0.02), "a box outlines the mark and leaves its inside (\(edge))")
  let label = counts(boxed, CGRect(x: markTL.x, y: H - markTL.y + 20, width: 60, height: 25))
  expect(label.yellow > 500, "a box's label sits on a yellow tag above it (\(label))")
  let arrowed = marked("arrow", text: "Click").shown
  let tip = (x: markMid.x, y: markBR.y + 4)
  let shaft = at(arrowed, tip.x + 55, tip.y + 65)
  expect(shaft[0] > 0.85 && shaft[2] < 0.3, "an arrow points up at the mark from below right (\(shaft))")
  expect(near(at(arrowed, tip.x - 55, tip.y + 65), gray, 0.02), "and nothing on the other side")
  // Near the right edge, the arrow comes from the left instead.
  var rightArrow = base
  rightArrow.annotations = [Annotation(start: 2, end: 6, kind: "arrow", x: 0.85, y: 0.4, w: 0.1, h: 0.2)]
  let rightTip = onScreen(0.9, 0.6)
  let leftShaft = at(render(rightArrow, frame: 120), rightTip.x - 55, rightTip.y + 4 + 65)
  expect(leftShaft[0] > 0.85 && leftShaft[2] < 0.3, "an arrow near the right edge comes from the left (\(leftShaft))")

  // The drawn cursor: a white arrow with its tip on the pointer, gone when hidden.
  let pointer = (0..<20).map { InputEvent(t: Double($0) * 0.5, type: .move, x: 0.5, y: 0.5) }
  // The arrow is 32 px tall at 1080p, drawn in 54-unit steps; (6, 30) is inside its body.
  let body = (x: markMid.x + 6 * 32 / 54, y: markMid.y + 30 * 32 / 54)
  let arrowBody = at(render(base, frame: 90, cursor: pointer), body.x, body.y)
  expect(arrowBody.min()! > 0.9, "the cursor is drawn at the pointer (\(arrowBody))")
  expect(near(at(render(base, frame: 90), body.x, body.y), gray, 0.02), "no pointer data, no cursor")
  var hidden = base
  hidden.cursor = CursorSettings(hidden: true)
  expect(near(at(render(hidden, frame: 90, cursor: pointer), body.x, body.y), gray, 0.02), "a hidden cursor isn't drawn")

  // Brackets: the accent corners sit just outside the screen card (a 12 px stroke centered 16 px out).
  var bracketed = base
  bracketed.look = Look()
  bracketed.look?.frame = "brackets"
  let arm = (x: screenBox.x - 16, y: screenBox.y - 16 + 60)
  let corner = at(render(bracketed, frame: 90), arm.x, arm.y), bare = at(plain, arm.x, arm.y)
  expect(near(corner, [1, 0.9, 0], 0.08) && !near(bare, [1, 0.9, 0], 0.3), "brackets draw at the card's corner (\(corner), was \(bare))")

  // Window frame: a dark title bar with dots over the padded screen card, which moves down to make room.
  var padded = base
  padded.style.padding = 0.06
  var windowed = padded
  windowed.look = Look()
  windowed.look?.frame = "window"
  let bar = windowBarHeight(windowed)
  let framed = layoutBoxes(.screen, plan: windowed).screen
  expect(bar > 0 && framed.y > layoutBoxes(.screen, plan: padded).screen.y, "a window frame leaves room for its bar (\(bar), \(framed.y))")
  let windowFrame = render(windowed, frame: 90)
  let barPixel = at(windowFrame, framed.x + framed.w / 2, framed.y - bar / 2)
  expect(near(barPixel, [0.102, 0.114, 0.141], 0.03), "the window bar is drawn over the card (\(barPixel))")
  let dot = at(windowFrame, framed.x + bar * 0.6, framed.y - bar / 2)
  expect(near(dot, [0.29, 0.3, 0.33], 0.04), "the window bar has its dots (\(dot))")
  var bleed = windowed
  bleed.style.padding = 0
  expect(windowBarHeight(bleed) == 0, "full bleed has no window bar")
  // Joined side by side: the camera starts where the screen ends, at the same height.
  var joinedSide = windowed
  joinedSide.style.joinSide = true
  let side = layoutBoxes(.side, plan: joinedSide)
  expect(
    abs(side.cam.x - (side.screen.x + side.screen.w)) < 0.5 && side.cam.y == side.screen.y && side.cam.h == side.screen.h,
    "joined side by side has no gap (\(side))")

  // Fill the frame: with no padding the screen covers the whole square frame (it shows whole, with
  // background above and below, without it); portrait keeps its split.
  var squareFill = ExportPreset.all.first { $0.id == "square" }!.applied(to: base)
  squareFill.style.padding = 0
  let fitted = layoutBoxes(.pip, plan: squareFill).screen
  squareFill.style.fill = true
  let filled = layoutBoxes(.pip, plan: squareFill).screen
  expect(fitted.h < 1080 && filled.x == 0 && filled.y == 0 && filled.w == 1080 && filled.h == 1080, "fill covers the frame (\(fitted) -> \(filled))")
  expect(cropsScreen(squareFill), "a filled screen pans like a cropped one")
  let sideFilled = layoutBoxes(.side, plan: squareFill)
  expect(sideFilled.screen.h == 1080 && sideFilled.screen.x + sideFilled.screen.w == sideFilled.cam.x, "fill covers the screen's side of side by side (\(sideFilled))")
  var verticalFill = ExportPreset.all.first { $0.id == "vertical" }!.applied(to: base)
  verticalFill.style.padding = 0
  verticalFill.style.fill = true
  expect(!fillsFrame(verticalFill), "portrait keeps its own split")

  // Watermark: the logo in the margin's bottom-right by default; full bleed puts it inside the frame's corner.
  let red = solidPNG(red: 1, green: 0, blue: 0, width: 200, height: 100)
  defer { try? FileManager.default.removeItem(atPath: red) }
  var stamped = base
  stamped.look = Look()
  stamped.look?.watermark = Look.Watermark(image: red, corner: nil, height: nil, opacity: 1)
  let stampedFrame = render(stamped, frame: 90)
  let mark = at(stampedFrame, 1817, 1047)
  expect(near(mark, [1, 0, 0], 0.05), "the watermark sits in the bottom-right margin (\(mark))")
  expect(!near(at(stampedFrame, 103, 1047), [1, 0, 0], 0.3), "and not in the other corner")
  stamped.style.padding = 0
  stamped.look?.watermark?.corner = "topLeft"
  let topLeft = at(render(stamped, frame: 90), 80, 61)
  expect(near(topLeft, [1, 0, 0], 0.05), "full bleed puts it in the chosen corner (\(topLeft))")

  // Dark or light background decides the card's text color.
  var light = base
  light.style.background = ["#ffffff", "#eeeeee"]
  expect(Scene(plan: base, words: [], clicks: [], shortcuts: []).darkBackground, "the default background counts as dark")
  expect(!Scene(plan: light, words: [], clicks: [], shortcuts: []).darkBackground, "a white background is light")

  // Intro and outro cards: title, accent bar and logo on the background, text fading out at the
  // intro's end and in at the outro's start.
  var carded = base
  carded.intro = Card(title: "Hello", subtitle: "World", logo: red)
  carded.outro = Card(title: "Bye")
  let cardScene = Scene(plan: carded, words: [], clicks: [], shortcuts: [])
  func column(_ img: CIImage) -> [[Double]] { strip(img, CGRect(x: 960, y: 0, width: 1, height: 1080)) }
  let accent = [0.47, 0.63, 1.0]
  let introFirst = column(cardScene.render(frame: 0, screen: screen, camera: nil))
  let introLast = column(cardScene.render(frame: cardScene.introFrames - 1, screen: screen, camera: nil))
  expect(introFirst.contains { near($0, accent, 0.05) } && introFirst.contains { near($0, [1, 0, 0], 0.05) }, "the intro shows its accent bar and logo")
  expect(introFirst.contains { $0.min()! > 0.95 }, "the intro's title is white on the dark background")
  expect(!introLast.contains { near($0, accent, 0.05) } && !introLast.contains { near($0, [1, 0, 0], 0.1) }, "the intro's text fades out at its end")
  let outroFirst = column(cardScene.render(frame: cardScene.outroStart, screen: screen, camera: nil))
  let outroLater = column(cardScene.render(frame: cardScene.frameCount - 1, screen: screen, camera: nil))
  expect(!outroFirst.contains { near($0, accent, 0.05) } && outroLater.contains { near($0, accent, 0.05) }, "the outro's text fades in")
  var lightCard = carded
  lightCard.style.background = ["#ffffff", "#ffffff"]
  let lightIntro = column(Scene(plan: lightCard, words: [], clicks: [], shortcuts: []).render(frame: 0, screen: screen, camera: nil))
  expect(lightIntro.contains { $0.max()! < 0.15 }, "a light background gets dark title text")

  // Camera: the bubble shows the camera picture, graded when the plan grades it.
  var filmed = base
  filmed.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  filmed.defaultLayout = .pip
  let bubbleBox = layoutBoxes(.pip, plan: filmed).cam
  let bubbleCenter = (bubbleBox.x + bubbleBox.w / 2, bubbleBox.y + bubbleBox.h / 2)
  let green = CIImage(color: CIColor(red: 0.2, green: 0.7, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
  let inBubble = at(render(filmed, frame: 90, camera: green), bubbleCenter.0, bubbleCenter.1)
  expect(near(inBubble, [0.2, 0.7, 0.3], 0.03), "the bubble shows the camera (\(inBubble))")
  filmed.camera?.grade = Grade(saturation: 0)
  let graded = at(render(filmed, frame: 90, camera: green), bubbleCenter.0, bubbleCenter.1)
  expect(graded.max()! - graded.min()! < 0.03, "a saturation 0 grade makes the camera black and white (\(graded))")
  // Mirror: a camera red on its left half and blue on its right shows blue on the left when flipped.
  var talking = base
  talking.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  talking.defaultLayout = .camera
  let redBlue = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 720))
    .composited(over: CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)))
  let leftPlain = at(render(talking, frame: 90, camera: redBlue), 200, 540)
  talking.camera?.mirror = true
  let leftMirrored = at(render(talking, frame: 90, camera: redBlue), 200, 540)
  expect(near(leftPlain, [0.9, 0.1, 0.1]) && near(leftMirrored, [0.1, 0.1, 0.9]), "mirror flips the camera (\(leftPlain) -> \(leftMirrored))")
  // A punch-in with a framing point cuts to that side of the camera (in file coordinates, so mirrored too).
  talking.camera?.mirror = nil
  talking.camera?.punchIns = [PunchIn(start: 2, end: 4, scale: 2)]
  talking.camera?.punchIns?[0].x = 0.85
  let toRight = at(render(talking, frame: 90, camera: redBlue), 960, 540)
  talking.camera?.punchIns?[0].x = 0.15
  let toLeft = at(render(talking, frame: 90, camera: redBlue), 960, 540)
  talking.camera?.mirror = true
  let toLeftMirrored = at(render(talking, frame: 90, camera: redBlue), 960, 540)
  expect(near(toRight, [0.1, 0.1, 0.9]) && near(toLeft, [0.9, 0.1, 0.1]) && near(toLeftMirrored, [0.9, 0.1, 0.1]),
    "a punch-in's framing point moves the camera (\(toRight), \(toLeft), mirrored \(toLeftMirrored))")
  talking.camera?.punchIns?[0].scale = 0.5
  talking.camera?.zoom = 1.5
  let widened = Scene(plan: talking, words: [], clicks: [], shortcuts: []).cameraFraming(layoutBoxes(.camera, plan: talking).cam, frame: 90, cameraWidth: 1280, cameraHeight: 720).zoom
  expect(widened == 1, "a punch-in below 1 widens the framing, never past the whole camera (\(widened))")
  let mid = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
  let brighter = pixel(Scene.graded(mid, Grade(exposure: 1)), x: 4, y: 4), darker = pixel(Scene.graded(mid, Grade(exposure: -1)), x: 4, y: 4)
  expect(brighter[1] > 0.5 && darker[1] < 0.3, "exposure brightens and darkens (\(brighter[1]), \(darker[1]))")
  let warm = pixel(Scene.graded(mid, Grade(warmth: 1)), x: 4, y: 4), cool = pixel(Scene.graded(mid, Grade(warmth: -1)), x: 4, y: 4)
  expect(warm[0] > warm[2] + 0.05 && cool[2] > cool[0] + 0.05, "warmth pushes toward red, coolness toward blue (\(warm), \(cool))")
  let flat = pixel(Scene.graded(CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7)).cropped(to: mid.extent), Grade(contrast: 0)), x: 4, y: 4)
  expect(flat.max()! - flat.min()! < 0.3 && Scene.graded(mid, nil) === mid, "contrast 0 flattens; no grade leaves the picture alone (\(flat))")
  // Highlights pull the bright side of a picture down, shadows lift the dark side.
  let halves = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    .composited(over: CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64)))
  let bright = pixel(halves, x: 16, y: 32)[1], dark = pixel(halves, x: 112, y: 32)[1]
  let tamed = pixel(Scene.graded(halves, Grade(highlights: -1)), x: 16, y: 32)[1]
  let lifted = pixel(Scene.graded(halves, Grade(shadows: 1)), x: 112, y: 32)[1]
  expect(tamed < bright - 0.03 && lifted > dark + 0.03, "highlights darken the bright side, shadows lift the dark (\(bright)→\(tamed), \(dark)→\(lifted))")
  // Vibrance boosts a muted color more than one that's already strong.
  func spread(_ c: [Double]) -> Double { c.max()! - c.min()! }
  let muted = CIImage(color: CIColor(red: 0.5, green: 0.45, blue: 0.4)).cropped(to: mid.extent)
  let strong = CIImage(color: CIColor(red: 0.9, green: 0.3, blue: 0.1)).cropped(to: mid.extent)
  let mutedGain = spread(pixel(Scene.graded(muted, Grade(vibrance: 1)), x: 4, y: 4)) / spread(pixel(muted, x: 4, y: 4))
  let strongGain = spread(pixel(Scene.graded(strong, Grade(vibrance: 1)), x: 4, y: 4)) / spread(pixel(strong, x: 4, y: 4))
  expect(mutedGain > 1.1 && mutedGain > strongGain, "vibrance favors muted colors (\(mutedGain) vs \(strongGain))")
  // A .cube LUT: an inverting 2x2x2 table turns the gray's complement, from a file in the project.
  let lutDir = FileManager.default.temporaryDirectory.appendingPathComponent("lut-check-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: lutDir.appendingPathComponent("luts"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: lutDir) }
  var cube = "TITLE \"invert\"\n# comment\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
  for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
  try? cube.write(to: lutDir.appendingPathComponent("luts/invert.cube"), atomically: true, encoding: .utf8)
  func lutScene(_ path: String) -> Scene {
    var p = base
    p.camera = Plan.Camera(video: "camera.mov", offset: 0)
    p.camera?.grade = Grade(lut: path)
    return Scene(plan: p, words: [], clicks: [], shortcuts: [], dir: lutDir)
  }
  let invertScene = lutScene("luts/invert.cube")
  // Read once when the scene is built, so deleting the file afterwards doesn't change frames.
  try? FileManager.default.removeItem(at: lutDir.appendingPathComponent("luts/invert.cube"))
  let inverted = pixel(Scene.graded(CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8)).cropped(to: mid.extent), Grade(lut: "luts/invert.cube"), lut: invertScene.cameraLUT), x: 4, y: 4)
  expect(near(inverted, [0.8, 0.5, 0.2], 0.04), "a LUT recolors the camera (\(inverted))")
  // A watermark (and so the card logos) named relative to the project loads from the project folder.
  let logoCtx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  try? Publish.writePNG(logoCtx.makeImage()!, to: lutDir.appendingPathComponent("logo.png"))
  var marked = base
  marked.look = Look()
  marked.look?.watermark = Look.Watermark(image: "logo.png")
  expect(Scene(plan: marked, words: [], clicks: [], shortcuts: [], dir: lutDir).watermark != nil, "a relative watermark loads from the project folder")
  let goneScene = lutScene("luts/gone.cube")
  let missing = pixel(Scene.graded(mid, Grade(lut: "luts/gone.cube"), lut: goneScene.cameraLUT), x: 4, y: 4)
  expect(goneScene.cameraLUT == nil && near(missing, [0.4, 0.4, 0.4], 0.01), "a missing LUT leaves the picture alone (\(missing))")
  for (bad, why) in [
    ("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n", "1D"), ("LUT_3D_SIZE 2\n0 0 0\n", "needs 8"), ("0 0 0\n", "no LUT_3D_SIZE"),
    ("LUT_3D_SIZE 2\nDOMAIN_MAX 2 2 2\n", "0...1 domain"), ("LUT_3D_SIZE 2\nred green blue\n", "unreadable"),
  ] {
    do {
      _ = try CubeLUT.parse(bad, name: "bad.cube")
      expect(false, "a broken LUT (\(why)) is refused")
    } catch {
      expect(error.localizedDescription.contains(why), "a broken LUT says why: \(error.localizedDescription)")
    }
  }

  // White balance pre-flight: a gray wall with a skin-colored face, read before recording. The
  // face is ignored (skin is warm in any light), and the suggested Warmth undoes the cast.
  let room = CGRect(x: 0, y: 0, width: 320, height: 180)
  let face = CIImage(color: CIColor(red: 0.85, green: 0.6, blue: 0.48)).cropped(to: CGRect(x: 110, y: 30, width: 100, height: 120))
  let wall = face.composited(over: CIImage(color: CIColor(red: 0.55, green: 0.55, blue: 0.55)).cropped(to: room))
  let balanced = WhiteBalance.measure(wall)
  expect(balanced?.isNeutral == true && balanced?.advice == "Looks neutral.", "a gray wall reads as neutral (\(String(describing: balanced)))")
  for (cast, word) in [(0.4, "Runs warm"), (-0.4, "Runs cool")] {
    let filmed = Scene.graded(wall, Grade(warmth: cast))
    let reading = WhiteBalance.measure(filmed)
    let fixed = reading.flatMap { WhiteBalance.measure(Scene.graded(filmed, Grade(warmth: $0.fixWarmth))) }
    expect(
      (reading?.fixWarmth ?? 0) * cast < 0 && reading?.advice.contains(word) == true && reading?.advice.contains("in the edit neutralizes") == true
        && fixed?.isNeutral == true,
      "a \(cast) Warmth cast is read as \(word), and its suggested Warmth neutralizes it (\(String(describing: reading)), after: \(String(describing: fixed)))")
  }
  let redLamp = WhiteBalance.measure(Scene.graded(Scene.graded(wall, Grade(warmth: 1)), Grade(warmth: 1)))
  expect(
    redLamp?.fixWarmth == -1 && redLamp?.advice.contains("Too strong") == true && redLamp?.advice.contains("in the edit neutralizes") == false,
    "a cast past Warmth's range says the edit can't fully undo it, not to set Warmth -1 (\(String(describing: redLamp)))")
  let fluorescent = WhiteBalance.measure(wall.applyingFilter("CIColorMatrix", parameters: ["inputGVector": CIVector(x: 0, y: 1.2, z: 0, w: 0)]))
  expect((fluorescent?.tint ?? 0) > WhiteBalance.Reading.tintTolerance && fluorescent?.advice.contains("green") == true, "a green cast is read as green (\(String(describing: fluorescent)))")
  expect(WhiteBalance.measure(CIImage(color: .black).cropped(to: room)) == nil, "a black frame (lens cap, no light) has nothing to judge")

  // Cutout with no one in the frame: the background is removed, so nothing of the camera shows.
  let empty = Scene.personCutout(green)
  let leftOver = empty.extent.isEmpty ? [0.0, 0, 0] : pixel(empty.composited(over: CIImage(color: .black).cropped(to: green.extent)), x: 640, y: 360)
  expect(leftOver.max()! < 0.05, "a cutout of an empty room keeps nothing (\(leftOver))")

  // A flash cut whites out the frame on the cut and is gone a few frames later.
  var flashy = base
  flashy.segments = [Segment(start: 0, end: 4, speed: 1), Segment(start: 6, end: 12, speed: 1, transition: "flash")]
  let onCut = at(render(flashy, frame: 120), 960, 540), afterCut = at(render(flashy, frame: 140), 960, 540)
  expect(onCut.min()! > 0.9 && near(afterCut, gray, 0.02), "a flash cut flashes on the cut only (\(onCut), \(afterCut))")
}
// swiftlint:enable function_body_length

import CoreImage
import Foundation

// Vertical covers (Publish.verticalThumbnail): 1080x1920, the title big at the top with its last
// line on the chip, the camera frame filling the bottom, flipped when the camera is. Called from
// Checks.main; run with macos/test.sh.

func coverChecks() {
  let (lines, size) = Publish.coverTitle("How to jailbreak your old Kindle", font: nil, maxWidth: 888)
  expect(lines.last == "KINDLE" || lines.last?.hasSuffix("KINDLE") == true, "the cover title ends on the last word (\(lines))")
  expect(lines.count <= 4 && size >= 90 && lines.allSatisfy { $0 == $0.uppercased() }, "the cover title is big, uppercase, at most four lines (\(lines), \(size))")

  // A camera frame: red on the left half, blue on the right.
  let w = 1920, h = 1080
  let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
  ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1))
  ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
  let frame = ctx.makeImage()!

  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 10, captureStart: nil, camera: nil)
  var plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-cover"), source: src))
  plan.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  func px(_ img: CGImage, _ x: Double, _ yDown: Double) -> [Double] { pixel(CIImage(cgImage: img), x: x, y: Double(img.height) - yDown - 1) }

  // Framed on a face at the left: the bottom shows the left (red) side; the top is the dark title area.
  guard let cover = Publish.verticalThumbnail(plan: plan, person: frame, faceX: 0.2, title: "How to jailbreak your old Kindle") else {
    expect(false, "the vertical cover renders")
    return
  }
  expect(cover.width == 1080 && cover.height == 1920, "the cover is 1080x1920 (\(cover.width)x\(cover.height))")
  let bottom = px(cover, 540, 1800), top = px(cover, 1000, 60)
  expect(bottom[0] > 0.7 && bottom[2] < 0.3, "the photo is framed on the face's side (\(bottom))")
  expect(top.max()! < 0.15, "the title area is dark (\(top))")
  // A mirrored camera shows the frame flipped, and the face where the video shows it.
  plan.camera?.mirror = true
  let flipped = Publish.verticalThumbnail(plan: plan, person: frame, faceX: 0.2, title: "Kindle")!
  let fb = px(flipped, 540, 1800)
  expect(fb[0] > 0.7 && fb[2] < 0.3, "a mirrored cover flips the frame and keeps the face in view (\(fb))")

  // Landscape: the title on the dark left, the photo on the right framed on the face.
  plan.camera?.mirror = nil
  if let wide = Publish.landscapeThumbnail(plan: plan, person: frame, faceX: 0.8, title: "How to jailbreak your old Kindle") {
    expect(wide.width == 1280 && wide.height == 720, "the landscape thumbnail is 1280x720")
    let right = px(wide, 1100, 360), left = px(wide, 20, 20)
    expect(right[2] > 0.7 && right[0] < 0.3, "the photo is framed on the face's side (\(right))")
    expect(left.max()! < 0.15, "the title side is dark (\(left))")
  } else {
    expect(false, "the landscape thumbnail renders")
  }

  // Split: B-roll (green) on the top half, the camera framed on the face below, the title on an
  // accent bar across the seam.
  let greenCtx = CGContext(
    data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  greenCtx.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.1, alpha: 1))
  greenCtx.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
  var barLook = Look()
  barLook.titleBackground = "#FF4FD8"
  plan.look = barLook
  if let split = Publish.verticalThumbnail(plan: plan, person: frame, faceX: 0.8, faceY: 0.4, faceWidth: 0.1, subject: greenCtx.makeImage()!, title: "3D printed plant rack") {
    let up = px(split, 540, 300), seam = px(split, 45, 960), low = px(split, 540, 1700)
    expect(up[1] > 0.7 && up[0] < 0.3, "the B-roll fills the top half (\(up))")
    expect(seam[0] > 0.9 && seam[2] > 0.7 && seam[1] < 0.5, "the title bar crosses the seam in the accent (\(seam))")
    expect(low[2] > 0.7 && low[0] < 0.3, "the camera fills the bottom half framed on the face (\(low))")
  } else {
    expect(false, "the split cover renders")
  }
  plan.look = nil

  // Cover faces: a face cut off by the edge, turned away or crowding the top scores below a clear one.
  let clear = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.3)
  let base = Publish.faceScore(quality: 0.6, box: clear, smiling: false, blinking: false, yaw: 0)
  func score(_ box: CGRect, yaw: Double = 0) -> Double { Publish.faceScore(quality: 0.6, box: box, smiling: false, blinking: false, yaw: yaw) }
  expect(score(CGRect(x: 0.8, y: 0.3, width: 0.3, height: 0.3)) < base - 0.5, "a face cut off by the edge scores low")
  expect(score(clear, yaw: 0.6) < base, "a turned face scores lower")
  expect(score(CGRect(x: 0.35, y: 0.6, width: 0.3, height: 0.3)) < base, "a face crowding the top scores lower")
  // Under full-frame B-roll the camera isn't seen, so its frames aren't cover candidates.
  var hidden = plan
  hidden.inserts = [Insert(start: 2, end: 4, file: "broll/a.mov", placement: "full")]
  expect(Publish.cameraHidden(hidden, at: 3) && !Publish.cameraHidden(hidden, at: 5), "the camera is hidden only under full-frame B-roll")
  // Sharpness: a striped frame is sharper than a flat one.
  let striped = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
  striped.setFillColor(gray: 0, alpha: 1)
  striped.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
  striped.setFillColor(gray: 1, alpha: 1)
  for x in stride(from: 0, to: 400, by: 8) { striped.fill(CGRect(x: x, y: 0, width: 4, height: 200)) }
  expect(Publish.sharpness(striped.makeImage()!) > Publish.sharpness(greenCtx.makeImage()!) + 100, "detail scores sharper than a flat frame")

  // Picked cover moments: a second apart or replaced, the three most recent kept.
  var picks = plan
  for t in [4.8, 5.2, 30, 62, 85] { picks.addCover(at: t) }
  expect(picks.coverAt == [30, 62, 85], "covers keep the three latest picks, a near-duplicate replacing the earlier one (\(picks.coverAt ?? []))")
  picks.addCover(at: 30.4)
  expect(picks.coverAt == [62, 85, 30.4], "picking near an existing cover replaces it (\(picks.coverAt ?? []))")
}

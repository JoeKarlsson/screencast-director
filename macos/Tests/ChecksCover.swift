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

  // Picked cover moments: a second apart or replaced, the three most recent kept.
  var picks = plan
  for t in [4.8, 5.2, 30, 62, 85] { picks.addCover(at: t) }
  expect(picks.coverAt == [30, 62, 85], "covers keep the three latest picks, a near-duplicate replacing the earlier one (\(picks.coverAt ?? []))")
  picks.addCover(at: 30.4)
  expect(picks.coverAt == [62, 85, 30.4], "picking near an existing cover replaces it (\(picks.coverAt ?? []))")
}

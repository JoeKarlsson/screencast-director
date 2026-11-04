import CoreImage
import Foundation

// Vertical videos keep titles, chips, captions and animation content clear of the apps' own UI
// (SafeArea). Called from Checks.main; run with macos/test.sh.

func safeAreaChecks() {
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 12, captureStart: nil, camera: nil)
  var wide = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp"), source: src))
  wide.segments = [Segment(start: 0, end: 12, speed: 1)]
  wide.zooms = []
  wide.clickRipples = false
  wide.shortcutChips = false
  wide.captions.enabled = false
  var tall = wide
  tall.output = Plan.Output(width: 1080, height: 1920, fps: 30)
  tall.style.screenAspect = 1

  // The shift moves something into the area and leaves what's already inside alone.
  let high = CGRect(x: 100, y: 40, width: 400, height: 80)
  expect(SafeArea.shift(high, plan: tall) == CGSize(width: 0, height: 1920 * SafeArea.top - 40), "a title near the top moves below the apps' tabs")
  expect(SafeArea.shift(CGRect(x: 100, y: 600, width: 400, height: 80), plan: tall) == .zero, "a title already inside stays put")
  expect(SafeArea.shift(CGRect(x: 900, y: 600, width: 160, height: 80), plan: tall).width < 0, "something under the right-hand buttons moves left")
  expect(SafeArea.shift(high, plan: wide) == .zero, "landscape isn't moved: the apps don't cover it")

  // A step chip on a vertical video is drawn below the tabs, not at the top of the screen card.
  // The chip is pure red; the screen is gray.
  tall.look = Look()
  tall.look?.titleBackground = "#FF0000"
  tall.callouts = [Callout(start: 1, end: 9, text: "Jailbreak it", style: "chapter", subtitle: "Step 1")]
  let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
  let frame = Scene(plan: tall, words: [], clicks: [], shortcuts: []).render(frame: 150, screen: screen, camera: nil)
  func redRows(_ from: Double, _ to: Double) -> Int {
    stride(from: from, to: to, by: 8).filter { y in
      stride(from: 80.0, to: 700, by: 40).contains { x in
        let p = pixel(frame, x: x, y: 1920 - y - 1)
        return p[0] > 0.9 && p[1] < 0.15 && p[2] < 0.15
      }
    }.count
  }
  expect(redRows(0, 1920 * SafeArea.top) == 0, "nothing of the step chip is under the apps' tabs (\(redRows(0, 1920 * SafeArea.top)) rows)")
  expect(redRows(1920 * SafeArea.top, 1920 * 0.3) > 0, "the step chip is drawn just below them")

  // Animations in a vertical video keep their top clear; landscape ones use the whole clip.
  expect(tall.animationSafeTop > 0, "a vertical video's animations start below the apps' tabs (\(tall.animationSafeTop) px)")
  expect(wide.animationSafeTop == 0, "a landscape video's animations use the whole frame")
  let anim = Animation(start: 1, end: 5, template: "hub", data: .object([:]))
  expect(anim.clipPath(tall.animationOutput, dir: nil, safeTop: 120) != anim.clipPath(tall.animationOutput, dir: nil),
    "a clip kept clear at the top is a different clip")
}

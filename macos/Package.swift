// swift-tools-version:6.0
// The macOS app. Build the .app with macos/build.sh; `swift build` alone only makes the binaries.
import PackageDescription

let package = Package(
  name: "ScreencastDirector",
  platforms: [.macOS(.v15)],
  targets: [
    // Plan model, timeline math, planner, analysis and the renderer. No AppKit or SwiftUI,
    // so macos/test.sh can compile it with plain swiftc (Swift Testing needs Xcode).
    .target(name: "DirectorCore", path: "Sources/DirectorCore"),
    // Headless CLI: analyze, plan, describe, render. Bundled in the app so Claude can run it.
    .executableTarget(name: "director", dependencies: ["DirectorCore"], path: "Sources/director"),
    .executableTarget(name: "ScreencastDirector", dependencies: ["DirectorCore"], path: "Sources/ScreencastDirector"),
  ],
  swiftLanguageModes: [.v5]
)

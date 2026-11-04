import Foundation

// Camera capture format: which of a camera's formats the recorder picks, and its bitrate. Called from
// Checks.main; run with macos/test.sh.

func cameraFormatChecks() {
  typealias Opt = CameraFormat.Option
  // An OBSBOT-like camera: 4K at 30, 1080p at 60, and a 4K format that only does 15 fps.
  let obsbot = [Opt(width: 1920, height: 1080, maxFPS: 60), Opt(width: 3840, height: 2160, maxFPS: 30), Opt(width: 3840, height: 2160, maxFPS: 15)]
  expect(CameraFormat.best(obsbot) == 1, "a 4K camera records in 4K at 30 fps, not 1080p")
  expect(CameraFormat.best([Opt(width: 3840, height: 2160, maxFPS: 15), Opt(width: 1920, height: 1080, maxFPS: 30)]) == 1, "a 4K format below 30 fps is skipped")
  expect(CameraFormat.best([Opt(width: 7680, height: 4320, maxFPS: 30), Opt(width: 3840, height: 2160, maxFPS: 30)]) == 1, "nothing bigger than 4K")
  expect(CameraFormat.best([Opt(width: 1920, height: 1080, maxFPS: 30), Opt(width: 1920, height: 1080, maxFPS: 60)]) == 1, "same size: the higher frame rate")
  expect(CameraFormat.best([Opt(width: 640, height: 480, maxFPS: 15)]) == nil, "no 30 fps format keeps the camera's own")
  expect(CameraFormat.bitrate(width: 1920, height: 1080) == 12_000_000, "1080p keeps 12 Mbps")
  expect(CameraFormat.bitrate(width: 3840, height: 2160) == 40_000_000, "4K gets 40 Mbps")
}

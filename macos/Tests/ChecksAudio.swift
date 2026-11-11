import AVFoundation
import CoreImage
import Foundation

// Audio processing: music ducking, the gain tap and voice cleanup. Called from Checks.main; run with macos/test.sh.

/// Runs async work from the synchronous checks.
func blocking<T>(_ body: @escaping () async throws -> T) -> Result<T, Error> {
  var result: Result<T, Error>?
  let done = DispatchSemaphore(value: 0)
  Task.detached {
    do { result = .success(try await body()) } catch { result = .failure(error) }
    done.signal()
  }
  done.wait()
  return result!
}

/// Writes mono 48 kHz float PCM, one sample per index from `sample`.
private func writeTone(_ url: URL, seconds: Double, _ sample: (Int) -> Float) throws {
  let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
  let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
  let n = Int(seconds * 48000)
  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
  for i in 0..<n { buf.floatChannelData![0][i] = sample(i) }
  buf.frameLength = AVAudioFrameCount(n)
  try file.write(from: buf)
}

/// A sine's samples: `db` is its RMS level in dBFS.
private func sine(_ hz: Double, db: Double) -> (Int) -> Float {
  let amp = pow(10, db / 20) * sqrt(2)
  return { Float(amp * sin(2 * Double.pi * hz * Double($0) / 48000)) }
}

/// RMS level in dBFS of `samples[from..<to]` (sample indices at 48 kHz).
private func rmsDB(_ samples: [Float], _ from: Int, _ to: Int) -> Double {
  let part = samples[max(0, from)..<min(samples.count, to)]
  let power = part.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, part.count))
  return 10 * log10(max(power, 1e-20))
}

/// Mono samples of `url` played through `tap` (an audio mix on an asset reader, the export's path).
private func readThroughTap(_ url: URL, _ tap: MTAudioProcessingTap?) throws -> [Float] {
  let asset = AVURLAsset(url: url)
  let track = try blocking { try await asset.loadTracks(withMediaType: .audio).first! }.get()
  let params = AVMutableAudioMixInputParameters(track: track)
  params.audioTapProcessor = tap
  let mix = AVMutableAudioMix()
  mix.inputParameters = [params]
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderAudioMixOutput(
    audioTracks: [track],
    audioSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ])
  output.audioMix = mix
  reader.add(output)
  guard reader.startReading() else { throw reader.error ?? NSError(domain: "checks", code: 1) }
  var samples: [Float] = []
  while let sb = output.copyNextSampleBuffer() {
    guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
    let bytes = CMBlockBufferGetDataLength(block)
    var chunk = [Float](repeating: 0, count: bytes / 4)
    chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
    samples += chunk
  }
  return samples
}

private func readMono(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
  try file.read(into: buf)
  return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

func audioChecks() {
  // Openverse: only licenses a video can use, names the library and plan paths can hold, and the
  // license record that finds an id already downloaded.
  let query = Openverse.searchURL(.sounds, query: "ui pop", allowCredit: false).query ?? ""
  expect(query.contains("license=cc0,pdm&") && query.contains("length=shortest"), "Openverse sound search asks for credit-free short sounds (\(query))")
  expect(Openverse.searchURL(.images, query: "x", allowCredit: true).query?.contains("license=by,cc0,pdm") == true, "--credit-ok adds CC BY only")
  var pop = Openverse.Item(id: "130a70f2-4fa5-4600-8bca-eeec3c82edd3", title: "Pop: high / A.wav", license: "by", url: "https://x/p.mp3", filetype: "mp3")
  expect(Openverse.fileName(pop, .sounds) == "Openverse - Pop high A (CC BY).mp3", "a sound's name drops / and : and flags CC BY (\(Openverse.fileName(pop, .sounds)))")
  pop.license = "cc0"
  expect(Openverse.fileName(pop, .images) == "Pop high A.mp3", "a picture keeps its title")
  let licenseDir = FileManager.default.temporaryDirectory.appendingPathComponent("openverse-\(UUID())")
  do {
    try FileManager.default.createDirectory(at: licenseDir, withIntermediateDirectories: true)
    pop.title = "Say \"pop\""
    try Openverse.record(pop, file: "a.mp3", in: licenseDir)
    try Openverse.record(Openverse.Item(id: "00000000-0000-0000-0000-000000000001", license: "cc0", url: "u"), file: "b.mp3", in: licenseDir)
    expect(Openverse.recorded(pop.id, in: licenseDir) == "a.mp3", "the license record finds a downloaded id")
    expect(Openverse.recorded("00000000-0000-0000-0000-000000000001", in: licenseDir) == "b.mp3", "rows append under one header")
  } catch {
    expect(false, "Openverse license record: \(error)")
  }
  try? FileManager.default.removeItem(at: licenseDir)

  // New Recording's mic check: quiet only after 3 s with nothing over -55 dB; any sound resets it.
  var watch = SilenceWatch(start: 10)
  expect(!watch.isSilent(at: 12.9) && watch.isSilent(at: 13), "a mic that hears nothing is flagged after 3 s, not before")
  watch.hear(peakDB: -60, at: 12)
  expect(watch.isSilent(at: 13), "peaks under -55 dB don't count as sound")
  watch.hear(peakDB: -30, at: 14)
  expect(!watch.isSilent(at: 16.5) && watch.isSilent(at: 17), "speech clears the flag, and 3 s of quiet after it sets it again")
  musicDuckChecks()
  gainTapChecks()
  voiceCleanupChecks()
}

/// The music's volume ramps: (start volume, end volume, start s, end s) for the ramp at `t`, if any.
private func volumeRamp(_ p: AVMutableAudioMixInputParameters, at t: Double) -> (Float, Float, Double, Double)? {
  var a: Float = 0, b: Float = 0
  var range = CMTimeRange.zero
  guard p.getVolumeRamp(for: CMTime(seconds: t, preferredTimescale: 60000), startVolume: &a, endVolume: &b, timeRange: &range) else { return nil }
  return (a, b, range.start.seconds, range.end.seconds)
}

private func musicDuckChecks() {
  let up = Float(pow(10, -14.0 / 20)), down = Float(pow(10, -32.0 / 20))
  func near(_ r: (Float, Float, Double, Double)?, _ want: (Float, Float, Double, Double)) -> Bool {
    guard let r else { return false }
    return abs(r.0 - want.0) < 1e-4 && abs(r.1 - want.1) < 1e-4 && abs(r.2 - want.2) < 1e-3 && abs(r.3 - want.3) < 1e-3
  }
  func ramps(_ music: Music, speech: [(Double, Double)], total: Double) -> AVMutableAudioMixInputParameters {
    let p = AVMutableAudioMixInputParameters()
    MusicDuck.apply(music, to: p, speech: speech, total: total)
    return p
  }

  // Talking from 5 to 8 s of a 20 s video: a 0.15 s ramp in, duck 0.3 s ahead of the voice, back up
  // over 0.6 s, and a 0.15 s ramp out. No long fades: they read as the video trailing off.
  let talk = ramps(Music(file: "m.m4a"), speech: [(5, 8)], total: 20)
  expect(near(volumeRamp(talk, at: 0.05), (0, up, 0, 0.15)), "music starts with a 0.15 s ramp (\(String(describing: volumeRamp(talk, at: 0.05))))")
  expect(near(volumeRamp(talk, at: 4.8), (up, down, 4.7, 5)), "music ducks 18 dB in the 0.3 s before the voice (\(String(describing: volumeRamp(talk, at: 4.8))))")
  expect(near(volumeRamp(talk, at: 8.3), (down, up, 8, 8.6)), "music comes back up over 0.6 s after the voice (\(String(describing: volumeRamp(talk, at: 8.3))))")
  expect(near(volumeRamp(talk, at: 19.9), (up, 0, 19.85, 20)), "music stops with a 0.15 s ramp, no long fade (\(String(describing: volumeRamp(talk, at: 19.9))))")
  // Between ramps AVFoundation reports the next one; the volume holds where the last one ended.
  expect(near(volumeRamp(talk, at: 6.5), (down, up, 8, 8.6)), "the music holds ducked while the voice talks")

  // Talking from the start: ramp in to the ducked level, not up and straight back down.
  let early = ramps(Music(file: "m.m4a"), speech: [(0.2, 3)], total: 10)
  expect(near(volumeRamp(early, at: 0.05), (0, down, 0, 0.15)), "talking at the start ramps in to the ducked level (\(String(describing: volumeRamp(early, at: 0.05))))")
  expect(near(volumeRamp(early, at: 3.3), (down, up, 3, 3.6)), "and comes up after the first line")

  // Still talking at the end: the ramp out starts from the ducked level, with no swell before it.
  let late = ramps(Music(file: "m.m4a"), speech: [(5, 19.8)], total: 20)
  expect(near(volumeRamp(late, at: 19.9), (down, 0, 19.85, 20)), "talking into the end stops from the ducked level (\(String(describing: volumeRamp(late, at: 19.9))))")
  expect(!(1..<39).contains { volumeRamp(late, at: Double($0) * 0.5).map { $0.1 == up && $0.2 > 4 } ?? false }, "the music never comes back up before the end")

  // A plan's own levels: -6 dB music, ducking 10 dB.
  let custom = ramps(Music(file: "m.m4a", volumeDB: -6, duckDB: -10), speech: [(5, 8)], total: 20)
  expect(near(volumeRamp(custom, at: 4.8), (Float(pow(10, -6.0 / 20)), Float(pow(10, -16.0 / 20)), 4.7, 5)), "a plan's music and duck levels are used")

  // No talking: just the short ramps, full level between.
  let quiet = ramps(Music(file: "m.m4a"), speech: [], total: 10)
  expect(near(volumeRamp(quiet, at: 0.05), (0, up, 0, 0.15)) && near(volumeRamp(quiet, at: 9.9), (up, 0, 9.85, 10)), "with no talking only the start and stop ramps")
  expect(near(volumeRamp(quiet, at: 5), (up, 0, 9.85, 10)), "and the music holds its level between (the next ramp is the stop)")

  // Music off from 8 to 12 s of output: down to nothing over the 0.3 s before, silent, back over 0.6 s after.
  let off = AVMutableAudioMixInputParameters()
  MusicDuck.apply(Music(file: "m.m4a"), to: off, speech: [], off: [(8, 12)], total: 20)
  expect(near(volumeRamp(off, at: 7.8), (up, 0, 7.7, 8)), "music fades out over the 0.3 s before an off range (\(String(describing: volumeRamp(off, at: 7.8))))")
  expect(near(volumeRamp(off, at: 10), (0, up, 12, 12.6)), "and stays silent through it (the next ramp is the way back)")
  expect(near(volumeRamp(off, at: 12.3), (0, up, 12, 12.6)), "and comes back over 0.6 s after it (\(String(describing: volumeRamp(off, at: 12.3))))")
  expect(near(volumeRamp(off, at: 15), (up, 0, 19.85, 20)), "then holds its normal level to the stop")
  // Talking inside an off range doesn't bring the music back for the duck.
  let talkOff = AVMutableAudioMixInputParameters()
  MusicDuck.apply(Music(file: "m.m4a"), to: talkOff, speech: [(9, 11)], off: [(8, 12)], total: 20)
  expect(!stride(from: 8.0, to: 12.0, by: 0.05).contains { t in
    volumeRamp(talkOff, at: t).map { $0.2 < 12 && $0.3 > 8 && ($0.0 > 0 || $0.1 > 0) } ?? false
  }, "no ramp inside an off range rises above silence")
  expect(near(volumeRamp(talkOff, at: 12.3), (0, up, 12, 12.6)), "after it the music comes back to full (the voice stopped at 11)")

  // Off ranges are source seconds: a part that's cut does nothing, a range across a cut joins up in output.
  let cutMap = mapSegments([Segment(start: 0, end: 5, speed: 1), Segment(start: 10, end: 20, speed: 1)], fps: 30)
  let inCut = MusicDuck.offSpans(Music(file: "m.m4a", off: [MusicOff(start: 6, end: 9)]), mapped: cutMap, fps: 30)
  expect(inCut.isEmpty, "a range inside a cut has no output span (\(inCut))")
  let cutParams = AVMutableAudioMixInputParameters()
  MusicDuck.apply(Music(file: "m.m4a"), to: cutParams, speech: [], off: inCut, total: 15)
  expect(near(volumeRamp(cutParams, at: 7.5), (up, 0, 14.85, 15)), "so the music plays on as if it weren't there")
  let spans = MusicDuck.offSpans(Music(file: "m.m4a", off: [MusicOff(start: 3, end: 11), MusicOff(start: 13, end: 14)]), mapped: cutMap, fps: 30)
  expect(spans.count == 2 && abs(spans[0].0 - 3) < 1e-6 && abs(spans[0].1 - 6) < 1e-6 && abs(spans[1].0 - 8) < 1e-6 && abs(spans[1].1 - 9) < 1e-6,
    "source 3-11 across the 5-10 cut plays as output 3-6, and 13-14 as 8-9 (\(spans))")
}

private func gainTapChecks() {
  // Box: a fixed gain, or the gain times a per-frame curve interpolated between frames and held at the end.
  let fixed = AudioGain.Box(2, curve: [], fps: 10, warm: false)
  expect(fixed.gain(at: 0) == 2 && fixed.gain(at: 99) == 2, "with no curve the gain is fixed")
  let curved = AudioGain.Box(2, curve: [1, 0.5, 0.25], fps: 10, warm: false)
  expect(curved.gain(at: 0) == 2 && abs(curved.gain(at: 0.05) - 1.5) < 1e-6 && abs(curved.gain(at: 0.15) - 0.75) < 1e-6, "the curve is interpolated between frames")
  expect(curved.gain(at: 5) == 0.5 && curved.gain(at: -1) == 2, "the curve holds its ends")

  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-audio-tap-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  do {
    // A 2 s 1 kHz tone at -26 dB RMS, through the tap the preview and export use.
    let tone = dir.appendingPathComponent("tone.caf")
    try writeTone(tone, seconds: 2, sine(1000, db: -26))
    let dry = try readThroughTap(tone, nil)
    expect(abs(rmsDB(dry, 0, dry.count) + 26) < 0.2 && dry.count == 96000, "the dry tone reads back at -26 dB (\(rmsDB(dry, 0, dry.count)), \(dry.count) samples)")
    let boosted = try readThroughTap(tone, AudioGain.tap(gainDB: 6))
    let boost = rmsDB(boosted, 0, boosted.count) - rmsDB(dry, 0, dry.count)
    expect(abs(boost - 6) < 0.2, "a 6 dB tap raises the voice 6 dB (\(boost))")
    let unity = try readThroughTap(tone, AudioGain.tap(gainDB: 0))
    expect(unity.count == dry.count && zip(unity, dry).allSatisfy { abs($0 - $1) < 1e-6 }, "a 0 dB tap leaves the samples untouched")

    // A leveling curve: 0 dB for the first second, -12 dB from 1.1 s on (30 fps frames).
    let curve = (0..<60).map { $0 < 30 ? 0.0 : -12.0 }
    let leveled = try readThroughTap(tone, AudioGain.tap(gainDB: 0, curveDB: curve, fps: 30))
    let first = rmsDB(leveled, 0, 46000) - rmsDB(dry, 0, 46000), second = rmsDB(leveled, 53000, 96000) - rmsDB(dry, 53000, 96000)
    expect(abs(first) < 0.2 && abs(second + 12) < 0.2, "the tap follows the leveling curve over time (\(first), \(second))")

    // A boost past full scale rounds off below -0.5 dBFS instead of clipping.
    let hot = dir.appendingPathComponent("hot.caf")
    try writeTone(hot, seconds: 1, sine(1000, db: -6))
    let limited = try readThroughTap(hot, AudioGain.tap(gainDB: 12))
    let peak = limited.map { abs($0) }.max() ?? 0
    expect(peak <= 0.94 && peak > 0.9, "boosted peaks stay under -0.5 dBFS (peak \(peak))")
    expect(rmsDB(limited, 0, limited.count) > rmsDB(dry, 0, dry.count) + 15, "and the boost still makes it louder")

    // Warm voice in the tap: an 80 Hz tone gets more chest.
    let low = dir.appendingPathComponent("low.caf")
    try writeTone(low, seconds: 1, sine(80, db: -33))
    let lowDry = try readThroughTap(low, nil), lowWarm = try readThroughTap(low, AudioGain.tap(gainDB: 0, warm: true))
    let chest = rmsDB(lowWarm, 24000, 48000) - rmsDB(lowDry, 24000, 48000)
    expect(chest > 1.5, "the tap runs the warm voice chain (80 Hz +\(chest) dB)")
  } catch {
    expect(false, "gain tap: \(error)")
  }
}

private func voiceCleanupChecks() {
  // The fallback's expander, threshold -40 dB: room noise 20 dB under it drops the full 12 dB,
  // noise 3 dB under drops 3 dB, speech passes, and it opens fast and closes slowly.
  func expanded(_ parts: [(seconds: Double, db: Double)]) -> [Float] {
    var x: [Float] = []
    for part in parts {
      let s = sine(300, db: part.db), offset = x.count
      x += (0..<Int(part.seconds * 48000)).map { s(offset + $0) }
    }
    let expander = VoiceCleanup.Expander(threshold: -40)
    x.withUnsafeMutableBufferPointer { expander.process($0.baseAddress!, count: $0.count) }
    return x
  }
  let noise = expanded([(1, -60)])
  expect(abs(rmsDB(noise, 24000, 48000) + 72) < 0.5, "room noise 20 dB under the threshold drops 12 dB (\(rmsDB(noise, 24000, 48000)))")
  let near = expanded([(1, -43)])
  expect(abs(rmsDB(near, 24000, 48000) + 46) < 0.5, "noise 3 dB under the threshold drops 3 dB (\(rmsDB(near, 24000, 48000)))")
  let voice = expanded([(1, -20)])
  expect(abs(rmsDB(voice, 0, 48000) + 20) < 0.05, "speech passes at its level (\(rmsDB(voice, 0, 48000)))")
  let opening = expanded([(1, -60), (1, -20)])
  expect(abs(rmsDB(opening, 48000 + 2400, 48000 + 4800) + 20) < 1, "a word after a pause is at full level within 50 ms (\(rmsDB(opening, 50400, 52800)))")
  let closing = expanded([(1, -20), (1, -45)])
  let tailGain = rmsDB(closing, 48000 + 1440, 48000 + 2400) + 45, settled = rmsDB(closing, 48000 + 24000, 96000) + 45
  expect(tailGain > -2.5 && settled < -4.5, "the end of a word isn't clipped: 30-50 ms on it's down \(tailGain) dB, later \(settled) dB")

  // The filter fallback end to end: a 3 s mono file, room noise, a second of voice, room noise.
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-voice-clean-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  do {
    let src = dir.appendingPathComponent("screen.caf"), out = dir.appendingPathComponent(VoiceCleanup.fileName)
    let room = sine(300, db: -60), talk = sine(300, db: -20)
    try writeTone(src, seconds: 3) { $0 >= 48000 && $0 < 96000 ? talk($0) : room($0) }
    let levels = (0..<60).map { i in (Double(i) * 0.05, i >= 20 && i < 40 ? -20.0 : -60.0) }
    try blocking { try await VoiceCleanup.render(source: src, to: out, method: .filter, levels: levels) }.get()
    let cleaned = try readMono(out)
    expect(abs(Double(cleaned.count) - 144000) < 2048, "the cleaned voice is as long as the recording (\(cleaned.count) samples)")
    expect(abs(rmsDB(cleaned, 60000, 84000) + 20) < 1, "the voice keeps its level (\(rmsDB(cleaned, 60000, 84000)))")
    // Threshold: the quietest tenth (-60) + 12 = -48, less 3 for the expander, so -60 noise drops 9 dB.
    let roomOut = rmsDB(cleaned, 120000, 140000)
    expect(roomOut < -66 && roomOut > -72, "room noise between words drops about 9 dB (\(roomOut))")
    let onset = cleaned.firstIndex { abs($0) > 0.05 } ?? -1
    expect(abs(onset - 48000) < 240, "the cleaned voice lines up with the recording (voice starts at sample \(onset), want 48000)")
    // A fresh cleaned file is reused, not rendered again.
    try Data("cached".utf8).write(to: out)
    let project = Project(dir: dir, source: Project.Source(video: "screen.caf", width: 16, height: 16, duration: 3, captureStart: nil, camera: nil))
    let reused = try blocking { try await VoiceCleanup.cleaned(project, video: "screen.caf") }.get()
    expect(reused == out && (try? String(contentsOf: out, encoding: .utf8)) == "cached", "a cleaned voice newer than the recording is reused")
    expect(VoiceCleanup.Method(rawValue: "filter") == .filter && VoiceCleanup.Method(rawValue: "isolation") == .isolation, "cleanup methods by name")
    // No audio track: a clear error instead of a silent file.
    let empty = dir.appendingPathComponent("empty.mov")
    try Data().write(to: empty)
    let failed = blocking { try await VoiceCleanup.render(source: empty, to: dir.appendingPathComponent("x.m4a"), method: .filter, levels: []) }
    if case .success = failed { expect(false, "a file with no audio fails to clean") }
  } catch {
    expect(false, "voice cleanup: \(error)")
  }
}

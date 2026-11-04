import AVFoundation
import AppKit
import DirectorCore
import Foundation
import UniformTypeIdentifiers

// Publishing, the analyze-and-plan pipeline, exports and profiles.
extension ProjectModel {
  // MARK: Publishing

  var publishDir: URL { dir.appendingPathComponent("publish") }

  func openPublish() {
    if publishTitle.isEmpty { publishTitle = plan?.callouts.first?.text ?? name }
    publishFiles = (try? FileManager.default.contentsOfDirectory(at: publishDir, includingPropertiesForKeys: nil))?
      .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    descriptionText = (try? String(contentsOf: publishDir.appendingPathComponent("description.md"), encoding: .utf8)) ?? ""
    showPublish = true
  }

  /// Captions, chapters, transcript and thumbnails into publish/.
  func makePublishKit() {
    run("Making captions and thumbnails…") { [self] in
      guard let plan, let project else { return }
      let files = try await Publish.run(project: project, plan: plan, title: publishTitle) { msg in
        Task { @MainActor in self.status = msg }
      }
      publishFiles = files
      status = "Wrote \(files.count) files to publish/"
    }
  }

  func draftDescription() {
    let ai = AISettings.shared
    run("\(ai.provider.shortName) is writing the description…") { [self] in
      guard let plan, let project else { return }
      let scene = Scene(plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)
      let user = "Video title: \(publishTitle)\nLength: \(fmtTime(Double(scene.frameCount) / Double(scene.fps)))\n\nTranscript with timestamps:\n\(Publish.timedTranscript(scene))"
      let text = try await AIText.generate(system: AIText.descriptionSystem, user: user, settings: ai)
      try FileManager.default.createDirectory(at: publishDir, withIntermediateDirectories: true)
      let url = publishDir.appendingPathComponent("description.md")
      try text.write(to: url, atomically: true, encoding: .utf8)
      descriptionText = text
      if !publishFiles.contains(url) { publishFiles.append(url) }
      status = "Wrote publish/description.md"
    }
  }


  func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    status = label
    task = Task { @MainActor in
      do {
        try await work()
      } catch is CancellationError {
        status = "Stopped."
      } catch where Task.isCancelled {
        status = "Stopped."
      } catch {
        status = "\(label.replacingOccurrences(of: "…", with: "")) failed: \(error.localizedDescription)"
        Notices.shared.show(status, error: true)
      }
      busy = false
      task = nil
      onFinishedWork?(dir)
    }
  }

  /// Stops the AI edit in progress. What it already changed stays, as one undo step.
  func stopAsk() {
    task?.cancel()
  }

  /// Transcribe, measure motion, and write a first-draft plan (keeps an existing plan unless `force`).
  /// A joined recording already has its transcript and motion, so it passes `analyzeFirst: false`.
  func analyzeAndPlan(force: Bool = false, analyzeFirst: Bool = true, then done: (() -> Void)? = nil) {
    run("Analyzing…") { [self] in
      defer { done?() }
      if analyzeFirst { try await analyze(dir) { msg in Task { @MainActor in self.status = msg } } }
      let fresh = try await FreshDraft.withAppSettings(dir: dir, name: name) { msg in Task { @MainActor in self.status = msg } }
      let draft = fresh.plan
      if fresh.lipSyncUnchecked {
        Notices.shared.show("Couldn't check that the camera is in sync with your voice. If it looks off, set Camera > Lip sync.")
      }
      if let current = plan, force {
        undoStack.append(current)
        commit(draft)
      } else if plan == nil {
        commit(draft)
      } else {
        rebuild(now: true)
      }
    }
  }

  /// One file to export: the plan as it'll render, where it goes, and how `director animate` renders its animations.
  private struct ExportJob {
    let plan: Plan, url: URL, label: String, animateArgs: [String]
  }

  /// Queues the current format, or presets, for export (one file each). Exports run in the
  /// background on the plan as it is right now, so you can keep editing.
  func export(_ presets: [ExportPreset?] = [nil]) {
    flushWrite()
    guard let plan else { return }
    enqueue(presets.map { preset in
      let shaped = preset.map { $0.applied(to: plan) } ?? plan
      return ExportJob(
        plan: shaped, url: exportURL(dir: dir, preset: preset, size: shaped.output),
        label: preset?.name ?? "current format", animateArgs: preset.map { ["--preset", $0.id] } ?? [])
    })
  }

  /// A vertical social clip over the in/out range, shown in the Format tab to name and set up.
  func makeClipFromRange() {
    guard let range = markedRange, let c = plan?.newClip(over: range) else { return }
    apply { $0.clipList.append(c) }
    status = "\(c.name): \(fmtTime(c.start))-\(fmtTime(c.end)). Set it up in Format › Clips, then export it from the Export menu."
  }

  /// Queues clips for export, each cut from the edit in its own format, named "<project> - <clip>.mp4".
  func exportClips(_ clips: [Clip]) {
    flushWrite()
    guard let plan else { return }
    let jobs = clips.map { c in
      let p = plan.trimmed(to: c, words: words, silences: project?.silences)
      return ExportJob(plan: p, url: exportURL(dir: dir, clip: c, size: p.output), label: c.name, animateArgs: ["--clip", c.name])
    }
    if let empty = jobs.first(where: { $0.plan.segments.isEmpty }) {
      Notices.shared.show("The clip \(empty.label) is entirely cut from the edit, so there's nothing to export.", error: true)
      return
    }
    // Each clip's captions file goes beside its video, for platforms that take one.
    if let project {
      for job in jobs {
        let srt = job.url.deletingPathExtension().appendingPathExtension("srt")
        do {
          try Publish.srt(Scene(plan: job.plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts))
            .write(to: srt, atomically: true, encoding: .utf8)
        } catch { Notices.shared.show(error, "Couldn't write the captions for \(job.label)") }
      }
    }
    enqueue(jobs)
  }

  private func enqueue(_ jobs: [ExportJob]) {
    guard let plan, !jobs.isEmpty else { return }
    // An export without its animations would quietly drop them, and each format has its own clips.
    if let job = jobs.first(where: { !$0.plan.animationsToRender(dir: dir).isEmpty }) {
      Notices.shared.show("Animations are still rendering for \(job.label). Export again when they're done.")
      renderAnimationsIfNeeded(plan, target: job.plan, args: job.animateArgs)
      return
    }
    // Menus, buttons and key shortcuts all call this on the main thread.
    MainActor.assumeIsolated {
      for job in jobs { ExportQueue.shared.enqueue(projectDir: dir, plan: job.plan, label: "\(name): \(job.label)", url: job.url) }
      ExportQueue.shared.showList = true
    }
    status = jobs.count == 1 ? "Exporting in the background." : "Queued \(jobs.count) exports."
  }

  func applyProfile(_ name: String) {
    let profile: Profile
    do { profile = try ProfileStore.shared.load(name) } catch {
      Notices.shared.show(error, "Couldn't read the profile \(name)")
      return
    }
    let title = self.name
    apply { profile.apply(to: &$0, name: title) }
    status = "Applied profile \(name)"
  }

  /// Changes the video's shape; vertical, square and feed crop the screen and follow the action.
  func setFormat(aspect: Aspect? = nil, resolution: Resolution? = nil) {
    guard let plan else { return }
    let a = aspect ?? Aspect.of(plan.output)
    let r = resolution ?? Resolution.of(plan.output)
    let size = outputSize(a, r)
    apply {
      $0.output.width = size.width
      $0.output.height = size.height
      if aspect != nil { $0.style.screenAspect = ExportPreset.all.first { $0.aspect == a }?.screenAspect }
    }
  }
}

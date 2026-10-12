import Combine
import Foundation

/// Exports run here, one at a time, so editing never waits on them. Each job renders the plan as
/// it was when queued: later edits don't change an export that's already waiting or running.
@MainActor
public final class ExportQueue: ObservableObject {
  public static let shared = ExportQueue()

  public enum State: Equatable {
    case queued, running, done, failed(String), cancelled
  }

  public final class Job: ObservableObject, Identifiable {
    public let id = UUID()
    public let projectDir: URL
    public let label: String
    public let url: URL
    let plan: Plan
    @Published public internal(set) var progress = 0.0
    @Published public internal(set) var state = State.queued

    init(projectDir: URL, plan: Plan, label: String, url: URL) {
      self.projectDir = projectDir
      self.plan = plan
      self.label = label
      self.url = url
    }

    public var isFinished: Bool {
      switch state {
      case .done, .failed, .cancelled: return true
      default: return false
      }
    }
  }

  @Published public private(set) var jobs: [Job] = []
  /// For the queue popover in the app.
  @Published public var showList = false
  /// Called when a job finishes successfully (the app reveals the file).
  public var onFinished: ((Job) -> Void)?

  private var current: (job: Job, task: Task<Void, Never>)?

  public init() {}

  public var activeCount: Int { jobs.filter { !$0.isFinished }.count }

  /// Queues an export of `plan` (snapshotted now) to `url`.
  @discardableResult
  public func enqueue(projectDir: URL, plan: Plan, label: String, url: URL) -> Job {
    let job = Job(projectDir: projectDir, plan: plan, label: label, url: url)
    jobs.append(job)
    startNext()
    return job
  }

  public func cancel(_ job: Job) {
    if current?.job === job {
      current?.task.cancel()
    } else if job.state == .queued {
      job.state = .cancelled
      objectWillChange.send()
    }
  }

  public func clearFinished() {
    jobs.removeAll { $0.isFinished }
  }

  private func startNext() {
    guard current == nil, let job = jobs.first(where: { $0.state == .queued }) else { return }
    job.state = .running
    objectWillChange.send()
    let task = Task { @MainActor in
      do {
        let project = try Project.load(job.projectDir)
        let built = try await buildComposition(project: project, plan: job.plan)
        try await export(built, to: job.url) { p in
          Task { @MainActor in job.progress = p }
        }
        job.state = .done
        job.progress = 1
        onFinished?(job)
      } catch is CancellationError {
        job.state = .cancelled
      } catch {
        job.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
      }
      objectWillChange.send()
      current = nil
      startNext()
    }
    current = (job, task)
  }

  /// Waits until nothing is queued or running (for scripts and tests).
  public func waitUntilIdle() async {
    while jobs.contains(where: { !$0.isFinished }) { try? await Task.sleep(nanoseconds: 100_000_000) }
  }
}

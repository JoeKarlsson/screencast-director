import Foundation

// Helpers for watching a child process (the app's Claude Code runs), here so macos/test.sh checks them.

/// Resumes its waiter once the process has exited, whether that happens before or after the wait.
public final class ExitSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiter: CheckedContinuation<Void, Never>?

  public init() {}

  public func fire() {
    lock.lock()
    fired = true
    let w = waiter
    waiter = nil
    lock.unlock()
    w?.resume()
  }

  public func wait() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      lock.lock()
      if fired {
        lock.unlock()
        c.resume()
      } else {
        waiter = c
        lock.unlock()
      }
    }
  }
}

/// The last `limit` bytes written, as text.
public final class TailBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private let limit: Int
  public init(limit: Int) { self.limit = limit }

  public func append(_ d: Data) {
    lock.lock()
    data.append(d)
    if data.count > limit { data = data.suffix(limit) }
    lock.unlock()
  }

  public var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

import Foundation

/// Records events from callbacks that may run on any thread.
final class EventLog: @unchecked Sendable {
    // State is guarded by `lock`.
    private let lock = NSLock()
    private var recorded: [String] = []

    var entries: [String] {
        lock.withLock { recorded }
    }

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }
}

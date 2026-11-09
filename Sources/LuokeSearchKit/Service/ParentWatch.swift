import Darwin
import Foundation

/// Calls `gone`, once, when a process ends, however it went: killed, crashed or quit without a word (`serve
/// --parent-pid`). Keep it for as long as the watching should go on.
public final class ParentWatch: @unchecked Sendable {
    private let source: DispatchSourceProcess

    public init(pid: pid_t, queue: DispatchQueue, gone: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [source] in
            source.cancel()
            gone()
        }
        source.resume()
        // A process that ended before the source was set up never fires it.
        queue.async { [source] in
            if !source.isCancelled, !Self.isRunning(pid) {
                source.cancel()
                gone()
            }
        }
    }

    deinit { source.cancel() }

    /// EPERM: it's there, and someone else's.
    static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

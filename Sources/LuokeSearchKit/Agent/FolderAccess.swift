import Foundation

/// Whether macOS lets a folder be read, asked on a thread of its own. The first read of a protected folder waits until
/// the user answers macOS's prompt, and the outbox is read with the tool server's lock held: a prompt nobody has
/// answered yet would stop every request, and the agent would say luoke-search isn't running.
final class FolderAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: Bool] = [:]
    private var asking: [String: DispatchGroup] = [:]
    private let patience: TimeInterval
    private let read: @Sendable (String) -> Bool

    init(patience: TimeInterval = 0.5, read: @escaping @Sendable (String) -> Bool = SearchService.readable) {
        self.patience = patience
        self.read = read
    }

    /// Each folder's latest answer. Asks again each time, waiting a moment for it: a folder that answers at once is
    /// always up to date, one still waiting for the user has its last answer, or none yet. One question per folder at a
    /// time, however long it waits.
    func answers(_ folders: [String]) -> [String: Bool] {
        let questions = folders.map(ask)
        let deadline = DispatchTime.now() + patience
        for question in questions { _ = question.wait(timeout: deadline) }
        return lock.withLock { known.filter { folders.contains($0.key) } }
    }

    private func ask(_ folder: String) -> DispatchGroup {
        lock.withLock {
            if let question = asking[folder] { return question }
            let question = DispatchGroup()
            question.enter()
            asking[folder] = question
            Thread.detachNewThread { [self] in      // not a pool's: it may wait for the user for a long time
                let answer = read(folder)
                lock.withLock {
                    known[folder] = answer
                    asking[folder] = nil
                }
                question.leave()
            }
            return question
        }
    }
}

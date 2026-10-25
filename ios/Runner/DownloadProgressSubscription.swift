import Foundation

final class CoreDownloadProgress {
    private let waiter: (Int64, Int64) throws -> String
    private let closer: () -> Void

    init(wait: @escaping (Int64, Int64) throws -> String, close: @escaping () -> Void = {}) {
        waiter = wait
        closer = close
    }

    func waitDelta(_ sequence: Int64, _ timeout: Int64) throws -> String {
        try waiter(sequence, timeout)
    }

    func close() { closer() }
}

/// Each listener owns its cursor and pending waiter. Lifecycle and delivery run
/// on the main queue; a cancelled wait may finish, but can only touch its own state.
final class DownloadProgressSubscription {
    typealias Waiter = (Int64, Int64) -> String
    private final class Session {
        let queue = DispatchQueue(label: "com.zarz.mornye.download_progress_subscription", qos: .utility)
        private let lock = NSLock()
        private var cancelled = false
        private var source: CoreDownloadProgress?
        // Accessed only on this session's queue.
        var sequence: Int64 = 0
        var lastPayload: String?

        func cancel() {
            lock.lock()
            cancelled = true
            let closing = source
            source = nil
            lock.unlock()
            closing?.close()
        }

        func connection(_ connect: () throws -> CoreDownloadProgress) throws -> CoreDownloadProgress? {
            lock.lock()
            let stopped = cancelled
            let existing = source
            lock.unlock()
            if stopped { return nil }
            if let existing { return existing }
            let opened = try connect()
            lock.lock()
            if cancelled {
                lock.unlock()
                opened.close()
                return nil
            }
            source = opened
            lock.unlock()
            return opened
        }

        func disconnect() {
            lock.lock()
            let closing = source
            source = nil
            lock.unlock()
            closing?.close()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private let connect: () throws -> CoreDownloadProgress
    private let interval: TimeInterval
    private var current: Session?

    convenience init(interval: TimeInterval = 0.25, waiter: @escaping Waiter) {
        self.init(interval: interval, connect: { CoreDownloadProgress(wait: waiter) })
    }

    init(interval: TimeInterval = 0.25, connect: @escaping () throws -> CoreDownloadProgress) {
        self.interval = interval
        self.connect = connect
    }

    func start(_ receive: @escaping (Any) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        let session = Session()
        current = session
        poll(session, receive: receive)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        current?.cancel()
        current = nil
    }

    deinit { current?.cancel() }

    private func poll(_ session: Session, receive: @escaping (Any) -> Void) {
        let connect = self.connect
        session.queue.async { [weak self] in
            guard !session.isCancelled else { return }
            let payload: String
            do {
                guard let source = try session.connection(connect) else { return }
                payload = try source.waitDelta(session.sequence, 15_000)
            } catch {
                session.disconnect()
                session.sequence = 0
                session.lastPayload = nil
                payload = ""
            }
            guard !session.isCancelled else { return }
            if !payload.isEmpty && payload != session.lastPayload,
               let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let delta = object as? [String: Any],
               let sequence = delta["seq"] as? NSNumber {
                session.sequence = max(session.sequence, sequence.int64Value)
                session.lastPayload = payload
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.current === session, !session.isCancelled else { return }
                    receive(object)
                }
            }
            // Schedule from main so subscription identity is never accessed
            // concurrently, and stop/relisten does not wait for an old backend call.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.current === session, !session.isCancelled else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.interval) { [weak self] in
                    guard let self, self.current === session, !session.isCancelled else { return }
                    self.poll(session, receive: receive)
                }
            }
        }
    }
}

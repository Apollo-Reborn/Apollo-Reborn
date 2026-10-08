import Foundation

/// Bounds the caller's wait without assuming the underlying SDK cooperates
/// with cancellation. Keep one occupied slot after a timeout until the SDK
/// returns, so repeated refreshes cannot accumulate suspended publications.
actor ApolloPublicationGate {
    enum Failure: Error { case timedOut, stillRunning }

    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var activeID: UUID?

    func run(timeout: Duration = .seconds(20),
             operation: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard operationTask == nil else { throw Failure.stillRunning }
        let id = UUID()
        activeID = id
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            operationTask = Task {
                let result: Result<Void, Error>
                do {
                    try await operation()
                    try Task.checkCancellation()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                finish(result, id: id)
            }
            timeoutTask = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                // Cancellation can race a timer that has already fired. An
                // old timer must never resume a newer publication's waiter.
                guard activeID == id else { return }
                // This actor owns both completion paths: only one can resume.
                waiter?.resume(throwing: Failure.timedOut)
                waiter = nil
                operationTask?.cancel()
                timeoutTask = nil
            }
        }
    }

    private func finish(_ result: Result<Void, Error>, id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        operationTask = nil
        waiter?.resume(with: result)
        waiter = nil
    }
}

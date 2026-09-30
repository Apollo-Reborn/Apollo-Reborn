import Foundation

private enum TestFailure: Error { case expected }

/// Models an SDK callback that ignores cancellation until explicitly released.
private actor Callback {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var starts = 0
    private(set) var staleWrites = 0

    func suspend() async {
        starts += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func recordWrite() { staleWrites += 1 }
}

@main
private struct PublicationGateTests {
    static func main() async throws {
        let gate = ApolloPublicationGate()
        try await gate.run { }
        do {
            try await gate.run { throw TestFailure.expected }
            fatalError("An SDK error must reach the caller")
        } catch TestFailure.expected { }
        try await gate.run { } // Errors release the slot immediately.

        let callback = Callback()
        let started = ContinuousClock.now
        do {
            try await gate.run(timeout: .milliseconds(30)) {
                await callback.suspend()
                // Matches the checks between CoreSpotlight calls: a late SDK
                // callback must not start another write after timeout.
                try Task.checkCancellation()
                await callback.recordWrite()
            }
            fatalError("A missing SDK callback must time out")
        } catch ApolloPublicationGate.Failure.timedOut { }
        precondition(started.duration(to: .now) < .seconds(2), "Timeout must release its caller")

        // Refresh, status and toggle retries must not start more hanging work.
        for _ in 0..<100 {
            do {
                try await gate.run { await callback.suspend() }
                fatalError("A timed-out operation must keep its slot until it drains")
            } catch ApolloPublicationGate.Failure.stillRunning { }
        }
        let starts = await callback.starts
        precondition(starts == 1, "Only one SDK operation may remain suspended")

        await callback.release()
        // Wait for the cancelled operation to unwind; no wall-clock assumption
        // about executor scheduling is needed, but a broken gate fails boundedly.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            do {
                try await gate.run { }
                break
            } catch ApolloPublicationGate.Failure.stillRunning {
                precondition(ContinuousClock.now < deadline, "Late completion must release the slot")
                await Task.yield()
            }
        }
        let writes = await callback.staleWrites
        precondition(writes == 0, "A cancelled publication must not continue writing")

        // Repeated successful publications exercise cancellation of old timers;
        // no timer may resume a completed continuation or affect the next run.
        for _ in 0..<100 {
            try await gate.run(timeout: .milliseconds(10)) { }
        }
        try await Task.sleep(for: .milliseconds(30))
        try await gate.run { }

        // At the deadline either completion may legitimately win. Once it
        // drains, its old timer must not cancel the following publication.
        for _ in 0..<50 {
            do {
                try await gate.run(timeout: .milliseconds(1)) {
                    try await Task.sleep(for: .milliseconds(1))
                }
            } catch ApolloPublicationGate.Failure.timedOut { }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                do {
                    try await gate.run(timeout: .seconds(1)) {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    break
                } catch ApolloPublicationGate.Failure.stillRunning {
                    precondition(ContinuousClock.now < deadline)
                    await Task.yield()
                }
            }
        }
        print("PASS: publication success, error, timeout, bounded retries, late callback and timer races")
    }
}

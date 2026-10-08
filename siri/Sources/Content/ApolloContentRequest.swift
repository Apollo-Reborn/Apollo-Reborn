import Darwin
import Foundation

/// Owns one native request. Timeout and cancellation complete the continuation
/// exactly once, cancel the task, and ignore any subsequent native callback.
@MainActor
final class ApolloContentRequest {
    struct Response: Sendable {
        let data: Data
        let next: String?
    }
    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case account, rateLimit, network, invalidResponse, accountChanged, timeout, unavailable
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .account: "Sign in to Apollo before searching Reddit."
            case .rateLimit: "Reddit is rate limiting requests. Try again later."
            case .network: "Apollo could not load Reddit. Check its API setup and connection."
            case .invalidResponse: "Reddit returned an unexpected response."
            case .accountChanged: "Apollo’s account changed. Run the action again."
            case .timeout: "Reddit took too long to respond. Try again."
            case .unavailable: "This Apollo build does not include the content bridge."
            }
        }
    }
    private var continuation: CheckedContinuation<Response, Error>?
    private var operation: NSObject?
    private var timeoutTask: Task<Void, Never>?

    func fetch(kind: String, query: String = "", after: String? = nil) async throws -> Response {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start(kind: kind, query: query, after: after)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError()), cancel: true) }
        }
    }

    private func start(kind: String, query: String, after: String?) {
        guard let handle = dlopen(nil, RTLD_LAZY) else { finish(.failure(Failure.unavailable)); return }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "ApolloSiriFetchContent") else { finish(.failure(Failure.unavailable)); return }
        typealias Callback = @convention(block) (NSData?, NSString?, Int) -> Void
        typealias Fetch = @convention(c) (NSString, NSString, NSString?, Callback) -> NSObject?
        let callback: Callback = { data, next, code in
            // The C bridge explicitly dispatches every completion to main.
            guard code == 0, let data else {
                let error: Failure
                switch code {
                case 1: error = .account
                case 2: error = .rateLimit
                case 3: error = .network
                case 5: error = .accountChanged
                default: error = .invalidResponse
                }
                self.finish(.failure(error))
                return
            }
            self.finish(.success(Response(data: data as Data, next: next as String?)))
        }
        operation = unsafeBitCast(symbol, to: Fetch.self)(kind as NSString, query as NSString, after as NSString?, callback)
        guard continuation != nil else { operation = nil; return }
        timeoutTask = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self.finish(.failure(Failure.timeout), cancel: true)
        }
    }

    private func finish(_ result: Result<Response, Error>, cancel: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if cancel, operation?.responds(to: NSSelectorFromString("cancel")) == true {
            operation?.perform(NSSelectorFromString("cancel"))
        }
        operation = nil
        continuation.resume(with: result)
    }
}

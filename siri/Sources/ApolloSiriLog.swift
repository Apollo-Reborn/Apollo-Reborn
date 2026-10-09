import OSLog

enum ApolloSiriLog {
    // Same subsystem as ApolloLog so the existing device/simulator log workflow
    // captures it. Messages are fixed events, never account/content data.
    private static let logger = Logger(subsystem: "apollofix", category: "Siri")

    static func event(_ message: StaticString) {
        logger.notice("[Siri] \(String(describing: message), privacy: .public)")
    }

    static func event(_ message: StaticString, count: Int) {
        logger.notice("[Siri] \(String(describing: message), privacy: .public) count=\(count, privacy: .public)")
    }

    // These entry points can be called by Siri, Spotlight or Shortcuts. A query
    // callback proves entity access, not which system surface requested it.
    // Never log IDs, queries, returned content, account data or error strings.
    static func query<Value: Sendable>(_ operation: StaticString,
                                       perform: @Sendable () async throws -> [Value]) async throws -> [Value] {
        logger.notice("[Siri] Query started: \(String(describing: operation), privacy: .public)")
        do {
            let values = try await perform()
            logger.notice("[Siri] Query completed: \(String(describing: operation), privacy: .public) count=\(values.count, privacy: .public)")
            return values
        } catch {
            logger.notice("[Siri] Query failed: \(String(describing: operation), privacy: .public)")
            throw error
        }
    }

    // Detail transitions persist at notice level for Export Debug Logs. Feed
    // rows are high-frequency; keep their diagnostics at debug level.
    static func onscreen(_ message: StaticString, detail: Bool) {
        if detail {
            logger.notice("[Siri] Onscreen detail: \(String(describing: message), privacy: .public)")
        } else {
            logger.debug("[Siri] Onscreen row: \(String(describing: message), privacy: .public)")
        }
    }
}

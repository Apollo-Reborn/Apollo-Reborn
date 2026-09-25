import OSLog

enum ApolloSiriLog {
    // Same subsystem as ApolloLog so the existing device/simulator log workflow
    // captures the proof. Messages are fixed events, never account/content data.
    private static let logger = Logger(subsystem: "apollofix", category: "SiriProof")

    static func event(_ message: StaticString) {
        logger.notice("[SiriProof] \(String(describing: message), privacy: .public)")
    }
}

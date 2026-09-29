import Foundation

@MainActor
@objc public final class ApolloSiriBootstrap: NSObject {
    @objc public static func prepare() {
        ApolloSiriLog.event("Framework loaded in Apollo")
        ApolloContentBridge.start()
    }
}

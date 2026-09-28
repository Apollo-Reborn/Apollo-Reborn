import AppIntents
import CoreSpotlight
import Foundation

@MainActor
@objc public final class ApolloSiriBootstrap: NSObject {
    @objc public static func prepare() {
        ApolloSiriLog.event("Framework loaded in Apollo")
        ApolloContentBridge.start()
        ApolloSiriShortcuts.updateAppShortcutParameters()
        ApolloSiriLog.event("Refreshed empty App Shortcut catalogue; phrase shortcuts disabled")
        // Remove the fixed proof entity the old Show Community action put in the
        // DEFAULT index (Apple: named indexes only outside prototyping).
        Task.detached {
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: ApolloProofSubredditEntity.self)
        }
    }
}

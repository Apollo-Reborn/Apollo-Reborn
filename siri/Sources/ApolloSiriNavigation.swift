import Foundation
import UIKit
import Darwin

@MainActor
enum ApolloSiriNavigation {
    private static var searchInProgress = false
    static func search(_ query: String) async throws {
        guard !searchInProgress else { throw ApolloSiriNavigationError.searchUnavailable }
        searchInProgress = true
        defer { searchInProgress = false }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApolloSiriNavigationError.emptyQuery
        }
        try await waitForScene()
        lastIntentNavigation = Date()
        guard let handle = dlopen(nil, RTLD_LAZY) else { throw ApolloSiriNavigationError.routerUnavailable }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "ApolloSiriOpenNativeSearch"),
              let prepareSymbol = dlsym(handle, "ApolloSiriPrepareNativeSearch") else {
            throw ApolloSiriNavigationError.routerUnavailable
        }
        typealias Prepare = @convention(c) () -> UIViewController?
        guard let root = unsafeBitCast(prepareSymbol, to: Prepare.self)(),
              let navigation = root.navigationController else { throw ApolloSiriNavigationError.searchUnavailable }
        // A nonanimated pop still has deferred UIKit appearance callbacks. Don't
        // push search results until it has settled; repeated searches otherwise
        // appear to succeed while leaving the previous results on screen.
        for _ in 0..<40 {
            try Task.checkCancellation()
            if navigation.topViewController === root, navigation.transitionCoordinator == nil,
               root.viewIfLoaded?.window != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard navigation.topViewController === root, navigation.transitionCoordinator == nil,
              root.viewIfLoaded?.window != nil else { throw ApolloSiriNavigationError.searchUnavailable }
        typealias Search = @convention(c) (NSString) -> Bool
        guard unsafeBitCast(symbol, to: Search.self)(query as NSString) else {
            throw ApolloSiriNavigationError.searchUnavailable
        }
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let result = navigation.topViewController, result !== root,
               NSStringFromClass(type(of: result)).contains("PostsSearchResultsViewController"),
               result.userActivity?.title == "Search for “\(query)”",
               navigation.transitionCoordinator == nil {
                ApolloSiriLog.event("Verified native search results destination")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ApolloSiriNavigationError.searchUnavailable
    }

    private static func waitForScene() async throws {
        for _ in 0..<50 {
            try Task.checkCancellation()
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if scenes.contains(where: { scene in
                scene.activationState == .foregroundActive && scene.windows.contains {
                    $0.isKeyWindow && $0.rootViewController?.viewIfLoaded?.window != nil
                }
            }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ApolloSiriNavigationError.sceneUnavailable
    }

    /// When an intent last drove navigation. Apple: donate only interactions
    /// people start in the app's own UI, never ones Siri/Shortcuts started
    /// (the system already donates those), so the onscreen bridge checks this.
    private(set) static var lastIntentNavigation: Date?
    static var intentNavigationIsRecent: Bool {
        lastIntentNavigation.map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    static func open(_ url: URL) async throws {
        // Apollo's native Reddit route requires the canonical host (no www).
        guard url.scheme == "apollo", url.host == "reddit.com" else {
            throw ApolloSiriNavigationError.invalidRoute
        }
        lastIntentNavigation = Date()
        // Reuse the tweak's exported router, which handles Apollo's scene-owned
        // tab controller before invoking its URL-scheme handler. The browsing-web
        // activity handler is a DIFFERENT route and ignores ordinary Reddit URLs.
        // Resolve dynamically because this optional framework is built separately
        // from the Theos dylib; don't duplicate the router or dispatch via iOS
        // (which could choose a different sideloaded Apollo installation).
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            throw ApolloSiriNavigationError.routerUnavailable
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "ApolloRouteURLThroughApp") else {
            ApolloSiriLog.event("Apollo URL router unavailable")
            throw ApolloSiriNavigationError.routerUnavailable
        }
        typealias RouteURL = @convention(c) (NSURL) -> Bool
        let route = unsafeBitCast(symbol, to: RouteURL.self)
        for _ in 0..<50 {
            try Task.checkCancellation()
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if scenes.contains(where: { scene in
                scene.activationState == .foregroundActive && scene.windows.contains {
                    $0.isKeyWindow && $0.rootViewController?.viewIfLoaded?.window != nil
                }
            }) {
                guard route(url as NSURL) else {
                    ApolloSiriLog.event("Apollo URL router rejected delivery")
                    throw ApolloSiriNavigationError.routerUnavailable
                }
                ApolloSiriLog.event("Delivered apollo scheme URL to in-process router")
                return
            }
            // A cold launch can still be connecting its scene. This is bounded,
            // cancellation-aware, and does not touch views from a background actor.
            try await Task.sleep(for: .milliseconds(100))
        }
        ApolloSiriLog.event("Apollo scene unavailable")
        throw ApolloSiriNavigationError.sceneUnavailable
    }
}

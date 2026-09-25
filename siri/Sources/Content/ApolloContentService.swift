import AppIntents
import CoreSpotlight
import CryptoKit
import Darwin
import Foundation
import UIKit

@MainActor
@objc(ApolloContentBridge)
public final class ApolloContentBridge: NSObject {
    static let enabledKey = "ApolloSiriContentEnabled"
    static let schemaExperimentKey = "ApolloSiriExperimentalNotes"
    private static var observers: [NSObjectProtocol] = []
    private static var contentEvents: Task<Void, Never>?

    static func accountState() -> (ready: Bool, fingerprint: String?) {
        #if targetEnvironment(simulator)
        // Explicit synthetic-data mode for the isolated real-Apollo simulator
        // build. Never compiled into a device framework; no credential mocking.
        if UserDefaults.standard.bool(forKey: "ApolloSiriSyntheticCatalogue") {
            return (true, fingerprint("apollo-siri-synthetic"))
        }
        #endif
        guard let handle = dlopen(nil, RTLD_LAZY) else { return (false, nil) }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "ApolloSiriCurrentAccount") else { return (false, nil) }
        typealias CurrentAccount = @convention(c) () -> NSString?
        guard let account = unsafeBitCast(symbol, to: CurrentAccount.self)() as String? else { return (false, nil) }
        return (true, account.isEmpty ? nil : fingerprint(account))
    }

    private static func fingerprint(_ account: String) -> String {
        SHA256.hash(data: Data(account.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @objc public static func receiveListing(_ data: Data, account: String) {
        let expected = fingerprint(account)
        let previous = contentEvents
        contentEvents = Task {
            await previous?.value
            do { try await ApolloContentService.shared.ingest(data, account: expected) }
            catch { ApolloSiriLog.event("Content capture failed; no payload logged") }
            ApolloOnscreenBridge.refresh()
        }
    }

    @objc public static func suppressIdentifiers(_ identifiers: [String], account: String) {
        ApolloOnscreenBridge.clear()
        let expected = fingerprint(account)
        let previous = contentEvents
        contentEvents = Task {
            await previous?.value
            do { try await ApolloContentService.shared.suppress(identifiers, account: expected) }
            catch { ApolloSiriLog.event("Content removal failed; retry required") }
            ApolloOnscreenBridge.refresh()
            ApolloPostResultsSnippetIntent.reload()
        }
    }

    @objc public static func allowIdentifiers(_ identifiers: [String], account: String) {
        let expected = fingerprint(account)
        let previous = contentEvents
        contentEvents = Task {
            await previous?.value
            do { try await ApolloContentService.shared.allow(identifiers, account: expected) }
            catch { ApolloSiriLog.event("Content eligibility update failed") }
        }
    }

    @objc public static func setContentIndexing(_ enabled: Bool, completion: @escaping @MainActor (String) -> Void) {
        Task {
            do {
                try await ApolloContentService.shared.setEnabled(enabled)
                completion(try await ApolloContentService.shared.status())
            } catch { completion(message(for: error)) }
        }
    }

    @objc public static func contentIndexStatus(completion: @escaping @MainActor (String) -> Void) {
        Task {
            do { completion(try await ApolloContentService.shared.status()) }
            catch { completion(message(for: error)) }
        }
    }

    @objc public static func setSchemaExperiment(_ enabled: Bool, completion: @escaping @MainActor (String) -> Void) {
        UserDefaults.standard.set(enabled, forKey: schemaExperimentKey)
        ApolloOnscreenBridge.clear()
        Task {
            do { completion(try await ApolloContentService.shared.status()) }
            catch { completion(message(for: error)) }
        }
    }

    @objc public static func refreshSubscriptions(completion: @escaping @MainActor (String) -> Void) {
        Task {
            do {
                let complete = try await ApolloContentService.shared.refreshSubscriptions()
                let status = try await ApolloContentService.shared.status()
                completion(complete ? status : "\(status) Reached the 500-subscription fetch limit; no missing entries were removed.")
            } catch { completion(message(for: error)) }
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? any CustomLocalizedStringResourceConvertible {
            return String(localized: localized.localizedStringResource)
        }
        return "Apollo could not update its content index. Try again."
    }

    static func start() {
        // Observe account changes even when no listing arrives (including logout).
        // Query execution also checks the active account, not just this observer.
        guard observers.isEmpty else { return }
        let names = [UIApplication.didBecomeActiveNotification, UserDefaults.didChangeNotification,
                     Notification.Name("com.christianselig.RedditCurrentAccountChanged"),
                     Notification.Name("com.christianselig.RedditAccountChanged")]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in refresh() }
            })
        }
        refresh()
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "ApolloSiriSyntheticCatalogue"),
           UserDefaults.standard.bool(forKey: enabledKey),
           !UserDefaults.standard.bool(forKey: "ApolloSiriSyntheticCatalogueSeeded") {
            Task {
                do {
                    try await ApolloContentService.shared.seedSyntheticCatalogue()
                    UserDefaults.standard.set(true, forKey: "ApolloSiriSyntheticCatalogueSeeded")
                } catch { ApolloSiriLog.event("Synthetic catalogue seed failed") }
            }
        }
        #endif
    }

    @objc private static func refresh() {
        ApolloOnscreenBridge.refresh()
        ApolloPostResultsSnippetIntent.reload()
        Task {
            do { try await ApolloContentService.shared.refresh() }
            catch { ApolloSiriLog.event("Content catalogue refresh failed") }
        }
    }
}

actor ApolloContentService {
    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case accountUnavailable, indexingDisabled, searchInProgress, emptyQuery
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .accountUnavailable: "Apollo is still loading its account. Open Apollo and try again."
            case .indexingDisabled: "Enable Siri & Spotlight content indexing in Apollo first."
            case .searchInProgress: "Apollo is already loading content. Try again shortly."
            case .emptyQuery: "Enter a search of between 1 and 512 characters."
            }
        }
    }
    static let shared = ApolloContentService()
    static let indexName = "ApolloReborn.Content.v1"
    private var catalog: ApolloContentCatalog?
    private var dirty = false
    private var resetIndex = true // Reconcile incomplete work from a prior process.
    private var publishedPosts: Set<String> = []
    private var publishedSubreddits: Set<String> = []
    private var syncTask: Task<Void, Error>?
    private var protectionClass: FileProtectionType? = .completeUntilFirstUserAuthentication
    private var networkRequestInProgress = false
    private var experimentalNotes = false

    func schemaExperimentEnabled() async -> Bool {
        await MainActor.run { UserDefaults.standard.bool(forKey: ApolloContentBridge.schemaExperimentKey) }
    }

    #if targetEnvironment(simulator)
    func seedSyntheticCatalogue() async throws {
        try await refresh()
        let account = try enabledAccount()
        let rows: [[String: Any]] = [
            ["kind": "t3", "name": "t3_siritest1", "title": "Synthetic test: café keyboards",
             "subreddit": "apollo_test", "author": "test_author", "selftext": "A local fixture for the Apollo result card; not a Reddit response.",
             "subreddit_type": "public", "over_18": false, "hidden": false],
            ["kind": "t3", "name": "t3_siritest2", "title": "Synthetic test: compact keyboards",
             "subreddit": "apollo_test", "author": "test_author", "selftext": "Second local fixture for stable identity and multiple result rows.",
             "subreddit_type": "public", "over_18": false, "hidden": false]
        ]
        try store().ingest(JSONSerialization.data(withJSONObject: rows), account: account)
        scheduleSync()
        try await syncTask?.value
    }
    #endif

    private func store() throws -> ApolloContentCatalog {
        if let catalog { return catalog }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let loaded = try ApolloContentCatalog(file: root.appendingPathComponent("ApolloReborn/Siri/catalog-v1.json"))
        catalog = loaded
        return loaded
    }

    func refresh() async throws {
        let experiment = await schemaExperimentEnabled()
        if experimentalNotes != experiment { experimentalNotes = experiment; resetIndex = true }
        let (enabled, account) = await MainActor.run {
            (UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey), ApolloContentBridge.accountState())
        }
        guard account.ready || !enabled else { throw Failure.accountUnavailable }
        let catalog = try store()
        let changed = try catalog.configure(enabled: enabled, account: account.fingerprint)
        if changed { resetIndex = true }
        let count = catalog.state.records.count
        try catalog.expire()
        if changed || resetIndex || count != catalog.state.records.count { scheduleSync() }
    }

    func ingest(_ payload: Data, account: String) async throws {
        try await refresh()
        try store().ingest(payload, account: account)
        scheduleSync()
    }

    func suppress(_ identifiers: [String], account: String) async throws {
        try await refresh()
        let catalog = try store()
        try catalog.suppress(catalog.canonicalIdentifiers(identifiers), account: account)
        scheduleSync()
        try await syncTask?.value
    }

    func allow(_ identifiers: [String], account: String) async throws {
        try await refresh()
        let catalog = try store()
        try catalog.allow(catalog.canonicalIdentifiers(identifiers), account: account)
    }

    func searchSnapshot(query: String) async throws -> (records: [ApolloContentRecord], account: String) {
        try await refresh()
        let catalog = try store()
        return (catalog.records(kind: .post, query: query, limit: 10), catalog.state.account ?? "")
    }

    private func enabledAccount() throws -> String {
        let catalog = try store()
        guard catalog.state.enabled else { throw Failure.indexingDisabled }
        guard let account = catalog.state.account else { throw Failure.accountUnavailable }
        return account
    }

    func liveSearch(query: String) async throws -> (records: [ApolloContentRecord], account: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf16.count <= 512 else { throw Failure.emptyQuery }
        guard !networkRequestInProgress else { throw Failure.searchInProgress }
        networkRequestInProgress = true
        defer { networkRequestInProgress = false }
        try await refresh()
        let account = try enabledAccount()
        let request = await ApolloContentRequest()
        let result = try await request.fetch(kind: "search", query: query)
        try Task.checkCancellation()
        try await ingest(result.data, account: account)
        guard try enabledAccount() == account else { throw Failure.accountUnavailable }
        let rows = try JSONSerialization.jsonObject(with: result.data) as? [[String: Any]] ?? []
        let ids = rows.compactMap(ApolloContentRecord.identifier)
        var seen = Set<String>()
        let records = try store().resolve(ids).filter { $0.kind == .post && seen.insert($0.id).inserted }
        return (Array(records.prefix(10)), account)
    }

    func refreshSubscriptions() async throws -> Bool {
        guard !networkRequestInProgress else { throw Failure.searchInProgress }
        networkRequestInProgress = true
        defer { networkRequestInProgress = false }
        try await refresh()
        let account = try enabledAccount()
        var after: String?
        var observed = Set<String>()
        var cursors = Set<String>()
        for _ in 0..<5 {
            try Task.checkCancellation()
            let request = await ApolloContentRequest()
            let result = try await request.fetch(kind: "subscriptions", after: after)
            try Task.checkCancellation()
            try await ingest(result.data, account: account)
            guard try enabledAccount() == account else { throw Failure.accountUnavailable }
            let rows = try JSONSerialization.jsonObject(with: result.data) as? [[String: Any]] ?? []
            observed.formUnion(rows.compactMap { row in
                guard row["kind"] as? String == "t5" else { return nil }
                return ApolloContentRecord.identifier(row)
            })
            guard let next = result.next, !next.isEmpty else {
                let catalog = try store()
                let stale = catalog.records(kind: .subreddit, limit: 500).map(\.id).filter { !observed.contains($0) }
                try catalog.suppress(stale, account: account)
                scheduleSync()
                try await syncTask?.value
                return true
            }
            guard cursors.insert(next).inserted else { throw ApolloContentRequest.Failure.invalidResponse }
            after = next
        }
        try await syncTask?.value
        return false // Never infer unsubscribe from a truncated/failed listing.
    }

    /// Snippet redraws are reads, not new searches, writes or indexing requests.
    /// Never render a prior account's captured values after account switching.
    func snippetRecords(identifiers: [String], account: String) async throws -> [ApolloContentRecord] {
        let (enabled, current) = await MainActor.run {
            (UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey), ApolloContentBridge.accountState())
        }
        guard enabled, current.ready, current.fingerprint == account else { return [] }
        let catalog = try store()
        guard catalog.state.account == account else { return [] }
        return catalog.resolve(Array(identifiers.prefix(10))).filter { $0.kind == .post }
    }

    func records(kind: ApolloContentRecord.Kind, query: String = "", limit: Int = 50) async throws -> [ApolloContentRecord] {
        try await refresh()
        return try store().records(kind: kind, query: query, limit: limit)
    }

    func resolve(_ identifiers: [String], kind: ApolloContentRecord.Kind) async throws -> [ApolloContentRecord] {
        try await refresh()
        return try store().resolve(identifiers).filter { $0.kind == kind }
    }

    func setEnabled(_ enabled: Bool) async throws {
        await MainActor.run { UserDefaults.standard.set(enabled, forKey: ApolloContentBridge.enabledKey) }
        try await refresh()
        // Turning off completes only after our entities have been removed from
        // Spotlight. An in-flight older upsert cannot race a completed disable.
        try await syncTask?.value
    }

    func status() async throws -> String {
        try await refresh()
        try await syncTask?.value
        let catalog = try store()
        guard catalog.state.enabled else { return "Apollo content indexing is off. Its post and subscription index is cleared." }
        guard catalog.state.account != nil else { return "Apollo content indexing is enabled. Sign in and browse Apollo to collect eligible public content." }
        let posts = catalog.records(kind: .post, limit: 1000).count
        let subs = catalog.records(kind: .subreddit, limit: 500).count
        let projection = experimentalNotes ? "Experimental notes schema" : "Canonical post entities"
        return "Apollo catalogue: \(posts) posts and \(subs) subscribed communities. \(projection). Public, non-NSFW content only; up to 30 days of loaded content."
    }

    func reindex(protectionClass: FileProtectionType?) async throws {
        try await refresh()
        // The system supplies the protection class of the index being rebuilt.
        // Retain our index namespace but honour that supplied description.
        self.protectionClass = protectionClass
        resetIndex = true
        scheduleSync()
        try await syncTask?.value
    }

    private func scheduleSync() {
        dirty = true
        guard syncTask == nil else { return }
        syncTask = Task {
            defer { syncTask = nil }
            do {
                // Coalesce normal listing bursts; actor remains available for
                // capture and opt-out while Spotlight operations are suspended.
                try await Task.sleep(for: .milliseconds(500))
                while dirty {
                    dirty = false
                    let reset = resetIndex
                    resetIndex = false
                    let posts = try store().records(kind: .post, limit: 1000).map(ApolloPostEntity.init)
                    let subs = try store().records(kind: .subreddit, limit: 500).map(ApolloSubredditEntity.init)
                    let postIDs = Set(posts.map(\.id))
                    let subredditIDs = Set(subs.map(\.id))
                    let notes = experimentalNotes ? try store().records(kind: .post, limit: 1000) : []
                    try await Self.publish(reset: reset, posts: posts, subreddits: subs,
                                           removePosts: Array(publishedPosts.subtracting(postIDs)),
                                           removeSubreddits: Array(publishedSubreddits.subtracting(subredditIDs)),
                                           protectionClass: protectionClass, notes: notes, experimental: experimentalNotes)
                    publishedPosts = postIDs
                    publishedSubreddits = subredditIDs
                }
                ApolloSiriLog.event("Content index synchronized")
            } catch {
                resetIndex = true
                dirty = true
                ApolloSiriLog.event("Content index sync failed; retry on next refresh")
                throw error
            }
        }
    }

    // The SDK's CSSearchableIndex reference isn't Sendable. Keep it local to
    // this nonisolated async operation; never pass an actor-owned reference to
    // a nonisolated SDK method or paper over it with @unchecked Sendable.
    private nonisolated static func publish(reset: Bool, posts: [ApolloPostEntity],
                                            subreddits: [ApolloSubredditEntity],
                                            removePosts: [String], removeSubreddits: [String],
                                            protectionClass: FileProtectionType?, notes: [ApolloContentRecord], experimental: Bool) async throws {
        let index = CSSearchableIndex(name: indexName, protectionClass: protectionClass)
        let experimentIndex = CSSearchableIndex(name: "ApolloReborn.SchemaExperiment.v1", protectionClass: protectionClass)
        if reset {
            try await index.deleteAppEntities(ofType: ApolloPostEntity.self)
            try await index.deleteAppEntities(ofType: ApolloSubredditEntity.self)
            try await experimentIndex.deleteAppEntities(ofType: ApolloExperimentalPostNote.self)
        } else {
            if !removePosts.isEmpty { try await index.deleteAppEntities(identifiedBy: removePosts, ofType: ApolloPostEntity.self) }
            if !removeSubreddits.isEmpty { try await index.deleteAppEntities(identifiedBy: removeSubreddits, ofType: ApolloSubredditEntity.self) }
            if !removePosts.isEmpty {
                try await experimentIndex.deleteAppEntities(identifiedBy: removePosts.map { ApolloExperimentalPostNote.prefix + $0 }, ofType: ApolloExperimentalPostNote.self)
            }
        }
        // Entity-backed searchable items retain App Intents association while
        // allowing an expiry even when Apollo isn't launched again for weeks.
        let items = (experimental ? [] : posts).map { entity in
            let item = CSSearchableItem(appEntity: entity)
            item.expirationDate = entity.expiresAt
            return item
        } + subreddits.map { entity in
            let item = CSSearchableItem(appEntity: entity)
            item.expirationDate = entity.expiresAt
            return item
        }
        if !items.isEmpty { try await index.indexSearchableItems(items) }
        if experimental, !notes.isEmpty {
            let noteItems = notes.map { record in
                let item = CSSearchableItem(appEntity: ApolloExperimentalPostNote(record))
                item.expirationDate = record.observedAt.addingTimeInterval(30 * 24 * 60 * 60)
                return item
            }
            try await experimentIndex.indexSearchableItems(noteItems)
        }
    }
}

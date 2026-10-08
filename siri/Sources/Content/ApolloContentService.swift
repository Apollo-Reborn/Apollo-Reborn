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
    private static var observers: [NSObjectProtocol] = []
    private static var contentEvents: Task<Void, Never>?

    static func accountState() -> (ready: Bool, fingerprint: String?) {
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
        // Revalidate rather than clear(): clear() dropped every binding, so
        // still-visible unrelated rows could never be re-annotated.
        ApolloOnscreenBridge.refresh()
        let expected = fingerprint(account)
        let previous = contentEvents
        contentEvents = Task {
            await previous?.value
            do { try await ApolloContentService.shared.suppress(identifiers, account: expected) }
            catch { ApolloSiriLog.event("Content removal failed; retry required") }
            ApolloOnscreenBridge.refresh()
        }
    }

    /// A post the person opened (detail screen), from the tweak's RDKLink.
    /// Memory-only session context so onscreen annotations resolve even when
    /// no listing captured the post (opened from a link, inbox, etc.).
    @objc public static func observePost(_ data: Data, account: String) {
        enqueue(account: account) { service, expected in
            try await service.observePost(data, account: expected)
        }
    }

    /// Comments Apollo already loaded for an opened post. Memory-only.
    @objc public static func observeComments(_ data: Data, account: String) {
        enqueue(account: account) { service, expected in
            try await service.observeComments(data, account: expected)
        }
    }

    private static func enqueue(account: String,
                                _ work: @escaping @Sendable (ApolloContentService, String) async throws -> Void) {
        let expected = fingerprint(account)
        let previous = contentEvents
        contentEvents = Task {
            await previous?.value
            do { try await work(ApolloContentService.shared, expected) }
            catch { ApolloSiriLog.event("Session context update failed; no payload logged") }
            // Bindings created before this context arrived can now resolve.
            ApolloOnscreenBridge.refresh()
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
    }

    @objc private static func refresh() {
        // No SnippetIntent.reload() here: Apple documents that reload PRESENTS
        // the snippet when it isn't visible and dismisses any other snippet.
        // This path runs on every defaults change and app activation.
        ApolloOnscreenBridge.refresh()
        Task {
            do { try await ApolloContentService.shared.refresh() }
            catch { ApolloSiriLog.event("Content catalogue refresh failed") }
        }
    }
}

actor ApolloContentService {
    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case accountUnavailable, indexingDisabled, searchInProgress, emptyQuery, indexUnavailable
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .accountUnavailable: "Apollo is still loading its account. Open Apollo and try again."
            case .indexingDisabled: "Enable Siri & Spotlight content indexing in Apollo first."
            case .searchInProgress: "Apollo is already loading content. Try again shortly."
            case .indexUnavailable: "Spotlight could not finish updating. Apollo will retry after a short pause. If it stays unavailable, reopen Apollo. Index removal is not confirmed until an update succeeds."
            case .emptyQuery: "Enter a search of between 1 and 512 characters."
            }
        }
    }
    static let shared = ApolloContentService()
    static let indexName = "ApolloReborn.Content.v1"
    private var catalog: ApolloContentCatalog?
    /// Viewed posts + loaded comments; never persisted or indexed.
    private let session = ApolloSessionContext()
    private var dirty = false
    private var resetIndex = false // Forces a full delete/rebuild (recovery, reindex-all, scope change).
    /// What Core Spotlight is known to hold: id → content signature, per scope.
    /// Persisted so a relaunch neither wipes/rebuilds the whole index nor
    /// republishes unchanged entities. Written only after the index calls
    /// succeed; a stale checkpoint only causes an idempotent re-upsert/delete.
    private struct PublishCheckpoint: Codable {
        var account: String?
        var posts: [String: String]
        var subreddits: [String: String]
    }
    private var checkpoint: PublishCheckpoint?
    private var checkpointLoaded = false
    private var syncTask: Task<Void, Error>?
    private var syncFailure: (any Error)?
    private var retryAfter: ContinuousClock.Instant?
    private static let publicationGate = ApolloPublicationGate()
    private var protectionClass: FileProtectionType? = .completeUntilFirstUserAuthentication
    private var networkRequestInProgress = false
    private func store() throws -> ApolloContentCatalog {
        if let catalog { return catalog }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let loaded = try ApolloContentCatalog(file: root.appendingPathComponent("ApolloReborn/Siri/catalog-v1.json"))
        catalog = loaded
        return loaded
    }

    func refresh() async throws {
        let (enabled, account) = await MainActor.run {
            (UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey), ApolloContentBridge.accountState())
        }
        guard account.ready || !enabled else { throw Failure.accountUnavailable }
        let catalog = try store()
        let changed = try catalog.configure(enabled: enabled, account: account.fingerprint)
        session.configure(account: catalog.state.enabled ? catalog.state.account : nil)
        if changed {
            retryAfter = nil // Account changes and opt-out must attempt cleanup immediately.
            resetIndex = true
            // Apple: remove donations that no longer apply. A different account
            // or an opt-out makes every prior Apollo open-content donation stale.
            Self.deleteAllDonations()
        }
        let count = catalog.state.records.count
        try catalog.expire()
        if changed || resetIndex || loadCheckpoint() == nil || count != catalog.state.records.count { scheduleSync() }
    }

    func ingest(_ payload: Data, account: String) async throws {
        try await refresh()
        try store().ingest(payload, account: account)
        scheduleSync()
    }

    func suppress(_ identifiers: [String], account: String) async throws {
        try await refresh()
        let catalog = try store()
        let canonical = catalog.canonicalIdentifiers(identifiers)
        try catalog.suppress(canonical, account: account)
        session.suppress(canonical)
        Self.deleteDonations(forPosts: canonical.filter { $0.hasPrefix("reddit:post:") })
        scheduleSync()
        try await waitForSync()
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
                try await waitForSync()
                return true
            }
            guard cursors.insert(next).inserted else { throw ApolloContentRequest.Failure.invalidResponse }
            after = next
        }
        try await waitForSync()
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
        let catalogued = try store().resolve(identifiers).filter { $0.kind == kind }
        guard kind == .post else { return catalogued }
        // Viewed-but-uncatalogued posts resolve too, so an annotated detail
        // screen and its open action work for posts opened from a link.
        let found = Set(catalogued.map(\.id))
        return catalogued + identifiers.filter { !found.contains($0) }.compactMap(session.post)
    }

    // MARK: - Session context (viewed posts, loaded comments)

    func observePost(_ payload: Data, account: String) async throws {
        try await refresh()
        let catalog = try store()
        guard catalog.state.enabled, catalog.state.account == account, payload.count <= 64 * 1024,
              let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let record = ApolloContentRecord.parse(json, now: Date()),
              !catalog.isSuppressed(record.id) else { return }
        session.observe(post: record, account: account)
    }

    func observeComments(_ payload: Data, account: String) async throws {
        try await refresh()
        let catalog = try store()
        guard catalog.state.enabled, catalog.state.account == account, payload.count <= 2 * 1024 * 1024,
              let rows = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else { return }
        let comments = rows.prefix(500).compactMap { row -> ApolloCommentRecord? in
            ApolloCommentRecord.parse(row, order: (row["order"] as? NSNumber)?.intValue ?? Int.max)
        }.filter { !catalog.isSuppressed($0.postID) }
        session.observe(comments: comments, account: account)
        ApolloSiriLog.event("Loaded comments added to session context", count: comments.count)
    }

    /// Onscreen lookup: catalogue first, then this session's viewed posts.
    /// Never renders a prior account's content after switching.
    func onscreenPost(_ id: String, account: String) async throws -> ApolloContentRecord? {
        try await refresh()
        let catalog = try store()
        guard catalog.state.enabled, catalog.state.account == account else { return nil }
        return catalog.resolve([id]).first { $0.kind == .post } ?? session.post(id)
    }

    func onscreenComment(_ id: String, account: String) async throws -> ApolloCommentRecord? {
        try await refresh()
        guard session.account == account else { return nil }
        return session.comments([id]).first
    }

    func comments(_ identifiers: [String]) async throws -> [ApolloCommentRecord] {
        try await refresh()
        return session.comments(identifiers)
    }

    func comments(forPost postID: String, limit: Int) async throws -> [ApolloCommentRecord] {
        try await refresh()
        return session.comments(forPost: postID, limit: limit)
    }

    func searchComments(_ query: String, limit: Int) async throws -> [ApolloCommentRecord] {
        try await refresh()
        return session.search(query, limit: limit)
    }

    // MARK: - Donation hygiene

    private nonisolated static func deleteAllDonations() {
        Task {
            for type in [OpenApolloPostIntent.self, OpenApolloCommentIntent.self,
                         OpenApolloSubscribedSubredditIntent.self] as [any AppIntent.Type] {
                _ = try? await IntentDonationManager.shared.deleteDonations(matching: .intentType(type))
            }
            ApolloSiriLog.event("Cleared Apollo intent donations after scope change")
        }
    }

    private nonisolated static func deleteDonations(forPosts ids: [String]) {
        guard !ids.isEmpty else { return }
        let entities = ids.map { EntityIdentifier(for: ApolloPostEntity.self, identifier: $0) }
        Task { try? await IntentDonationManager.shared.deleteDonations(matching: .entityIdentifiers(entities)) }
    }

    func setEnabled(_ enabled: Bool) async throws {
        await MainActor.run { UserDefaults.standard.set(enabled, forKey: ApolloContentBridge.enabledKey) }
        try await refresh()
        // Turning off completes only after our entities have been removed from
        // Spotlight. An in-flight older upsert cannot race a completed disable.
        try await waitForSync()
    }

    func status() async throws -> String {
        try await refresh()
        try await waitForSync()
        let catalog = try store()
        guard catalog.state.enabled else { return "Apollo content indexing is off. Its post and subscription index is cleared." }
        guard catalog.state.account != nil else { return "Apollo content indexing is enabled. Sign in and browse Apollo to collect eligible public content." }
        let posts = catalog.records(kind: .post, limit: 1000).count
        let subs = catalog.records(kind: .subreddit, limit: 500).count
        return "Apollo catalogue: \(posts) posts and \(subs) subscribed communities. Public, non-NSFW content only; up to 30 days of loaded content."
    }

    /// System-requested full recovery (IndexedEntityQuery.reindexAllEntities).
    func reindex(protectionClass: FileProtectionType?) async throws {
        try await refresh()
        // The system supplies the protection class of the index being rebuilt.
        // Retain our index namespace but honour that supplied description.
        self.protectionClass = protectionClass
        resetIndex = true
        scheduleSync()
        try await waitForSync()
    }

    /// System-requested targeted recovery: re-upsert only the named entities
    /// (Apple's IndexedEntityQuery contract), deleting any we no longer hold.
    func reindex(_ identifiers: [String], protectionClass: FileProtectionType?) async throws {
        try await refresh()
        self.protectionClass = protectionClass
        let catalog = try store()
        let records = catalog.state.enabled ? catalog.resolve(identifiers) : []
        let present = Set(records.map(\.id))
        let missing = identifiers.filter { !present.contains($0) }
        try await Self.publish(reset: false, posts: records.filter { $0.kind == .post },
                               subreddits: records.filter { $0.kind == .subreddit },
                               removePosts: missing, removeSubreddits: missing,
                               protectionClass: protectionClass)
        ApolloSiriLog.event("Targeted reindex completed", count: records.count)
    }

    // MARK: - Incremental Spotlight publication

    private func checkpointURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ApolloReborn/Siri/spotlight-checkpoint-v1.json")
    }

    private func loadCheckpoint() -> PublishCheckpoint? {
        if !checkpointLoaded {
            checkpointLoaded = true
            checkpoint = (try? Data(contentsOf: checkpointURL())).flatMap { try? JSONDecoder().decode(PublishCheckpoint.self, from: $0) }
        }
        return checkpoint
    }

    private func saveCheckpoint(_ next: PublishCheckpoint) throws {
        checkpoint = next
        var url = try checkpointURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Changes whenever indexed text changes. The week bucket re-upserts a
    /// still-observed record at most weekly so its Spotlight expiry keeps
    /// pace with catalogue retention, without republishing on every scroll.
    /// 32-byte digest of a checkpoint, committed atomically with each Spotlight
    /// batch (CoreSpotlight's client-state contract; limit 250 bytes).
    private static func clientState(_ checkpoint: PublishCheckpoint) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data((checkpoint.account ?? "-").utf8))
        for map in [checkpoint.posts, checkpoint.subreddits] {
            for key in map.keys.sorted() { hasher.update(data: Data("\(key)=\(map[key] ?? "")\n".utf8)) }
            hasher.update(data: Data([0]))
        }
        return Data(hasher.finalize())
    }

    private static func signature(_ record: ApolloContentRecord) -> String {
        let week = Int(record.observedAt.timeIntervalSince1970 / (7 * 24 * 60 * 60))
        let content = [record.title, record.text, record.author, record.subreddit, record.displayTitle ?? "",
                       record.score.map(String.init) ?? "", record.commentCount.map(String.init) ?? "",
                       record.linkDomain ?? "", String(week)]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(content.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func waitForSync() async throws {
        try await syncTask?.value
        // During backoff there is no task to await. Never claim a successful
        // update (especially "index is cleared") after a failed publication.
        if let syncFailure { throw syncFailure }
    }

    private func scheduleSync() {
        dirty = true
        guard syncTask == nil else { return }
        if let retryAfter, ContinuousClock.now < retryAfter { return }
        syncTask = Task {
            defer { syncTask = nil }
            do {
                // Coalesce normal listing bursts; actor remains available for
                // capture and opt-out while Spotlight operations are suspended.
                try await Task.sleep(for: .milliseconds(500))
                while dirty {
                    dirty = false
                    let catalog = try store()
                    let account = catalog.state.enabled ? catalog.state.account : nil
                    let posts = account == nil ? [] : catalog.records(kind: .post, limit: 1000)
                    let subs = account == nil ? [] : catalog.records(kind: .subreddit, limit: 500)
                    var previous = loadCheckpoint()
                    let reset = resetIndex || previous == nil || previous?.account != account
                    resetIndex = false
                    if reset { previous = PublishCheckpoint(account: account, posts: [:], subreddits: [:]) }
                    guard let previous else { continue }
                    let postSigs = Dictionary(posts.map { ($0.id, Self.signature($0)) }, uniquingKeysWith: { first, _ in first })
                    let subSigs = Dictionary(subs.map { ($0.id, Self.signature($0)) }, uniquingKeysWith: { first, _ in first })
                    let changedPosts = posts.filter { previous.posts[$0.id] != postSigs[$0.id] }
                    let changedSubs = subs.filter { previous.subreddits[$0.id] != subSigs[$0.id] }
                    let removePosts = previous.posts.keys.filter { postSigs[$0] == nil }
                    let removeSubs = previous.subreddits.keys.filter { subSigs[$0] == nil }
                    guard reset || !changedPosts.isEmpty || !changedSubs.isEmpty || !removePosts.isEmpty || !removeSubs.isEmpty else {
                        continue
                    }
                    let next = PublishCheckpoint(account: account,
                                                 posts: postSigs, subreddits: subSigs)
                    do {
                        try await Self.publish(reset: reset, posts: changedPosts, subreddits: changedSubs,
                                               removePosts: Array(removePosts), removeSubreddits: Array(removeSubs),
                                               protectionClass: protectionClass,
                                               expectedState: reset ? nil : Self.clientState(previous),
                                               newState: Self.clientState(next))
                    } catch let error as CSIndexError where error.code == .mismatchedClientState {
                        // Spotlight doesn't hold what our checkpoint says (index
                        // wiped/restored). Rebuild once instead of trusting it.
                        ApolloSiriLog.event("Spotlight client state mismatch; full rebuild")
                        resetIndex = true
                        dirty = true
                        continue
                    }
                    try saveCheckpoint(next)
                    syncFailure = nil
                    retryAfter = nil
                    ApolloSiriLog.event("Content index synchronized; upserts", count: changedPosts.count + changedSubs.count)
                }
            } catch {
                resetIndex = true
                dirty = true
                syncFailure = error
                retryAfter = ContinuousClock.now.advanced(by: .seconds(60))
                ApolloSiriLog.event("Content index sync failed; refresh retries after cooldown")
                throw error
            }
        }
    }

    /// A task-group timeout would still await a non-cooperative SDK child.
    /// The gate releases callers after 20 seconds but keeps that operation's
    /// slot occupied until it drains, avoiding overlapping or unbounded calls.
    private nonisolated static func publish(reset: Bool, posts: [ApolloContentRecord],
                                            subreddits: [ApolloContentRecord],
                                            removePosts: [String], removeSubreddits: [String],
                                            protectionClass: FileProtectionType?,
                                            expectedState: Data? = nil, newState: Data? = nil) async throws {
        do {
            try await publicationGate.run {
                try await publishNow(reset: reset, posts: posts, subreddits: subreddits,
                                     removePosts: removePosts, removeSubreddits: removeSubreddits,
                                     protectionClass: protectionClass,
                                     expectedState: expectedState, newState: newState)
            }
        } catch is ApolloPublicationGate.Failure {
            throw Failure.indexUnavailable
        }
    }

    // The SDK's CSSearchableIndex reference isn't Sendable. Keep it local to
    // this nonisolated async operation; never pass an actor-owned reference to
    // a nonisolated SDK method or paper over it with @unchecked Sendable.
    private nonisolated static func publishNow(reset: Bool, posts: [ApolloContentRecord],
                                            subreddits: [ApolloContentRecord],
                                            removePosts: [String], removeSubreddits: [String],
                                            protectionClass: FileProtectionType?,
                                            expectedState: Data? = nil, newState: Data? = nil) async throws {
        try Task.checkCancellation()
        let index = CSSearchableIndex(name: indexName, protectionClass: protectionClass)
        // Canonical-index work is one batch whose client state commits only if
        // every call lands (Apple's CosmoTunes pattern). Targeted reindex passes
        // no state and stays outside the batch contract.
        if newState != nil { index.beginBatch() }
        if reset {
            try await index.deleteAppEntities(ofType: ApolloPostEntity.self)
            try Task.checkCancellation()
            try await index.deleteAppEntities(ofType: ApolloSubredditEntity.self)
        } else {
            if !removePosts.isEmpty { try await index.deleteAppEntities(identifiedBy: removePosts, ofType: ApolloPostEntity.self) }
            try Task.checkCancellation()
            if !removeSubreddits.isEmpty { try await index.deleteAppEntities(identifiedBy: removeSubreddits, ofType: ApolloSubredditEntity.self) }
        }
        // A callback can arrive after the caller timed out or changed account.
        // Do not let the cancelled publication continue with stale writes.
        try Task.checkCancellation()
        // Entity-backed searchable items retain App Intents association while
        // allowing an expiry even when Apollo isn't launched again for weeks.
        // Upserting an existing identifier updates it in place (Apple).
        let items = posts.map { record in
            let entity = ApolloPostEntity(record)
            let item = CSSearchableItem(appEntity: entity)
            item.expirationDate = entity.expiresAt
            return item
        } + subreddits.map { record in
            let entity = ApolloSubredditEntity(record)
            let item = CSSearchableItem(appEntity: entity)
            item.expirationDate = entity.expiresAt
            return item
        }
        // Bounded batches keep a first full build from being one huge request.
        for start in stride(from: 0, to: items.count, by: 200) {
            try await index.indexSearchableItems(Array(items[start..<min(start + 200, items.count)]))
            try Task.checkCancellation()
        }
        if let newState {
            try await index.endIndexBatch(expectedClientState: expectedState, newClientState: newState)
        }
    }
}

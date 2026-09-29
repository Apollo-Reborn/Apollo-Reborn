//
//  ApolloAppleTranslation.swift
//  Apollo-Reborn
//
//  On-device translation backend powered by Apple's Translation framework
//  (iOS 18.0+). This is the project's first Swift compilation unit; it exists
//  solely because Apple's programmatic translation API has *no* Objective-C
//  surface and is only reachable from Swift/SwiftUI.
//
//  Why a hidden SwiftUI host?
//  --------------------------
//  A `TranslationSession` cannot be constructed directly on iOS 18–25; it is
//  vended ONLY inside the SwiftUI `.translationTask(_:action:)` closure attached
//  to a live view, and it is view-lifecycle-bound. The session that comes from a
//  view is also the only one that can drive Apple's one-time, system-presented
//  language-model *download* sheet.
//
//  Source language is supplied EXPLICITLY by the caller (detected client-side via
//  NLLanguageRecognizer in ApolloTranslation.xm). We deliberately do NOT use
//  `source: nil` auto-detect: when Apple can't auto-detect a snippet it does not
//  throw — it SUSPENDS the translate call and presents a "select a language"
//  picker, which (because we drain requests serially) would block every queued
//  translation behind it. An explicit source avoids the picker entirely.
//
//  Each source language gets its own serial queue and its own session, so a
//  mixed-language thread (e.g. Portuguese + French comments) doesn't thrash a single
//  session's configuration. Installed pairs use the headless
//  `TranslationSession(installedSource:target:)` on iOS 26+; pairs that still need
//  the download (and every pair on iOS 18–25) use a hidden `.translationTask` probe.
//
//  The download prompt
//  -------------------
//  A hosted session's first translate for an un-downloaded language shows Apple's
//  download sheet — a SwiftUI sheet presented from the hidden host. Anything that
//  takes that sheet away before the user answers (a dismissal from elsewhere, a
//  presentation UIKit refuses) comes back as the same "cancelled" error a real
//  decline does. So the prompt is only raised once a moment the sheet can be seen
//  arrives, and only a sheet that was actually on screen and then dismissed counts
//  as a decline (see `promptGate` / `promptFailed`).
//
//  The Objective-C bridge is `ApolloAppleTranslator.translate(_:from:to:completion:)`.
//

import Foundation

#if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
import UIKit
import SwiftUI
import Translation
import OSLog
import os

@available(iOS 18.0, *)
private let appleTranslateLog = Logger(subsystem: "apollofix", category: "AppleTranslate")

/// Tunables for Apple's one-time download prompt.
private enum ApolloAppleDownloadPrompt {
    /// Distinct texts that must be detected as the language before asking — a one-off
    /// misdetection (an Italian title read as Indonesian) never corroborates.
    static let corroboratingTexts = 2
    /// How long a job may wait, from when it arrived, for a moment the sheet can be
    /// seen (no navigation or modal transition in flight, nothing covering the host).
    static let settleWindow: TimeInterval = 4
    /// A sheet on screen at least this long before it went away was answered by the
    /// user. Anything shorter was taken away before anyone could read it.
    static let declineVisibleSeconds: TimeInterval = 1
    /// After an interrupted prompt, wait this long before asking again.
    static let retryDelay: TimeInterval = 10
    /// Interrupted prompts per language before giving up until the next foreground.
    static let maxInterruptedPrompts = 3
    static let pollNanoseconds: UInt64 = 100_000_000
}

// MARK: - UIKit state probes

@available(iOS 18.0, *)
@MainActor
private enum ApolloAppleUIState {
    /// The coordinator of a navigation or modal transition in flight anywhere under
    /// `root` (container children and presented controllers), if any.
    static func inFlightTransition(under root: UIViewController) -> UIViewControllerTransitionCoordinator? {
        var stack: [UIViewController] = [root]
        var visited = 0
        while let vc = stack.popLast(), visited < 256 {
            visited += 1
            if let coordinator = vc.transitionCoordinator { return coordinator }
            stack.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { stack.append(presented) }
        }
        return nil
    }

    /// root, then each controller it (transitively) presents.
    static func presentedChain(from root: UIViewController?) -> [UIViewController] {
        var chain: [UIViewController] = []
        var current = root
        while let vc = current, chain.count < 32 {
            chain.append(vc)
            current = vc.presentedViewController
        }
        return chain
    }
}

/// Follows one UIKit transition so a prompt asked for DURING it can tell whether the
/// screen that asked survived: a request that arrives mid-swipe-back comes from the
/// screen being revealed, and if the swipe is cancelled that screen never shows.
@available(iOS 18.0, *)
@MainActor
fileprivate final class ApolloAppleTransitionWatch {
    private(set) var finished = false
    private(set) var cancelled = false

    private static weak var latest: ApolloAppleTransitionWatch?
    private static var latestCoordinator: ObjectIdentifier?

    /// A watch on the transition in flight in `window` right now, or nil if none.
    static func current(in window: UIWindow?) -> ApolloAppleTransitionWatch? {
        guard let root = window?.rootViewController,
              let coordinator = ApolloAppleUIState.inFlightTransition(under: root) else { return nil }
        let id = ObjectIdentifier(coordinator)
        if let latest, latestCoordinator == id, !latest.finished { return latest }
        let watch = ApolloAppleTransitionWatch()
        let queued = coordinator.animate(alongsideTransition: nil) { context in
            watch.finished = true
            watch.cancelled = context.isCancelled
        }
        // Not queued = the transition is already wrapping up; nothing to follow.
        guard queued else { return nil }
        latest = watch
        latestCoordinator = id
        return watch
    }
}

/// Measures how long a newly presented controller (the download sheet) stays on
/// screen while a prompting translate is in flight.
@available(iOS 18.0, *)
@MainActor
private final class ApolloAppleSheetObserver {
    private weak var window: UIWindow?
    private let baseline: Set<ObjectIdentifier>
    private var lastSeen: Date?
    private var poller: Task<Void, Never>?
    private(set) var visibleSeconds: TimeInterval = 0
    private(set) var sheetClass: String?

    init(window: UIWindow?) {
        self.window = window
        baseline = Set(ApolloAppleUIState.presentedChain(from: window?.rootViewController).map { ObjectIdentifier($0) })
    }

    func start() {
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                try? await Task.sleep(nanoseconds: ApolloAppleDownloadPrompt.pollNanoseconds)
            }
        }
    }

    func stop() {
        sample()
        poller?.cancel()
        poller = nil
    }

    private func sample() {
        let now = Date()
        let sheet = ApolloAppleUIState.presentedChain(from: window?.rootViewController).last { vc in
            !baseline.contains(ObjectIdentifier(vc)) && !vc.isBeingPresented && !vc.isBeingDismissed
        }
        guard let sheet else {
            lastSeen = nil
            return
        }
        if sheetClass == nil { sheetClass = String(describing: type(of: sheet)) }
        if let lastSeen { visibleSeconds += now.timeIntervalSince(lastSeen) }
        lastSeen = now
    }
}

/// Copies the Translation framework's own account of a prompt that ended without a
/// download (remote sheet finished without a configuration, extension/host connection
/// failures, a refused presentation) into our log, so a user's debug log shows WHY
/// the sheet went away. Failure path only; runs off-main.
@available(iOS 18.0, *)
private func logDownloadPromptTrail(since start: Date, source: String) {
    Task.detached(priority: .utility) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@ OR (subsystem == %@ AND category == %@)",
                                        "com.apple.Translation", "com.apple.UIKit", "Presentation")
            // The Translation subsystem also logs every asset/status query; keep the
            // lines about the sheet and its extension host.
            let keywords = ["remote UI", "extension", "Host Connection", "Connection interrupted",
                            "user action", "present", "Received cancel", "Cancelling previous session"]
            var lines: [String] = []
            for entry in try store.getEntries(at: store.position(date: start), matching: predicate) {
                guard let log = entry as? OSLogEntryLog, log.date >= start else { continue }
                let message = log.composedMessage
                guard log.subsystem == "com.apple.UIKit" ||
                      keywords.contains(where: { message.localizedCaseInsensitiveContains($0) }) else { continue }
                lines.append("\(log.category): \(message)")
                if lines.count >= 12 { break }
            }
            let trail = lines.isEmpty ? "(nothing from the Translation framework or UIKit presentation)" : lines.joined(separator: " | ")
            appleTranslateLog.log("download prompt trail (\(source, privacy: .public)): \(trail, privacy: .public)")
        } catch {
            appleTranslateLog.error("download prompt trail unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Per-source job queue

/// FIFO of translate requests for one source language that outlives any one
/// consumer. A hosted `.translationTask` action is cancelled whenever its host view
/// leaves the window, and SwiftUI does not re-run it for an unchanged configuration
/// when the view comes back — so a consumer can vanish at any time. Jobs stay here
/// until a live consumer takes them; the one a dying consumer held goes back to the
/// front. (An AsyncStream terminated on that cancellation and dropped every buffered
/// job, leaving the callers — and ApolloRequestTranslation's per-key coalescing —
/// waiting forever.)
@available(iOS 18.0, *)
@MainActor
fileprivate final class ApolloAppleJobQueue {
    struct Job {
        let text: String
        let completion: (String?, NSError?) -> Void
        let enqueuedAt: Date
        /// The UIKit transition in flight when this job arrived, if any.
        let transition: ApolloAppleTransitionWatch?
    }

    private var jobs: [Job] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isClosed = false

    func push(_ job: Job) {
        jobs.append(job)
        wakeAll()
    }

    func pushFront(_ job: Job) {
        jobs.insert(job, at: 0)
        wakeAll()
    }

    /// Fails every waiting job and ends every consumer's `next()` (teardown).
    func close(failingWith error: NSError) {
        isClosed = true
        let pending = jobs
        jobs.removeAll()
        wakeAll()
        for job in pending { job.completion(nil, error) }
    }

    /// The next job, or nil once the queue is closed or the calling task is cancelled.
    func next() async -> Job? {
        while true {
            if isClosed || Task.isCancelled { return nil }
            if !jobs.isEmpty { return jobs.removeFirst() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiters.append(continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.wakeAll() }
            }
        }
    }

    /// Every parked consumer re-checks; whoever runs first takes the job.
    private func wakeAll() {
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }
}

// MARK: - Hidden host

/// A 1×1, effectively invisible SwiftUI host installed as a child of a view
/// controller in the app's window. Reports window attach/detach, which drives
/// restarting hosted sessions SwiftUI cancelled while the host was off-window.
@available(iOS 18.0, *)
@MainActor
private final class ApolloAppleHiddenHost {
    private final class ContainerView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    private let hosting: UIViewController
    private let container = ContainerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    var window: UIWindow? { container.window }
    var parent: UIViewController? { hosting.parent }
    var isAttached: Bool { container.window != nil && hosting.parent != nil }

    init(hosting: UIViewController, onWindowChange: @escaping (UIWindow?) -> Void) {
        self.hosting = hosting
        container.alpha = 0.001
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear
        hosting.view.frame = container.bounds
        hosting.view.backgroundColor = .clear
        container.onWindowChange = onWindowChange
    }

    func install(in parent: UIViewController) {
        parent.addChild(hosting)
        container.addSubview(hosting.view)
        parent.view.addSubview(container)
        hosting.didMove(toParent: parent)
    }

    func remove() {
        container.onWindowChange = nil
        hosting.willMove(toParent: nil)
        hosting.view.removeFromSuperview()
        container.removeFromSuperview()
        hosting.removeFromParent()
    }
}

// MARK: - Coordinator

/// Owns one queue + session per source language, the hidden SwiftUI probe host for
/// sessions that need it, and Apple's download prompt. Main-actor isolated so every
/// completion is delivered on the main thread (matching the other providers).
@available(iOS 18.0, *)
@MainActor
final class ApolloAppleTranslationCoordinator: ObservableObject {
    static let shared = ApolloAppleTranslationCoordinator()

    fileprivate typealias Job = ApolloAppleJobQueue.Job

    fileprivate enum Route: Equatable {
        case resolving          // availability query in flight; jobs wait in the queue
        case direct             // headless installed-pair session (iOS 26+ SDK)
        case hosted             // hidden .translationTask probe (may raise the download sheet)
        case unavailable        // unsupported pair; fail fast
        #if APOLLO_SIM_BUILD
        case simBridge          // host Mac's Apple engine over loopback
        case simPrompt          // simulated download sheet, then the host bridge
        #endif

        /// Serves through a session that raises the download sheet while the model is missing.
        var promptsForDownload: Bool {
            #if APOLLO_SIM_BUILD
            if self == .simPrompt { return true }
            #endif
            return self == .hosted
        }
    }

    @MainActor
    fileprivate final class SourceState {
        let code: String
        let queue = ApolloAppleJobQueue()
        var route: Route = .resolving
        /// The pair's model is on the device; translating can't raise the sheet.
        var installed = false
        /// The download sheet was on screen and the user dismissed it.
        var declinedByUser = false
        /// Prompts kept ending before anyone could answer; stop until the next foreground.
        var gaveUp = false
        var corroboration = Set<Int>()
        var interruptedPrompts = 0
        var promptRetryAfter: Date?
        var config: TranslationSession.Configuration?
        var liveRunToken: UUID?
        var runsStarted = 0
        var restartRequested = false
        init(code: String) { self.code = code }
    }

    /// Hosted sources, rendered as one `.translationTask` probe each by the host view.
    @Published private(set) var sources: [String] = []

    private var target: String = "en"
    private var states: [String: SourceState] = [:]
    private var probeHost: ApolloAppleHiddenHost?

    private init() {
        // Coming back from Settings (where the user may have downloaded a language) or
        // any other app: re-check what's installed and offer the prompt again.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in ApolloAppleTranslationCoordinator.shared.appDidBecomeActive() }
        }
    }

    // Build a Locale.Language from a bare code ("pt", "en"). Use languageCode: (not
    // identifier:) so the value canonicalizes identically to what LanguageAvailability
    // checks — identifier: can attach an unintended region and mismatch.
    private func makeLanguage(_ code: String) -> Locale.Language {
        Locale.Language(languageCode: Locale.LanguageCode(code))
    }

    // Objective-C entry hops here already on the main actor. `source` and `target`
    // are normalized language codes; source is always non-empty (caller detects it).
    fileprivate func enqueue(text: String, source: String, target: String,
                             completion: @escaping (String?, NSError?) -> Void) {
        let src = source.lowercased()
        let tgt = target.lowercased()
        guard !src.isEmpty, !tgt.isEmpty else {
            completion(nil, Self.makeError(code: 302, "Missing source/target language"))
            return
        }

        // Target language is fixed per browsing session. If it changes, tear down every
        // source (sessions are target-specific) and start over.
        if tgt != self.target { resetAll(newTarget: tgt) }

        let state: SourceState
        if let existing = states[src] {
            state = existing
        } else {
            state = SourceState(code: src)
            states[src] = state
            resolveRoute(for: state, target: tgt)
        }

        if state.route == .unavailable {
            completion(nil, Self.makeError(code: 303, "\(src) not available"))
            return
        }

        // Only a job that may raise the download sheet needs to know about a transition.
        let mayPrompt = !state.installed && !state.declinedByUser && !state.gaveUp
        let transition = mayPrompt ? ApolloAppleTransitionWatch.current(in: Self.activeWindow()) : nil
        state.queue.push(Job(text: text, completion: completion, enqueuedAt: Date(), transition: transition))
        if state.route == .hosted { ensureProbeHost() }
        #if APOLLO_SIM_BUILD
        if state.route == .simPrompt { ensureSimPromptHost() }
        #endif
    }

    private func resetAll(newTarget: String) {
        target = newTarget
        let error = Self.makeError(code: 302, "Target language changed")
        for state in states.values {
            state.route = .unavailable
            state.queue.close(failingWith: error)
        }
        states.removeAll()
        sources = []
        tearDownProbeHostIfIdle()
    }

    // Decide how a source is served. Runs once per source (again after a foreground
    // for a source that was unavailable).
    private func resolveRoute(for state: SourceState, target tgt: String) {
        let src = state.code
        Task { @MainActor in
            let status = await LanguageAvailability().status(from: self.makeLanguage(src), to: self.makeLanguage(tgt))
            guard self.states[src] === state, state.route == .resolving else { return }
            switch status {
            case .installed:
                state.installed = true
                #if compiler(>=6.2)
                // Built with the iOS 26 SDK (Xcode 26+ / Swift 6.2+): on iOS 26 use the
                // headless TranslationSession(installedSource:target:) for installed pairs.
                // It's owned/reusable and NOT view-anchored, so it survives the SwiftUI host
                // re-renders that collapse a .translationTask-vended session under load.
                // That initializer is iOS-26-SDK-only, so this branch is compiled out on
                // older SDKs (e.g. CI on Xcode 16) and we fall through to the hosted probe.
                if #available(iOS 26.0, *) {
                    self.startDirect(state, reason: "installed")
                    return
                }
                #endif
                // iOS 18–25, or built against an SDK without the headless initializer.
                self.startHosted(state, reason: "installed")
            case .supported:
                // Available but not downloaded: the hosted session's first translate shows
                // Apple's download sheet, once there's a moment the user can see it.
                self.startHosted(state, reason: "needs download")
            default:
                #if APOLLO_SIM_BUILD
                self.startSimRoute(state)
                #else
                appleTranslateLog.log("skip \(src, privacy: .public)->\(tgt, privacy: .public) (status=\(String(describing: status), privacy: .public))")
                state.route = .unavailable
                state.queue.close(failingWith: Self.makeError(code: 303, "\(src) not available"))
                #endif
            }
        }
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func startDirect(_ state: SourceState, reason: String) {
        state.route = .direct
        appleTranslateLog.log("direct session \(state.code, privacy: .public)->\(self.target, privacy: .public) (\(reason, privacy: .public))")
        let session = TranslationSession(installedSource: makeLanguage(state.code), target: makeLanguage(target))
        Task { @MainActor in await self.drainDirect(state, session: session) }
    }

    // Headless consumer: drains a source's jobs serially through a reused direct session.
    private func drainDirect(_ state: SourceState, session: TranslationSession) async {
        while let job = await state.queue.next() {
            guard state.route == .direct else { state.queue.pushFront(job); return }
            var attempt = 0
            while true {
                do {
                    let response = try await session.translate(job.text)
                    job.completion(response.targetText, nil)
                    break
                } catch is CancellationError {
                    job.completion(nil, Self.makeError(code: 304, "Translation cancelled"))
                    break
                } catch let error as NSError {
                    attempt += 1
                    // The framework intermittently throws TranslationError#1 ("Unable to
                    // Translate") under rapid serial load even for installed pairs. One
                    // short retry recovers most of these; give up after that.
                    if attempt >= 2 {
                        appleTranslateLog.error("direct translate failed (\(state.code, privacy: .public)) after retry: \(error.domain, privacy: .public)#\(error.code)")
                        job.completion(nil, error)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }
    #endif

    private func startHosted(_ state: SourceState, reason: String) {
        state.route = .hosted
        appleTranslateLog.log("hosted session \(state.code, privacy: .public)->\(self.target, privacy: .public) (\(reason, privacy: .public))")
        state.config = TranslationSession.Configuration(source: makeLanguage(state.code), target: makeLanguage(target))
        ensureProbeHost()
        if !sources.contains(state.code) { sources.append(state.code) }   // renders the probe -> .translationTask -> run()
    }

    /// Stable Configuration instance for a source (so SwiftUI's `.translationTask`
    /// doesn't restart on every re-render).
    func configuration(for source: String) -> TranslationSession.Configuration? {
        states[source]?.config
    }

    /// Hosted consumer, called by the probe's `.translationTask` with the session it
    /// vends. Returns when SwiftUI cancels the action (host left the window, config
    /// changed) or the source moves to another route; queued jobs are kept either way.
    func run(source: String, session: TranslationSession) async {
        guard let state = states[source], state.route == .hosted else { return }
        let token = UUID()
        state.liveRunToken = token
        state.runsStarted += 1
        state.restartRequested = false
        defer { if state.liveRunToken == token { state.liveRunToken = nil } }
        await consume(state, route: .hosted, window: probeHost?.window) { text in
            try await session.translate(text).targetText
        }
    }

    /// Drains `state`'s queue through a session that may still need Apple's download
    /// (the hosted probe, or the simulator's stand-in sheet). A job in hand when the
    /// calling task is cancelled goes back to the front of the queue.
    private func consume(_ state: SourceState, route: Route, window: @autoclosure () -> UIWindow?,
                         translate: (String) async throws -> String) async {
        while let job = await state.queue.next() {
            guard state.route == route else { state.queue.pushFront(job); return }

            if state.installed {
                do {
                    job.completion(try await translate(job.text), nil)
                } catch {
                    if Self.wasCancelled(error) { state.queue.pushFront(job); return }
                    job.completion(nil, error as NSError)
                }
                continue
            }

            switch await promptGate(state, job, route: route) {
            case .cancelled:
                state.queue.pushFront(job)
                return
            case .skip(let error):
                job.completion(nil, error)
                continue
            case .prompt:
                break
            }
            // The gate can wait; the model may have turned up (or the route moved) meanwhile.
            guard !state.installed, state.route == route else {
                state.queue.pushFront(job)
                continue
            }

            let observer = ApolloAppleSheetObserver(window: window())
            let startedAt = Date()
            appleTranslateLog.log("asking to download \(state.code, privacy: .public)->\(self.target, privacy: .public)")
            observer.start()
            do {
                let translated = try await translate(job.text)
                observer.stop()
                job.completion(translated, nil)
                await languageBecameReady(state, how: String(format: "download sheet accepted, on screen %.1fs", observer.visibleSeconds))
            } catch {
                observer.stop()
                if Self.wasCancelled(error) {
                    // SwiftUI cancelled the action (host left the window) and took the sheet
                    // with it. Not the user's answer: the next consumer asks again.
                    appleTranslateLog.log("download prompt for \(state.code, privacy: .public) cancelled with its host; will ask again")
                    state.queue.pushFront(job)
                    return
                }
                job.completion(nil, promptFailed(state, error: error as NSError, observer: observer, startedAt: startedAt))
            }
        }
    }

    private enum PromptGate {
        case prompt
        case skip(NSError)
        case cancelled
    }

    /// Whether `job` may raise the download sheet now. Holds it (polling) until there's
    /// a moment the sheet can be seen, and drops it if the screen that asked went away.
    private func promptGate(_ state: SourceState, _ job: Job, route: Route) async -> PromptGate {
        let code = state.code
        if state.declinedByUser {
            return .skip(Self.makeError(code: 305, "\(code) download declined"))
        }
        if state.gaveUp {
            return .skip(Self.makeError(code: 305, "\(code) download prompt unavailable"))
        }
        if let retryAfter = state.promptRetryAfter, retryAfter > Date() {
            return .skip(Self.retrySoonError(code: 308, "\(code) download prompt cooling down"))
        }
        // Only one distinct snippet so far — likely a one-off misdetection. Don't prompt
        // yet; wait for a second distinct text to corroborate.
        state.corroboration.insert(job.text.hashValue)
        if state.corroboration.count < ApolloAppleDownloadPrompt.corroboratingTexts {
            return .skip(Self.makeError(code: 306, "\(code) awaiting corroboration"))
        }

        let deadline = job.enqueuedAt.addingTimeInterval(ApolloAppleDownloadPrompt.settleWindow)
        var reportedBlocker: String?
        while true {
            if Task.isCancelled { return .cancelled }
            if let transition = job.transition, transition.cancelled {
                // Asked for mid-transition by the screen being revealed (a swipe-back), and
                // the transition was cancelled: that screen never showed. Leave the prompt
                // armed for the next text in this language.
                appleTranslateLog.log("holding the \(code, privacy: .public) download prompt: the screen that asked was dismissed (cancelled transition)")
                return .skip(Self.retrySoonError(code: 307, "\(code) download prompt deferred"))
            }
            var blocker: String?
            if let transition = job.transition, !transition.finished { blocker = "transition in flight" }
            if blocker == nil { blocker = promptBlocker(route: route) }
            guard let blocker else { return .prompt }
            if Date() >= deadline {
                appleTranslateLog.log("holding the \(code, privacy: .public) download prompt: \(blocker, privacy: .public)")
                return .skip(Self.retrySoonError(code: 307, "\(code) download prompt deferred"))
            }
            if blocker != reportedBlocker {
                reportedBlocker = blocker
                appleTranslateLog.log("waiting to ask to download \(code, privacy: .public): \(blocker, privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: ApolloAppleDownloadPrompt.pollNanoseconds)
        }
    }

    /// Why a sheet presented from the host now wouldn't be seen, or nil if it would.
    private func promptBlocker(route: Route) -> String? {
        guard UIApplication.shared.applicationState == .active else { return "app not active" }
        let host = hostForPrompt(route: route)
        guard let host, host.isAttached, let parent = host.parent, let root = host.window?.rootViewController else {
            return "host not in a window"
        }
        var top = root
        while let presented = top.presentedViewController {
            if presented.isBeingPresented || presented.isBeingDismissed { return "presentation in flight" }
            top = presented
        }
        // UIKit refuses a sheet from under another modal ("already presenting").
        var ancestor: UIViewController? = parent
        while let vc = ancestor, vc !== top { ancestor = vc.parent }
        if ancestor == nil { return "covered by \(String(describing: type(of: top)))" }
        if ApolloAppleUIState.inFlightTransition(under: top) != nil { return "transition in flight" }
        return nil
    }

    private func hostForPrompt(route: Route) -> ApolloAppleHiddenHost? {
        #if APOLLO_SIM_BUILD
        if route == .simPrompt { return simPromptHost }
        #endif
        return probeHost
    }

    /// Settles a prompting translate that threw. Only "cancelled" from a sheet that was
    /// on screen long enough to be read is the user's "no" — a sheet taken away sooner,
    /// or a download that failed after the user accepted, gets asked again.
    private func promptFailed(_ state: SourceState, error: NSError, observer: ApolloAppleSheetObserver,
                              startedAt: Date) -> NSError {
        let code = state.code
        let shown = observer.visibleSeconds
        let sheet = observer.sheetClass ?? "none"
        let cause = "\(error.domain)#\(error.code)"
        logDownloadPromptTrail(since: startedAt, source: code)
        let cancelled = error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
        if cancelled && shown >= ApolloAppleDownloadPrompt.declineVisibleSeconds {
            state.declinedByUser = true
            appleTranslateLog.log("download sheet for \(code, privacy: .public) dismissed after \(String(format: "%.1f", shown), privacy: .public)s (\(cause, privacy: .public)); treating it as a decline for this session")
            return Self.makeError(code: 305, "\(code) download declined")
        }
        state.interruptedPrompts += 1
        if state.interruptedPrompts >= ApolloAppleDownloadPrompt.maxInterruptedPrompts {
            state.gaveUp = true
            appleTranslateLog.log("download prompt for \(code, privacy: .public) ended before an answer \(state.interruptedPrompts) times (\(cause, privacy: .public), sheet \(sheet, privacy: .public) \(String(format: "%.1f", shown), privacy: .public)s); not asking again until Apollo comes back to the foreground")
            return Self.makeError(code: 305, "\(code) download prompt unavailable")
        }
        state.promptRetryAfter = Date().addingTimeInterval(ApolloAppleDownloadPrompt.retryDelay)
        appleTranslateLog.log("download prompt for \(code, privacy: .public) ended before an answer (\(cause, privacy: .public), sheet \(sheet, privacy: .public) \(String(format: "%.1f", shown), privacy: .public)s); not a decline, will ask again")
        return Self.retrySoonError(code: 307, "\(code) download prompt interrupted")
    }

    /// The pair can translate now: clear the prompt bookkeeping, tell the Objective-C
    /// side (so text that failed while the model was missing retranslates), and move
    /// the source off the view-bound hosted session where the headless one exists.
    private func languageBecameReady(_ state: SourceState, how: String) async {
        guard !state.installed else { return }
        state.installed = true
        state.declinedByUser = false
        state.gaveUp = false
        state.interruptedPrompts = 0
        state.promptRetryAfter = nil
        state.corroboration.removeAll()
        appleTranslateLog.log("\(state.code, privacy: .public)->\(self.target, privacy: .public) ready (\(how, privacy: .public))")
        NotificationCenter.default.post(name: ApolloAppleTranslator.languageReadyNotification, object: nil,
                                        userInfo: ["source": state.code])
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), state.route == .hosted {
            let status = await LanguageAvailability().status(from: makeLanguage(state.code), to: makeLanguage(target))
            guard status == .installed, states[state.code] === state, state.route == .hosted else { return }
            sources.removeAll { $0 == state.code }
            state.config = nil
            startDirect(state, reason: "downloaded")
            tearDownProbeHostIfIdle()
        }
        #endif
    }

    private func appDidBecomeActive() {
        for (code, state) in states {
            if state.route == .unavailable {
                states[code] = nil   // re-resolve on next use
                continue
            }
            guard !state.installed, state.route.promptsForDownload else { continue }
            // A foreground is a fresh chance for a prompt that kept getting interrupted.
            // A real decline stays until the language turns up installed.
            state.gaveUp = false
            state.interruptedPrompts = 0
            state.promptRetryAfter = nil
            guard state.route == .hosted else { continue }
            let tgt = target
            Task { @MainActor in
                let status = await LanguageAvailability().status(from: self.makeLanguage(code), to: self.makeLanguage(tgt))
                guard status == .installed, self.states[code] === state, !state.installed else { return }
                await self.languageBecameReady(state, how: "installed outside Apollo")
            }
        }
    }

    // MARK: Hidden host

    private func ensureProbeHost() {
        if let host = probeHost {
            if host.isAttached {
                restartDeadHostedRuns(reason: "a request found it idle")
                return
            }
            // Off-window under a full-screen modal: it comes back with the root's view.
            if Self.isStillHostedByRoot(host) { return }
            appleTranslateLog.log("root view controller changed; reinstalling the Apple translation host")
            host.remove()
            probeHost = nil
        }
        let hosting = UIHostingController(rootView: ApolloTranslationProbeHost(coordinator: self))
        probeHost = Self.installHiddenHost(hosting, label: "Apple translation host") { [weak self] window in
            guard window != nil else { return }
            Task { @MainActor in self?.restartDeadHostedRuns(reason: "host back in a window") }
        }
    }

    /// SwiftUI cancels a hosted action when its host leaves the window and doesn't re-run
    /// it for an unchanged configuration when the host comes back, so a consumer that
    /// ran and died stays dead. Invalidating its configuration restarts it.
    private func restartDeadHostedRuns(reason: String) {
        guard probeHost?.isAttached == true else { return }
        var restarted: [String] = []
        for code in sources {
            guard let state = states[code], state.route == .hosted, state.runsStarted > 0,
                  state.liveRunToken == nil, !state.restartRequested, state.config != nil else { continue }
            state.restartRequested = true
            state.config?.invalidate()
            restarted.append(code)
        }
        guard !restarted.isEmpty else { return }
        appleTranslateLog.log("restarting hosted Apple sessions \(restarted.joined(separator: ","), privacy: .public) (\(reason, privacy: .public))")
        objectWillChange.send()
    }

    private func tearDownProbeHostIfIdle() {
        guard sources.isEmpty, let host = probeHost else { return }
        host.remove()
        probeHost = nil
    }

    /// The host lives in the window's ROOT view controller, never in a presented one: a
    /// modal (What's New, an alert, a share sheet) comes and goes and would take the host
    /// — and every hosted session — with it, and a download sheet raised from inside one
    /// stacks over unrelated UI. While a modal covers the root, `promptBlocker` holds
    /// the prompt instead.
    private static func installHiddenHost(_ hosting: UIViewController, label: String,
                                          onWindowChange: @escaping (UIWindow?) -> Void) -> ApolloAppleHiddenHost? {
        guard let root = activeWindow()?.rootViewController else {
            appleTranslateLog.error("no key window/root VC yet; deferring \(label, privacy: .public)")
            return nil
        }
        let host = ApolloAppleHiddenHost(hosting: hosting, onWindowChange: onWindowChange)
        host.install(in: root)
        appleTranslateLog.log("installed \(label, privacy: .public) in \(String(describing: type(of: root)), privacy: .public)")
        return host
    }

    private static func isStillHostedByRoot(_ host: ApolloAppleHiddenHost) -> Bool {
        guard let parent = host.parent else { return false }
        return parent === activeWindow()?.rootViewController
    }

    static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.first?.windows.first
    }

    private static func wasCancelled(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    private static func makeError(code: Int, _ message: String) -> NSError {
        NSError(domain: "ApolloAppleTranslation", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A failure that isn't a verdict on the text: the prompt was held back or cut off
    /// and will be offered again, so callers shouldn't park the text in a cooldown.
    private static func retrySoonError(code: Int, _ message: String) -> NSError {
        NSError(domain: "ApolloAppleTranslation", code: code,
                userInfo: [NSLocalizedDescriptionKey: message,
                           ApolloAppleTranslator.retrySoonErrorKey: true])
    }

    // MARK: Simulator

    #if APOLLO_SIM_BUILD
    // SIMULATOR: the iOS Translation engine does not exist in sim runtimes (status is
    // .unsupported for every pair), but the identical engine runs on the host Mac.
    // Route through the local test bridge (scripts/apple-translate-bridge.swift,
    // 127.0.0.1:8765) so the Apple provider is fully exercisable in the sim.
    // APOLLOFIX_APPLE_SIM_DOWNLOAD=zh,pt (or *) additionally puts those languages behind
    // a stand-in for Apple's download sheet — a SwiftUI sheet presented from a hidden
    // host the same way, whose dismissal throws the same "cancelled" error — so the
    // download prompt flow is testable too. Dev-only: compiled out of device builds.
    private static let simDownloadLanguages: Set<String> = Set(
        (ProcessInfo.processInfo.environment["APOLLOFIX_APPLE_SIM_DOWNLOAD"] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    private var simPromptHost: ApolloAppleHiddenHost?
    private let simPrompt = ApolloAppleSimDownloadPrompt()

    private func startSimRoute(_ state: SourceState) {
        let code = state.code
        let tgt = target
        if Self.simDownloadLanguages.contains(code) || Self.simDownloadLanguages.contains("*") {
            state.route = .simPrompt
            appleTranslateLog.log("sim: \(code, privacy: .public)->\(tgt, privacy: .public) needs a (simulated) download, then the host bridge")
            ensureSimPromptHost()
            Task { @MainActor in
                await self.consume(state, route: .simPrompt, window: self.simPromptHost?.window) { text in
                    if !state.installed { try await self.presentSimDownloadSheet(for: code) }
                    return try await Self.hostBridgeTranslate(text: text, source: code, target: tgt)
                }
            }
            return
        }
        state.route = .simBridge
        state.installed = true
        appleTranslateLog.log("sim: bridging \(code, privacy: .public)->\(tgt, privacy: .public) to host Apple engine")
        Task { @MainActor in await self.drainViaHostBridge(state, target: tgt) }
    }

    private func ensureSimPromptHost() {
        if let host = simPromptHost, host.isAttached || Self.isStillHostedByRoot(host) { return }
        simPromptHost?.remove()
        let hosting = UIHostingController(rootView: ApolloAppleSimDownloadPromptHost(model: simPrompt))
        simPromptHost = Self.installHiddenHost(hosting, label: "simulated download sheet host") { _ in }
    }

    private func presentSimDownloadSheet(for code: String) async throws {
        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            simPrompt.ask(code) { continuation.resume(returning: $0) }
        }
        if !accepted { throw CocoaError(.userCancelled) }   // what Apple's sheet throws when dismissed
    }

    // Drain a source's jobs through the host Mac's Apple translation engine. The sim
    // shares the host's loopback, so 127.0.0.1 reaches the Mac directly.
    private func drainViaHostBridge(_ state: SourceState, target tgt: String) async {
        while let job = await state.queue.next() {
            do {
                let translated = try await Self.hostBridgeTranslate(text: job.text, source: state.code, target: tgt)
                job.completion(translated, nil)
            } catch {
                appleTranslateLog.error("sim bridge failed (\(state.code, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                job.completion(nil, Self.makeError(code: 309,
                    "Apple sim bridge: \(error.localizedDescription). Run scripts/apple-bridge.sh on the Mac."))
            }
        }
    }

    private static func hostBridgeTranslate(text: String, source: String, target: String) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: ["q": text, "source": source, "target": target])
        let (data, response) = try await URLSession.shared.data(for: request)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let translated = obj?["translatedText"] as? String, !translated.isEmpty else {
            throw makeError(code: 310, (obj?["error"] as? String) ?? "bridge returned no translation")
        }
        return translated
    }
    #endif
}

// MARK: - Hidden probe host

/// Carries one `.translationTask` per hosted source language. Each task vends a
/// `TranslationSession` for that source.
@available(iOS 18.0, *)
private struct ApolloTranslationProbeHost: View {
    @ObservedObject var coordinator: ApolloAppleTranslationCoordinator

    var body: some View {
        ZStack {
            ForEach(coordinator.sources, id: \.self) { src in
                if let cfg = coordinator.configuration(for: src) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .translationTask(cfg) { session in
                            await coordinator.run(source: src, session: session)
                        }
                }
            }
        }
        .frame(width: 1, height: 1)
    }
}

#if APOLLO_SIM_BUILD
/// Simulator stand-in for Apple's download sheet (see `startSimRoute`).
@available(iOS 18.0, *)
@MainActor
private final class ApolloAppleSimDownloadPrompt: ObservableObject {
    @Published private(set) var language: String?
    private var completion: ((Bool) -> Void)?

    func ask(_ code: String, completion: @escaping (Bool) -> Void) {
        finish(false)
        self.completion = completion
        language = code
    }

    func finish(_ accepted: Bool) {
        let done = completion
        completion = nil
        language = nil
        done?(accepted)
    }
}

@available(iOS 18.0, *)
private struct ApolloAppleSimDownloadPromptHost: View {
    @ObservedObject var model: ApolloAppleSimDownloadPrompt

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            // Same shape as the .translationTask sheet: an isPresented binding whose
            // setter(false) — swipe-down, a dismissal from elsewhere, a refused
            // presentation — reports "cancelled".
            .sheet(isPresented: Binding(get: { model.language != nil },
                                        set: { if !$0 { model.finish(false) } })) {
                VStack(spacing: 16) {
                    Text("Simulated Apple download").font(.headline)
                    Text("Download \(Locale.current.localizedString(forLanguageCode: model.language ?? "") ?? "language")?")
                    Button("Download") { model.finish(true) }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel) { model.finish(false) }
                }
                .padding()
                .presentationDetents([.medium])
            }
    }
}
#endif

#endif

// MARK: - Objective-C bridge

/// Stable, always-present Objective-C entry point. Defined unconditionally (no
/// `@available` on the class) so the generated `ApolloReborn-Swift.h` always
/// declares it; the iOS-18 gate lives inside.
@objc(ApolloAppleTranslator)
public final class ApolloAppleTranslator: NSObject {

    /// Posted on the main thread when an Apple language pair becomes usable mid-session
    /// (downloaded from Apple's sheet, or in Settings while Apollo was in the background).
    /// userInfo["source"] is the source language code.
    @objc public static let languageReadyNotification = Notification.Name("ApolloAppleTranslationLanguageReady")

    /// userInfo key (true) on failures that aren't a verdict on the text — the download
    /// prompt was held back or cut off and will be offered again.
    @objc public static let retrySoonErrorKey = "ApolloAppleTranslationRetrySoon"

    /// `source` and `target` are normalized language codes (e.g. "pt", "en").
    /// `completion` is always invoked on the main thread.
    @objc public static func translate(_ text: String,
                                       from source: String,
                                       to target: String,
                                       completion: @escaping (String?, NSError?) -> Void) {
        #if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
        if #available(iOS 18.0, *) {
            Task { @MainActor in
                ApolloAppleTranslationCoordinator.shared.enqueue(text: text, source: source, target: target, completion: completion)
            }
            return
        }
        #endif
        completion(nil, NSError(domain: "ApolloAppleTranslation", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Apple translation requires iOS 18 or later"]))
    }

    /// Whether the on-device Apple translation backend can run on this OS (iOS 18+).
    @objc public static func isSupported() -> Bool {
        #if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }

    // MARK: - Supported languages (for the Target Language picker)
    //
    // Apple Translation only covers ~20 languages (far fewer than Google), so when
    // Apple is the selected provider the settings picker should offer only those.
    // `supportedLanguages` is async, so we cache the base codes — both in memory and
    // (across launches) in UserDefaults — and expose a synchronous accessor the
    // Objective-C picker reads. `warmSupportedLanguages()` kicks off the refresh.

    // Serial queue (not NSLock) so the cache can be touched from the async warm
    // Task without tripping Swift's "lock unavailable from async contexts" rule.
    private static let supportedCodesQueue = DispatchQueue(label: "apollofix.appleTranslate.supportedCodes")
    private static var cachedSupportedCodesStorage: [String] = []
    private static var supportedWarmStarted = false
    private static let supportedCodesDefaultsKey = "ApolloAppleSupportedLangCodes"

    /// Lowercase ISO base codes Apple can translate (e.g. "en", "pt", "ja").
    /// Empty until the first warm completes; seeded instantly from the persisted
    /// cache on subsequent launches.
    @objc public static func supportedLanguageCodes() -> [String] {
        return supportedCodesQueue.sync { cachedSupportedCodesStorage }
    }

    /// Kicks off (once per launch) an async query of Apple's supported languages and
    /// caches the base codes. Cheap to call repeatedly; safe from the main thread.
    @objc public static func warmSupportedLanguages() {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            let shouldStart: Bool = supportedCodesQueue.sync {
                let alreadyStarted = supportedWarmStarted
                supportedWarmStarted = true
                if cachedSupportedCodesStorage.isEmpty,
                   let persisted = UserDefaults.standard.array(forKey: supportedCodesDefaultsKey) as? [String] {
                    cachedSupportedCodesStorage = persisted
                }
                return !alreadyStarted
            }
            guard shouldStart else { return }

            Task.detached(priority: .utility) {
                let langs = await LanguageAvailability().supportedLanguages
                var set = Set<String>()
                for lang in langs {
                    if let code = lang.languageCode?.identifier.lowercased(), !code.isEmpty {
                        set.insert(code)
                    }
                }
                let codes = Array(set).sorted()
                guard !codes.isEmpty else { return }
                supportedCodesQueue.sync { cachedSupportedCodesStorage = codes }
                UserDefaults.standard.set(codes, forKey: supportedCodesDefaultsKey)
            }
        }
        #endif
    }
}

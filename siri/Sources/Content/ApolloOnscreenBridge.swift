import AppIntents
import Foundation
import UIKit

/// Onscreen context, structured the way Apple's samples do it:
/// - a detail screen's single focus (the open post) goes on its NSUserActivity;
/// - each visible row (feed post, the post header, each comment) gets its own
///   view annotation, so "this comment" / "the second one" resolve to rows.
/// Only records resolvable from the catalogue or this session's context are
/// annotated, and everything clears on view exit, opt-out or account change.
@MainActor
@objc(ApolloOnscreenBridge)
final class ApolloOnscreenBridge: NSObject {
    private enum Kind { case post, comment }
    private final class Binding: NSObject {
        let id: String
        let kind: Kind
        let account: String
        let detail: Bool
        var activity: NSUserActivity?
        var ownsActivity = false
        var annotated = false
        var activityAnnotated = false
        var donated = false
        var generation = 0
        init(id: String, kind: Kind, account: String, detail: Bool, activity: NSUserActivity?) {
            self.id = id; self.kind = kind; self.account = account; self.detail = detail; self.activity = activity
        }
    }
    private static let bindings = NSMapTable<UIView, Binding>.weakToStrongObjects()

    /// `detail` = the post detail screen itself: annotate its user activity
    /// (screen focus), not the whole root view. Rows pass `detail: false`.
    @objc static func showPost(_ fullName: String, inView view: UIView, activity: NSUserActivity?, detail: Bool) {
        bind(id: ApolloContentRecord.identifier(["kind": "t3", "name": fullName]), kind: .post,
             view: view, activity: activity, detail: detail)
    }

    @objc static func showComment(_ fullName: String, inView view: UIView) {
        bind(id: ApolloCommentRecord.identifier(fullName), kind: .comment, view: view, activity: nil, detail: false)
    }

    private static func bind(id: String?, kind: Kind, view: UIView, activity: NSUserActivity?, detail: Bool) {
        guard view.window != nil, UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey),
              let account = ApolloContentBridge.accountState().fingerprint, let id else {
            ApolloSiriLog.onscreen("Skipped; view, indexing, account or identifier unavailable", detail: detail)
            hideView(view)
            return
        }
        if let existing = bindings.object(forKey: view), existing.id == id, existing.account == account,
           !detail || activity == nil || existing.activity === activity { return }
        hideView(view)
        let binding = Binding(id: id, kind: kind, account: account, detail: detail, activity: activity)
        ApolloSiriLog.onscreen("Binding created; awaiting eligible record", detail: detail)
        bindings.setObject(binding, forKey: view)
        update(view, binding: binding)
    }

    @objc static func hideView(_ view: UIView) {
        guard let binding = bindings.object(forKey: view) else { return }
        removeAnnotation(view, binding: binding)
        bindings.removeObject(forKey: view)
    }

    /// Revalidates every live binding (content/eligibility/account changed).
    /// Bindings are kept, so still-visible unaffected rows re-annotate.
    static func refresh() {
        for view in bindings.keyEnumerator().allObjects.compactMap({ $0 as? UIView }) {
            guard let binding = bindings.object(forKey: view) else { continue }
            binding.generation += 1
            // Remove synchronously before validating again, so logout or hide
            // cannot leave an old annotation while the actor lookup is pending.
            removeAnnotation(view, binding: binding)
            update(view, binding: binding)
        }
    }

    private static func removeAnnotation(_ view: UIView, binding: Binding) {
        if binding.annotated {
            view.appEntityIdentifier = nil
            ApolloSiriLog.onscreen("Annotation removed", detail: binding.detail)
        }
        if binding.activityAnnotated { binding.activity?.appEntityIdentifier = nil }
        if binding.ownsActivity { binding.activity?.resignCurrent() }
        binding.annotated = false
        binding.activityAnnotated = false
    }

    private static func update(_ view: UIView, binding: Binding) {
        let generation = binding.generation
        Task { @MainActor [weak view] in
            let annotation: EntityIdentifier
            var post: ApolloContentRecord?
            do {
                switch binding.kind {
                case .post:
                    post = try await ApolloContentService.shared.onscreenPost(binding.id, account: binding.account)
                    annotation = EntityIdentifier(for: ApolloPostEntity.self, identifier: binding.id)
                case .comment:
                    guard try await ApolloContentService.shared.onscreenComment(binding.id, account: binding.account) != nil else {
                        ApolloSiriLog.onscreen("Skipped; comment not in session context", detail: false)
                        return
                    }
                    annotation = EntityIdentifier(for: ApolloCommentEntity.self, identifier: binding.id)
                }
            } catch {
                ApolloSiriLog.onscreen("Record lookup failed", detail: binding.detail)
                return
            }
            guard let view, bindings.object(forKey: view) === binding, generation == binding.generation else { return }
            guard view.window != nil, binding.kind == .comment || post != nil,
                  UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey),
                  ApolloContentBridge.accountState().fingerprint == binding.account else {
                ApolloSiriLog.onscreen("Skipped; no eligible record or view/account changed", detail: binding.detail)
                return
            }
            if binding.detail {
                annotateActivity(binding, annotation: annotation, title: post?.title ?? "")
                donateOpenIfUserInitiated(binding, post: post)
                return
            }
            guard view.appEntityIdentifier == nil || binding.annotated else {
                ApolloSiriLog.onscreen("Skipped; view already has another annotation", detail: false)
                return
            }
            view.appEntityIdentifier = annotation
            binding.annotated = true
            ApolloSiriLog.onscreen(binding.kind == .comment ? "Comment entity attached" : "Post entity attached", detail: false)
        }
    }

    /// NSUserActivity carries the one entity the screen is about (Apple:
    /// "if the views reflect only one entity … deliver it using NSUserActivity").
    private static func annotateActivity(_ binding: Binding, annotation: EntityIdentifier, title: String) {
        if binding.activity == nil {
            let activity = NSUserActivity(activityType: "app.apolloreborn.viewPost")
            activity.isEligibleForSearch = false
            activity.isEligibleForHandoff = false
            activity.title = title
            binding.activity = activity
            binding.ownsActivity = true
        }
        guard binding.activity?.appEntityIdentifier == nil || binding.activityAnnotated else { return }
        binding.activity?.appEntityIdentifier = annotation
        binding.activityAnnotated = true
        if binding.ownsActivity { binding.activity?.becomeCurrent() }
        ApolloSiriLog.onscreen(binding.ownsActivity ? "Owned activity annotated and made current" : "Existing activity annotated", detail: true)
    }

    /// Opening a post from Apollo's UI is a meaningful action; donate it via the
    /// schema open intent so Apple Intelligence learns what this person reads.
    /// Apple: donate only UI-initiated actions (not Siri/Shortcuts-driven ones),
    /// once per completed action, never per feed row.
    private static func donateOpenIfUserInitiated(_ binding: Binding, post: ApolloContentRecord?) {
        guard !binding.donated, let post else { return }
        binding.donated = true
        guard !ApolloSiriNavigation.intentNavigationIsRecent else {
            ApolloSiriLog.onscreen("Donation skipped; navigation came from an intent", detail: true)
            return
        }
        let intent = OpenApolloPostIntent(target: ApolloPostEntity(post))
        Task {
            do {
                _ = try await IntentDonationManager.shared.donate(intent: intent)
                ApolloSiriLog.onscreen("Open-post interaction donated", detail: true)
            } catch {
                ApolloSiriLog.onscreen("Open-post donation failed", detail: true)
            }
        }
    }
}

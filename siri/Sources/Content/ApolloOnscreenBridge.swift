import AppIntents
import Foundation
import UIKit

/// Only currently visible, eligible catalogue records receive annotations.
@MainActor
@objc(ApolloOnscreenBridge)
final class ApolloOnscreenBridge: NSObject {
    private final class Binding: NSObject {
        let id: String
        let account: String
        let detail: Bool
        var activity: NSUserActivity?
        var ownsActivity = false
        var annotated = false
        var activityAnnotated = false
        var donated = false
        var generation = 0
        init(id: String, account: String, detail: Bool, activity: NSUserActivity?) {
            self.id = id; self.account = account; self.detail = detail; self.activity = activity
        }
    }
    private static let bindings = NSMapTable<UIView, Binding>.weakToStrongObjects()

    @objc static func showPost(_ fullName: String, inView view: UIView, activity: NSUserActivity?, detail: Bool) {
        guard view.window != nil, UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey),
              let account = ApolloContentBridge.accountState().fingerprint,
              let id = ApolloContentRecord.identifier(["kind": "t3", "name": fullName]) else {
            ApolloSiriLog.onscreen("Skipped; view, indexing, account or identifier unavailable", detail: detail)
            hideView(view)
            return
        }
        if let existing = bindings.object(forKey: view), existing.id == id, existing.account == account,
           !detail || activity == nil || existing.activity === activity { return }
        hideView(view)
        let binding = Binding(id: id, account: account, detail: detail, activity: activity)
        ApolloSiriLog.onscreen("Binding created; awaiting eligible record", detail: detail)
        bindings.setObject(binding, forKey: view)
        update(view, binding: binding)
    }

    @objc static func hideView(_ view: UIView) {
        guard let binding = bindings.object(forKey: view) else { return }
        removeAnnotation(view, binding: binding)
        bindings.removeObject(forKey: view)
    }

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
            let records: [ApolloContentRecord]
            do {
                records = try await ApolloContentService.shared.snippetRecords(identifiers: [binding.id], account: binding.account)
            } catch {
                ApolloSiriLog.onscreen("Record lookup failed", detail: binding.detail)
                return
            }
            guard let view, bindings.object(forKey: view) === binding, generation == binding.generation else { return }
            guard view.window != nil, let record = records.first,
                  UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey),
                  ApolloContentBridge.accountState().fingerprint == binding.account else {
                ApolloSiriLog.onscreen("Skipped; no eligible record or view/account changed", detail: binding.detail)
                return
            }
            let experimental = UserDefaults.standard.bool(forKey: ApolloContentBridge.schemaExperimentKey)
            let annotation = experimental
                ? EntityIdentifier(for: ApolloExperimentalPostNote.self, identifier: ApolloExperimentalPostNote.prefix + record.id)
                : EntityIdentifier(for: ApolloPostEntity.self, identifier: record.id)
            guard view.appEntityIdentifier == nil || binding.annotated else {
                ApolloSiriLog.onscreen("Skipped; view already has another annotation", detail: binding.detail)
                return
            }
            view.appEntityIdentifier = annotation
            ApolloSiriLog.onscreen(experimental ? "Notes entity attached" : "Post entity attached", detail: binding.detail)
            if binding.detail {
                if binding.activity == nil {
                    let activity = NSUserActivity(activityType: "app.apolloreborn.viewPost")
                    activity.isEligibleForSearch = false
                    activity.isEligibleForHandoff = false
                    activity.title = record.title
                    binding.activity = activity
                    binding.ownsActivity = true
                }
                if binding.activity?.appEntityIdentifier == nil || binding.activityAnnotated {
                    binding.activity?.appEntityIdentifier = annotation
                    binding.activityAnnotated = true
                    if binding.ownsActivity { binding.activity?.becomeCurrent() }
                    ApolloSiriLog.onscreen(binding.ownsActivity ? "Owned activity annotated and made current" : "Existing activity annotated", detail: true)
                }
            }
            binding.annotated = true
            // Opening a post is a meaningful user action; donate it through the
            // schema-conforming open intent so Apple Intelligence learns what
            // this person reads (Apple: donate accurately, not per feed row).
            if binding.detail, !experimental, !binding.donated {
                binding.donated = true
                let intent = OpenApolloPostIntent(target: ApolloPostEntity(record))
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
    }
}

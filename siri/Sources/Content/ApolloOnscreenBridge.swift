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
            hideView(view)
            return
        }
        if let existing = bindings.object(forKey: view), existing.id == id, existing.account == account,
           !detail || activity == nil || existing.activity === activity { return }
        hideView(view)
        let binding = Binding(id: id, account: account, detail: detail, activity: activity)
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

    static func clear() {
        for view in bindings.keyEnumerator().allObjects.compactMap({ $0 as? UIView }) { hideView(view) }
    }

    private static func removeAnnotation(_ view: UIView, binding: Binding) {
        if binding.annotated {
            view.appEntityIdentifier = nil
        }
        if binding.activityAnnotated { binding.activity?.appEntityIdentifier = nil }
        if binding.ownsActivity { binding.activity?.resignCurrent() }
        binding.annotated = false
        binding.activityAnnotated = false
    }

    private static func update(_ view: UIView, binding: Binding) {
        let generation = binding.generation
        Task { @MainActor [weak view] in
            let records = try? await ApolloContentService.shared.snippetRecords(identifiers: [binding.id], account: binding.account)
            guard let view, bindings.object(forKey: view) === binding, generation == binding.generation else { return }
            guard view.window != nil, let record = records?.first,
                  UserDefaults.standard.bool(forKey: ApolloContentBridge.enabledKey),
                  ApolloContentBridge.accountState().fingerprint == binding.account else { return }
            let experimental = UserDefaults.standard.bool(forKey: ApolloContentBridge.schemaExperimentKey)
            let annotation = experimental
                ? EntityIdentifier(for: ApolloExperimentalPostNote.self, identifier: ApolloExperimentalPostNote.prefix + record.id)
                : EntityIdentifier(for: ApolloPostEntity.self, identifier: record.id)
            guard view.appEntityIdentifier == nil || binding.annotated else { return }
            view.appEntityIdentifier = annotation
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
                }
            }
            binding.annotated = true
        }
    }
}

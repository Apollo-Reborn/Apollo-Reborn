import Foundation
import WidgetKit

/// Credentials the widget needs to talk to Reddit, bundled into a single
/// copy/paste "setup code" that the Apollo Reborn tweak generates in
/// Settings → Apollo Reborn → "Copy Widget Setup Code".
///
/// Channel rationale: a widget extension and the host app live in separate
/// sandboxes. Sharing data normally needs an App Group / shared keychain
/// entitlement, which third-party sideload signers (Feather/AltStore/…) can't
/// reliably claim for `group.com.christianselig.apollo`. A one-time manual
/// paste sidesteps that entirely and works identically on every signer.
///
/// Format: base64( JSON { "v", "clientID", "userAgent", … } ).
///   v1  – clientID + userAgent: the app-only tier every widget started with.
///   v2  – adds `refreshToken` + `username` (copied "with account"), which is
///         what Home and the user's own multireddits need, `clientSecret`
///         for "web app" API keys, and `issued` (unix seconds the code was
///         copied) so the most recently copied code can win — see `resolve`.
///         Older widget builds ignore the extra keys.
struct SetupCode: Codable {
    var v: Int
    var clientID: String
    var userAgent: String?
    var clientSecret: String?
    var refreshToken: String?
    var username: String?
    var issued: Double?

    var hasAccount: Bool { !(refreshToken ?? "").isEmpty }

    /// Stable, non-secret id of the signed-in account (a hash of client id +
    /// refresh token). Scopes every per-account cache — see `FeedSource
    /// .cacheKey(account:)` — so switching accounts can never surface the
    /// previous account's Home/multireddit posts. Nil without an account.
    var accountKey: String? {
        guard hasAccount, let refreshToken else { return nil }
        return String(fnv1a("\(clientID):\(refreshToken)"), radix: 36)
    }

    /// Decode a pasted code. Accepts either the base64 setup code OR, as a
    /// forgiving fallback, a bare Reddit client_id string (in which case a
    /// generic User-Agent is used).
    static func parse(_ raw: String?) -> SetupCode? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // Primary path: base64-encoded JSON. Every code starts with "eyJ"
        // (base64 of `{"`); a keyboard's auto-capitalization turns a typed one
        // into "EyJ", which is different base64 — undo that one mangling.
        var candidates = [raw]
        if raw.hasPrefix("EyJ") { candidates.append("eyJ" + raw.dropFirst(3)) }
        for candidate in candidates {
            if let data = Data(base64Encoded: candidate),
               let decoded = try? JSONDecoder().decode(SetupCode.self, from: data),
               !decoded.clientID.isEmpty {
                return decoded
            }
        }

        // Fallback: a raw client_id (Reddit ids are short, no spaces).
        if raw.count >= 8, raw.count <= 40,
           raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return SetupCode(v: 1, clientID: raw)
        }

        return nil
    }

    var resolvedUserAgent: String {
        if let ua = userAgent, !ua.isEmpty { return ua }
        return "ApolloRebornWidgets/1.0"
    }

    /// Resolve a widget's setup code, sharing it across all widgets.
    ///
    /// Every Reborn widget lives in the same extension process and so shares
    /// one `UserDefaults`. The first widget you paste a valid code into stashes
    /// it; any other widget whose own field is blank falls back to that stash.
    /// Net effect: paste the code once into ANY widget and the rest pick it up
    /// on their next refresh — no per-widget pasting, no App Group needed.
    ///
    /// **The most recently copied code wins everywhere.** Codes carry the time
    /// they were copied (`issued`), so pasting a newer code into ANY widget —
    /// with account, without account, or for another account — replaces the
    /// stash for every widget, while the older codes still sitting in other
    /// widgets' fields never drag it back (no reload ping-pong, and "Copy
    /// without Account" pasted once is how account access gets removed).
    /// Codes from older tweak builds have no timestamp: they're honoured in
    /// their own widget but never replace a timestamped stash.
    static func resolve(_ raw: String?) -> SetupCode? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sharedRaw = SharedSetup.load()
        let shared = sharedRaw.flatMap(parse)
        guard !trimmed.isEmpty, let own = parse(trimmed) else { return shared }
        guard let shared, trimmed != sharedRaw else {
            if shared == nil { SharedSetup.store(trimmed, replacing: nil) }
            return own
        }
        if (own.issued ?? 0) > (shared.issued ?? 0) {
            SharedSetup.store(trimmed, replacing: shared)
            return own
        }
        if let sharedIssued = shared.issued, (own.issued ?? 0) < sharedIssued {
            return shared                        // a deliberately later paste elsewhere
        }
        return own                               // neither dated: each widget keeps its own
    }
}

/// Cross-widget stash for the setup code (shared `UserDefaults` within the
/// single widget extension; not an App Group).
enum SharedSetup {
    private static let defaults = UserDefaults.standard
    private static let key = "rw.sharedSetupCode"

    /// Replace the stash with a newer code. When the account it carried is
    /// gone (a plain code, or a different account), everything cached for
    /// that account — posts, rotation offsets, Calendar picks, multireddit
    /// names, the user token — is dropped so nothing of it can resurface.
    /// Then every widget reloads so blank-field widgets re-resolve at once.
    static func store(_ code: String, replacing previous: SetupCode?) {
        guard defaults.string(forKey: key) != code else { return }
        defaults.set(code, forKey: key)
        if let old = previous?.accountKey, old != SetupCode.parse(code)?.accountKey {
            WidgetCaches.forget(account: old)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func load() -> String? {
        let v = defaults.string(forKey: key)
        return (v?.isEmpty == false) ? v : nil
    }
}

import WidgetKit
import SwiftUI
import AppIntents
import UIKit

// MARK: - Pal Home widget
//
// Your Pixel Pal at home, in the room you decorated in Apollo (Pal Home). The
// app can't share an App Group with a sideloaded widget, so Pal Home hands
// over a "Pal code" (PAL1:…) — paste it into this widget, or copy Apollo's
// Widget Setup Code, which carries it too. The room is drawn by the same
// Objective-C pixel renderer the app uses (bridged in), so it matches exactly.
//
// Interactive: Pet (hearts), Nap (off to bed) and Lights (lamps and fires on
// or off). Between taps the Pal wanders the room, the window sky follows the
// clock, and at night it sleeps in its bed.

/// The most recent Pal code from any widget's field or a setup code.
enum PalStash {
    private static let defaults = UserDefaults.standard
    private static let key = "rw.palCode"

    static func load() -> String? { defaults.string(forKey: key) }

    /// Keep whichever code was copied most recently.
    static func offer(_ code: String?) {
        guard let code, let payload = APPalWidget.decode(code) else { return }
        let issued = (payload["issued"] as? NSNumber)?.doubleValue ?? 0
        if let current = load(), let old = APPalWidget.decode(current),
           ((old["issued"] as? NSNumber)?.doubleValue ?? 0) >= issued { return }
        defaults.set(code, forKey: key)
    }

    /// Resolve a widget's code: its own field (if valid), else the stash.
    static func resolve(_ field: String?) -> [AnyHashable: Any]? {
        offer(field)
        // Full setup codes (base64 JSON) carry a Pal code too: look at both the
        // shared setup and this widget's own field, and let each Pal code's
        // `issued` time decide which wins (offer keeps the newest).
        for raw in [field, SharedSetup.load()].compactMap({ $0 }) {
            if let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pal = json["palHome"] as? String {
                offer(pal)
            }
        }
        guard let code = load() else { return nil }
        return APPalWidget.decode(code)
    }
}

/// The widget's own little world: what the Pal is doing right now.
enum PalState {
    private static let defaults = UserDefaults.standard
    static let kind = "PalHomeWidget"

    static var pose: String {
        get {
            // A pet lasts a few minutes, then back to normal.
            let until = defaults.double(forKey: "rw.pal.poseUntil")
            if until > 0, Date().timeIntervalSince1970 > until { return "idle" }
            return defaults.string(forKey: "rw.pal.pose") ?? "idle"
        }
        set {
            defaults.set(newValue, forKey: "rw.pal.pose")
            // Pets and play last a few minutes; a nap lasts until you wake them.
            defaults.set(newValue == "pet" || newValue == "play" ? Date().timeIntervalSince1970 + 180 : 0, forKey: "rw.pal.poseUntil")
        }
    }
    static var lightsOff: Bool {
        get { defaults.bool(forKey: "rw.pal.lightsOff") }
        set { defaults.set(newValue, forKey: "rw.pal.lightsOff") }
    }
    static var pets: Int {
        get { defaults.integer(forKey: "rw.pal.pets") }
        set { defaults.set(newValue, forKey: "rw.pal.pets") }
    }
}

struct PalPetIntent: AppIntent {
    static var title: LocalizedStringResource = "Pet Your Pal"
    func perform() async throws -> some IntentResult {
        PalState.pose = "pet"
        PalState.pets += 1
        WidgetCenter.shared.reloadTimelines(ofKind: PalState.kind)
        return .result()
    }
}

struct PalPlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Play"
    func perform() async throws -> some IntentResult {
        PalState.pose = "play"
        WidgetCenter.shared.reloadTimelines(ofKind: PalState.kind)
        return .result()
    }
}

struct PalNapIntent: AppIntent {
    static var title: LocalizedStringResource = "Nap Time"
    func perform() async throws -> some IntentResult {
        PalState.pose = PalState.pose == "sleep" ? "idle" : "sleep"
        WidgetCenter.shared.reloadTimelines(ofKind: PalState.kind)
        return .result()
    }
}

struct PalLightsIntent: AppIntent {
    static var title: LocalizedStringResource = "Lights"
    func perform() async throws -> some IntentResult {
        PalState.lightsOff.toggle()
        WidgetCenter.shared.reloadTimelines(ofKind: PalState.kind)
        return .result()
    }
}

// MARK: Timeline

struct PalHomeEntry: TimelineEntry {
    let date: Date
    let images: [WidgetFamily: CGImage]
    let style: String?
    let needsCode: Bool
    let pose: String
    let lightsOff: Bool
    /// The Pal's name, for VoiceOver ("Biscuit is napping").
    var palName: String = "Your Pal"
}

/// Pal sprites live in Apollo's own asset catalog, in the app bundle that
/// contains this extension (…/Apollo.app/PlugIns/ApolloRebornWidgets.appex).
private let hostBundle: Bundle? = {
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: app)
}()

/// Sprite sheets stay alive here for the renderer (it borrows them unretained).
private var spriteCache: [String: CGImage] = [:]
private let spriteLock = NSLock()

private func spriteSheet(_ name: String) -> Unmanaged<CGImage>? {
    spriteLock.lock(); defer { spriteLock.unlock() }
    if let cached = spriteCache[name] { return Unmanaged.passUnretained(cached) }
    guard let image = UIImage(named: name, in: hostBundle, compatibleWith: nil)?.cgImage else { return nil }
    spriteCache[name] = image
    return Unmanaged.passUnretained(image)
}

private func minuteOfDay(_ date: Date) -> Int32 {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return Int32((parts.hour ?? 12) * 60 + (parts.minute ?? 0))
}

private func apFamily(_ family: WidgetFamily) -> APPalWidgetFamily {
    switch family {
    case .systemSmall: return .small
    case .systemMedium: return .medium
    case .systemExtraLarge: return .extraLarge
    default:
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return .extraLargePortrait }
        #endif
        return .large
    }
}

struct PalHomeProvider: IntentTimelineProvider {
    typealias Entry = PalHomeEntry
    typealias Intent = PalHomeConfigurationIntent

    func placeholder(in context: Context) -> PalHomeEntry {
        PalHomeEntry(date: Date(), images: [:], style: nil, needsCode: false, pose: "idle", lightsOff: false)
    }

    func getSnapshot(for configuration: Intent, in context: Context, completion: @escaping (PalHomeEntry) -> Void) {
        // The widget gallery shows a sample Pal at home until a code is pasted.
        completion(entry(for: configuration, family: context.family, at: Date(), seed: 1, sampleIfMissing: context.isPreview))
    }

    func getTimeline(for configuration: Intent, in context: Context, completion: @escaping (Timeline<PalHomeEntry>) -> Void) {
        // The Pal wanders a little every 20 minutes for the next few hours.
        let now = Date()
        let slot = Int(now.timeIntervalSince1970 / 1200)
        var entries: [PalHomeEntry] = []
        for i in 0..<9 {
            let date = i == 0 ? now : Date(timeIntervalSince1970: TimeInterval((slot + i) * 1200))
            // Each room render makes plenty of short-lived objects; drain them
            // per entry to stay well inside the extension's memory limit.
            autoreleasepool {
                entries.append(entry(for: configuration, family: context.family, at: date, seed: slot + i))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(for configuration: Intent, family: WidgetFamily, at date: Date, seed: Int,
                       sampleIfMissing: Bool = false) -> PalHomeEntry {
        guard let payload = PalStash.resolve(configuration.palCode) ?? (sampleIfMissing ? APPalWidget.samplePayload() : nil) else {
            let setup = APPalWidget.setupImage(for: apFamily(family))
            return PalHomeEntry(date: date, images: [family: setup], style: nil, needsCode: true, pose: "idle", lightsOff: false)
        }
        let current = PalState.pose
        let pose = date > Date().addingTimeInterval(170) && (current == "pet" || current == "play") ? "idle" : current
        let state: [AnyHashable: Any] = ["pose": pose, "lightsOff": PalState.lightsOff, "seed": seed]
        let image = APPalWidget.renderPayload(payload, family: apFamily(family), minute: minuteOfDay(date), state: state,
                                              sprites: { spriteSheet($0) })
        let style = (payload["room"] as? [String: Any])?["style"] as? String
        let name = ((payload["pal"] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Your Pal"
        return PalHomeEntry(date: date, images: [family: image], style: style,
                            needsCode: false, pose: pose, lightsOff: PalState.lightsOff, palName: name)
    }
}

// MARK: Views

private func color(_ rgb: UInt32) -> Color {
    Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
}

struct PalHomeWidgetView: View {
    let entry: PalHomeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.needsCode, let image = entry.images[family] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel("Pal Home")
                    .accessibilityHint("To set up, open Apollo, tap your Pal's card, copy the Pal code, then edit this widget and paste it into Pal Code.")
            } else if let image = entry.images[family] {
                ZStack(alignment: .topTrailing) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement()
                        .accessibilityLabel(roomDescription)
                    buttons.padding(family == .systemSmall ? 5 : 8)
                }
            } else {
                Color.clear
            }
        }
        .containerBackground(for: .widget) { color(APPalWidget.backgroundColor(forStyle: entry.style)) }
        .widgetURL(URL(string: "apollo://reborn/settings/pal-home"))
    }

    /// What VoiceOver hears for the room: who, and what they're up to.
    private var roomDescription: String {
        let name = entry.palName
        switch entry.pose {
        case "sleep": return "\(name) is napping at home\(entry.lightsOff ? ", lights off" : "")."
        case "pet": return "\(name) is at home, happy after a pet."
        case "play": return "\(name) is at home, chasing the yarn."
        default: return "\(name) at home\(entry.lightsOff ? ", lights off" : "")."
        }
    }

    @ViewBuilder private var buttons: some View {
        let style = entry.style
        // Top corner, clear of the caption strip along the bottom.
        HStack(spacing: family == .systemSmall ? 3 : 4) {
            if family != .systemSmall {
                tile(PalLightsIntent(), icon: "bulb", toggled: !entry.lightsOff, style: style,
                     label: "Lights", value: entry.lightsOff ? "Off" : "On")
                tile(PalNapIntent(), icon: "moon", toggled: entry.pose == "sleep", style: style,
                     label: entry.pose == "sleep" ? "Wake \(entry.palName)" : "Nap time", value: entry.pose == "sleep" ? "Napping" : nil)
                tile(PalPlayIntent(), icon: "ball", toggled: entry.pose == "play", style: style, label: "Play", value: nil)
            }
            tile(PalPetIntent(), icon: "heart", toggled: entry.pose == "pet", style: style, label: "Pet \(entry.palName)", value: nil)
        }
    }

    private func tile<I: AppIntent>(_ intent: I, icon: String, toggled: Bool, style: String?,
                                    label: String, value: String?) -> some View {
        let image = APPalWidget.buttonImage(forIcon: icon, style: style, toggled: toggled)
        let scale: CGFloat = family == .systemSmall ? 1.5 : 1.75
        return Button(intent: intent) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: 18 * scale, height: 16 * scale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
    }
}

struct PalHomeWidget: Widget {
    let kind = PalState.kind

    private var families: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { families.append(.systemExtraLargePortrait) }
        #endif
        return families
    }

    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind, intent: PalHomeConfigurationIntent.self, provider: PalHomeProvider()) { entry in
            PalHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("Pal Home")
        .description("Your Pixel Pal at home, in the room you decorated. They get up to things through the day. Pet them, play, send them to bed, flick the lights.")
        .supportedFamilies(families)
        .contentMarginsDisabled()
    }
}

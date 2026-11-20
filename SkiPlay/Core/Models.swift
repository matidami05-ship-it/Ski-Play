import Foundation
import SwiftUI

/// A console this phone has been linked with (registered using the PIN from the console).
struct Console: Codable, Identifiable, Equatable {
    var id: String            // MAC address as hex
    var nickname: String
    var host: String          // last known IP address
    var ps5: Bool
    var registKey: Data       // 16 bytes
    var morning: Data         // 16 bytes ("rp key")
    var hostID: String?       // id reported by discovery (matches MAC)

    var displayName: String { nickname.isEmpty ? (ps5 ? "PS5" : "PS4") : nickname }
}

/// A console seen on the network right now.
struct FoundConsole: Identifiable, Equatable {
    var id: String { hostID }
    var hostID: String
    var name: String
    var address: String
    var ps5: Bool
    var state: State
    var runningApp: String?
    var lastSeen: Date

    enum State: Equatable { case on, rest, unknown }
}

enum StreamQuality: String, Codable, CaseIterable, Identifiable {
    case smooth, balanced, sharp, max

    var id: String { rawValue }
    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .balanced: return "Balanced"
        case .sharp: return "Sharp"
        case .max: return "Max"
        }
    }
    var detail: String {
        switch self {
        case .smooth: return "540p · 60 fps · 6 Mbps — best on weak Wi-Fi"
        case .balanced: return "720p · 60 fps · 10 Mbps — recommended"
        case .sharp: return "1080p · 60 fps · 15 Mbps — strong 5 GHz Wi-Fi"
        case .max: return "1080p · 60 fps · 25 Mbps — Wi-Fi 6, PS5 wired"
        }
    }
    var width: Int { [.smooth: 960, .balanced: 1280, .sharp: 1920, .max: 1920][self]! }
    var height: Int { [.smooth: 540, .balanced: 720, .sharp: 1080, .max: 1080][self]! }
    var bitrate: Int { [.smooth: 6000, .balanced: 10000, .sharp: 15000, .max: 25000][self]! }
}

final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var consoles: [Console] { didSet { save() } }
    @Published var accountID: Data? { didSet { save() } }     // 8 bytes, little endian
    @Published var onlineID: String? { didSet { save() } }
    @Published var quality: StreamQuality { didSet { save() } }
    @Published var fps: Int { didSet { save() } }
    @Published var useHEVC: Bool { didSet { save() } }
    @Published var showStats: Bool { didSet { save() } }
    @Published var showTouchControls: Bool { didSet { save() } }
    @Published var hapticsEnabled: Bool { didSet { save() } }
    @Published var manualHosts: [String] { didSet { save() } }

    private let defaults = UserDefaults.standard
    private var loading = true

    private init() {
        let d = UserDefaults.standard
        consoles = (d.data(forKey: "consoles")).flatMap { try? JSONDecoder().decode([Console].self, from: $0) } ?? []
        accountID = d.data(forKey: "accountID")
        onlineID = d.string(forKey: "onlineID")
        quality = StreamQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .balanced
        fps = d.object(forKey: "fps") as? Int ?? 60
        useHEVC = d.object(forKey: "hevc") as? Bool ?? true
        showStats = d.object(forKey: "stats") as? Bool ?? false
        showTouchControls = d.object(forKey: "touch") as? Bool ?? true
        hapticsEnabled = d.object(forKey: "haptics") as? Bool ?? true
        manualHosts = d.stringArray(forKey: "manualHosts") ?? []
        loading = false
    }

    private func save() {
        guard !loading else { return }
        defaults.set(try? JSONEncoder().encode(consoles), forKey: "consoles")
        defaults.set(accountID, forKey: "accountID")
        defaults.set(onlineID, forKey: "onlineID")
        defaults.set(quality.rawValue, forKey: "quality")
        defaults.set(fps, forKey: "fps")
        defaults.set(useHEVC, forKey: "hevc")
        defaults.set(showStats, forKey: "stats")
        defaults.set(showTouchControls, forKey: "touch")
        defaults.set(hapticsEnabled, forKey: "haptics")
        defaults.set(manualHosts, forKey: "manualHosts")
    }

    var accountIDBase64: String? { accountID?.base64EncodedString() }

    func setAccountID(base64: String) -> Bool {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 8 else { return false }
        accountID = data
        return true
    }

    func upsert(_ console: Console) {
        if let i = consoles.firstIndex(where: { $0.id == console.id }) {
            consoles[i] = console
        } else {
            consoles.append(console)
        }
    }

    func updateHost(for consoleID: String, address: String) {
        guard let i = consoles.firstIndex(where: { $0.id == consoleID }), consoles[i].host != address else { return }
        consoles[i].host = address
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}

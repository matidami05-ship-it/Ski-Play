import Foundation
import Darwin

/// Finds PlayStation consoles on the home Wi-Fi.
///
/// iOS doesn't let normal apps send broadcast packets, so instead of one broadcast this sends a
/// small "are you there?" packet to every address on the local network, plus any saved addresses.
final class Discovery: ObservableObject {
    static let shared = Discovery()

    @Published private(set) var found: [String: FoundConsole] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var localAddress: String?

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var tick = 0
    private let sendQueue = DispatchQueue(label: "discovery.send")

    func start() {
        guard handle == nil else { return }
        var err: Int32 = 0
        let user = Unmanaged.passUnretained(self).toOpaque()
        handle = sp_discovery_new({ hostPtr, user in
            guard let hostPtr, let user else { return }
            let me = Unmanaged<Discovery>.fromOpaque(user).takeUnretainedValue()
            let h = hostPtr.pointee
            guard let id = Discovery.str(h.host_id), let addr = Discovery.str(h.addr) else { return }
            let console = FoundConsole(
                hostID: id,
                name: Discovery.str(h.name) ?? (h.ps5 ? "PS5" : "PS4"),
                address: addr,
                ps5: h.ps5,
                state: h.state == 1 ? .on : (h.state == 2 ? .rest : .unknown),
                runningApp: Discovery.str(h.running_app_name),
                lastSeen: Date())
            DispatchQueue.main.async { me.didFind(console) }
        }, user, &err)
        if handle == nil {
            Log.shared.add("Discovery failed to start: \(Chiaki.errorString(err))")
            return
        }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.scan() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let handle { sp_discovery_free(handle) }
        handle = nil
        scanning = false
    }

    /// Probes saved consoles every 2 s and the whole network every 10 s.
    func scan(full: Bool = false) {
        guard let handle else { return }
        tick += 1
        let doFull = full || tick % 5 == 1
        var targets = Set(AppStore.shared.consoles.map(\.host))
        targets.formUnion(AppStore.shared.manualHosts)
        targets.formUnion(found.values.map(\.address))
        if doFull {
            let subnet = Self.localSubnet()
            localAddress = subnet?.address
            targets.formUnion(subnet?.hosts ?? [])
            scanning = true
        }
        // Forget consoles that stopped answering.
        let cutoff = Date().addingTimeInterval(-8)
        let stale = found.filter { $0.value.lastSeen < cutoff }.map(\.key)
        for key in stale { found.removeValue(forKey: key) }

        let list = Array(targets).filter { !$0.isEmpty }
        let h = handle
        sendQueue.async {
            for (i, ip) in list.enumerated() {
                _ = sp_discovery_probe(h, ip)
                if i % 32 == 31 { usleep(2000) }
            }
            if doFull {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.scanning = false }
            }
        }
    }

    private func didFind(_ console: FoundConsole) {
        found[console.hostID] = console
        // Keep saved consoles' addresses fresh when the router hands out a new IP.
        if let saved = AppStore.shared.consoles.first(where: { $0.id.caseInsensitiveCompare(console.hostID) == .orderedSame || $0.hostID == console.hostID }) {
            AppStore.shared.updateHost(for: saved.id, address: console.address)
        }
    }

    func status(for console: Console) -> FoundConsole? {
        found.values.first { $0.hostID.caseInsensitiveCompare(console.id) == .orderedSame || $0.hostID == console.hostID || $0.address == console.host }
    }

    // MARK: - Local network

    struct Subnet { var address: String; var hosts: [String] }

    static func localSubnet() -> Subnet? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: Subnet?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let mask = p.pointee.ifa_netmask,
                  (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if m == 0 { continue }
            // Don't sweep anything bigger than a /22 (1022 addresses).
            if m < 0xFFFF_FC00 { m = 0xFFFF_FF00 }
            let network = ip & m
            let broadcast = network | ~m
            var hosts: [String] = []
            if broadcast > network + 1 {
                for a in (network + 1)..<broadcast where a != ip {
                    hosts.append(ipString(a))
                }
            }
            let subnet = Subnet(address: ipString(ip), hosts: hosts)
            if name == "en0" { return subnet }
            if best == nil { best = subnet }
        }
        return best
    }

    static func str(_ p: UnsafePointer<CChar>?) -> String? {
        guard let p else { return nil }
        let v = String(cString: p)
        return v.isEmpty ? nil : v
    }

    static func ipString(_ a: UInt32) -> String {
        "\((a >> 24) & 0xFF).\((a >> 16) & 0xFF).\((a >> 8) & 0xFF).\(a & 0xFF)"
    }
}

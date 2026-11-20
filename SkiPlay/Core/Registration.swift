import Foundation

/// Links this phone with a console using the 8-digit code from
/// Settings › System › Remote Play › Link Device.
final class Registration {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?
    private var continuation: CheckedContinuation<Console, Error>?
    private var host = ""

    static func link(host: String, ps5: Bool, accountID: Data, pin: UInt32) async throws -> Console {
        let r = Registration()
        return try await r.run(host: host, ps5: ps5, accountID: accountID, pin: pin)
    }

    private func run(host: String, ps5: Bool, accountID: Data, pin: UInt32) async throws -> Console {
        self.host = host
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            var err: Int32 = 0
            let user = Unmanaged.passRetained(self).toOpaque()
            let bytes = [UInt8](accountID.prefix(8))
            handle = bytes.withUnsafeBufferPointer { buf in
                sp_regist_start(host, ps5, buf.baseAddress, pin, { resultPtr, user in
                    guard let resultPtr, let user else { return }
                    let me = Unmanaged<Registration>.fromOpaque(user).takeRetainedValue()
                    let result = resultPtr.pointee
                    DispatchQueue.main.async { me.finish(result) }
                }, user, &err)
            }
            if handle == nil {
                Unmanaged<Registration>.fromOpaque(user).release()
                self.continuation = nil
                cont.resume(throwing: Failure(message: "Couldn't start linking: \(Chiaki.errorString(err))"))
            }
            // Give up after 30 s if the console never answers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                let h = self.handle
                self.handle = nil
                DispatchQueue.global().async { if let h { sp_regist_free(h) } }
                pending.resume(throwing: Failure(message: "The console didn't answer. Make sure it's on, on the same Wi-Fi, and showing the 8-digit code."))
            }
        }
    }

    private func finish(_ r: SPRegistResult) {
        guard let cont = continuation else { return }
        continuation = nil
        let h = handle
        handle = nil
        DispatchQueue.global().async { if let h { sp_regist_free(h) } }

        switch r.status {
        case 0:
            var res = r
            let mac = withUnsafeBytes(of: &res.server_mac) { Data($0) }
            let key = withUnsafeBytes(of: &res.rp_regist_key) { Data($0) }
            let morning = withUnsafeBytes(of: &res.rp_key) { Data($0) }
            let nickname = withUnsafeBytes(of: &res.server_nickname) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[0..<end], as: UTF8.self)
            }
            let console = Console(id: mac.hex, nickname: nickname, host: host, ps5: r.ps5,
                                  registKey: key, morning: morning, hostID: mac.hex)
            cont.resume(returning: console)
        case 2:
            cont.resume(throwing: Failure(message: "Linking was canceled."))
        default:
            let detail = Log.shared.recentErrors(3)
            cont.resume(throwing: Failure(message: "The console didn't accept the code. Check the 8-digit code is still showing on the TV and try again." + (detail.isEmpty ? "" : "\n\n" + detail)))
        }
    }
}

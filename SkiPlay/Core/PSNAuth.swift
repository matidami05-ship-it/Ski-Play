import Foundation
import SwiftUI
import WebKit

/// Signs in to PlayStation Network once to learn the account ID the console needs for linking.
/// Uses the same sign-in flow as Sony's own Remote Play apps (as documented by chiaki-ng).
enum PSNAuth {
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!

    static var loginURL: URL {
        var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        c.queryItems = [
            .init(name: "service_entity", value: "urn:service-entity:psn"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scope),
            .init(name: "request_locale", value: "en_US"),
            .init(name: "ui", value: "pr"),
            .init(name: "service_logo", value: "ps"),
            .init(name: "layout_type", value: "popup"),
            .init(name: "smcid", value: "remoteplay"),
            .init(name: "prompt", value: "always"),
            .init(name: "PlatformPrivacyWs1", value: "minimal"),
            // Ties the sign-in to this phone; PlayStation Network requires it for internet play.
            .init(name: "duid", value: AppStore.shared.deviceUID),
        ]
        return c.url!
    }

    private static var basicAuth: String {
        "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
    }

    struct AuthError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private static func tokenRequest(_ items: [URLQueryItem]) async throws -> Tokens {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = items + [
            .init(name: "scope", value: scope),
            .init(name: "redirect_uri", value: redirect),
        ]
        req.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw AuthError(message: "PlayStation sign-in failed (\(status)). Sign in again in Settings.")
        }
        let refresh = json["refresh_token"] as? String ?? ""
        let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(seconds))
    }

    /// A PlayStation Network access token that's good for at least a few more minutes.
    static func validAccessToken() async throws -> String {
        guard var tokens = AppStore.shared.psnTokens else {
            throw AuthError(message: "Sign in to PlayStation again (Settings › Sign In) to play away from home.")
        }
        if tokens.expires.timeIntervalSinceNow > 300 { return tokens.access }
        guard !tokens.refresh.isEmpty else {
            throw AuthError(message: "Your PlayStation sign-in expired. Sign in again in Settings.")
        }
        let fresh = try await tokenRequest([
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: tokens.refresh),
        ])
        tokens.access = fresh.access
        if !fresh.refresh.isEmpty { tokens.refresh = fresh.refresh }
        tokens.expires = fresh.expires
        let saved = tokens
        await MainActor.run { AppStore.shared.psnTokens = saved }
        return saved.access
    }

    /// Exchanges the sign-in code for tokens, the 8-byte account ID (little endian) and online ID.
    static func accountID(fromCode code: String) async throws -> (id: Data, onlineID: String?, tokens: Tokens) {
        let tokens = try await tokenRequest([
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
        ])
        let token = tokens.access

        var infoReq = URLRequest(url: tokenURL.appendingPathComponent(token))
        infoReq.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        let (infoData, infoResp) = try await URLSession.shared.data(for: infoReq)
        guard (infoResp as? HTTPURLResponse)?.statusCode == 200,
              let info = try JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let userID = (info["user_id"] as? String).flatMap({ UInt64($0) }) ?? (info["user_id"] as? NSNumber)?.uint64Value else {
            throw AuthError(message: "Couldn't read your PlayStation account ID.")
        }
        var le = userID.littleEndian
        let id = Data(bytes: &le, count: 8)
        return (id, info["online_id"] as? String, tokens)
    }
}

/// Sony's sign-in page; finishes when it redirects with a code.
struct PSNLoginView: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: PSNAuth.loginURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, url.absoluteString.hasPrefix(PSNAuth.redirect) {
                decisionHandler(.cancel)
                if !done, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value {
                    done = true
                    onCode(code)
                }
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// Consoles on the PlayStation account, for playing away from home.
enum PSNDevices {
    struct Device { var name: String; var duid: String; var ps5: Bool; var enabled: Bool }

    static func list() async throws -> [Device] {
        let token = try await PSNAuth.validAccessToken()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var ptr: UnsafeMutablePointer<SPPsnDevice>?
                let n = sp_psn_list_devices(token, &ptr)
                if n < 0 {
                    cont.resume(throwing: PSNAuth.AuthError(message: "Couldn't get your consoles from PlayStation Network (\(Chiaki.errorString(-n)))."))
                    return
                }
                var result: [Device] = []
                if let ptr {
                    for i in 0..<Int(n) {
                        var d = ptr[i]
                        let name = withUnsafeBytes(of: &d.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                        let duid = withUnsafeBytes(of: &d.duid) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                        result.append(Device(name: name, duid: duid, ps5: d.ps5, enabled: d.remoteplay_enabled))
                    }
                    free(ptr)
                }
                cont.resume(returning: result)
            }
        }
    }

    /// Matches PSN consoles to saved ones (by name) and adds the rest, so they can be played
    /// from anywhere.
    @MainActor
    static func sync() async {
        guard AppStore.shared.psnTokens != nil else { return }
        do {
            let devices = try await list()
            let store = AppStore.shared
            for d in devices where d.enabled {
                if let i = store.consoles.firstIndex(where: { $0.psnDUID == d.duid }) {
                    if store.consoles[i].nickname.isEmpty { store.consoles[i].nickname = d.name }
                } else if let i = store.consoles.firstIndex(where: { $0.psnDUID == nil && $0.nickname.caseInsensitiveCompare(d.name) == .orderedSame }) {
                    store.consoles[i].psnDUID = d.duid
                } else {
                    store.consoles.append(Console(id: "psn-" + d.duid, nickname: d.name, host: "", ps5: d.ps5,
                                                  registKey: Data(), morning: Data(), hostID: nil, psnDUID: d.duid))
                }
            }
            Log.shared.add("PSN: \(devices.count) console(s) on your account")
        } catch {
            Log.shared.add("PSN: \(error.localizedDescription)")
        }
    }
}

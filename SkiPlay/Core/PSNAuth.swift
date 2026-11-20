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

    /// Exchanges the sign-in code for the 8-byte account ID (little endian) and online ID.
    static func accountID(fromCode code: String) async throws -> (id: Data, onlineID: String?) {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "scope", value: scope),
            .init(name: "redirect_uri", value: redirect),
        ]
        req.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw AuthError(message: "PlayStation sign-in failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)). Try again.")
        }

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
        return (id, info["online_id"] as? String)
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

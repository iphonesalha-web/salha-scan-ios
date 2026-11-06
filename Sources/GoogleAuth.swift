import UIKit
import AuthenticationServices
import CryptoKit
import Security

/// تسجيل دخول Google داخل التطبيق (OAuth لعميل iOS مع PKCE)
/// ويحفظ رمز التحديث في Keychain حتى لا يحتاج المستخدم «ربط» كل ساعة.
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var anchor: UIWindow?
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    /// com.googleusercontent.apps.<الجزء الأول من Client ID>
    static func reversedScheme(_ clientId: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientId.hasSuffix(suffix) else { return nil }
        return "com.googleusercontent.apps." + clientId.dropLast(suffix.count)
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    func signIn(clientId: String, scope: String, completion: @escaping ([String: Any]) -> Void) {
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = Self.reversedScheme(cid) else {
            completion(["error": "bad_client"]); return
        }
        let redirect = scheme + ":/oauth2redirect"
        let verifier = Self.randomVerifier()
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: cid),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account consent")
        ]

        let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { [weak self] url, error in
            self?.session = nil
            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                completion(["error": "canceled"]); return
            }
            guard let url = url,
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                completion(["error": error?.localizedDescription ?? "no_code"]); return
            }
            Self.token(params: [
                "code": code, "client_id": cid, "redirect_uri": redirect,
                "grant_type": "authorization_code", "code_verifier": verifier
            ], clientId: cid, completion: completion)
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        DispatchQueue.main.async { s.start() }
    }

    /// رمز جديد بدون أي نافذة، باستخدام رمز التحديث المحفوظ
    static func refresh(clientId: String, completion: @escaping ([String: Any]) -> Void) {
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let rt = KeychainStore.get("gd_refresh_" + cid)
        guard !rt.isEmpty else { completion(["error": "no_refresh"]); return }
        token(params: ["client_id": cid, "refresh_token": rt, "grant_type": "refresh_token"],
              clientId: cid, completion: completion)
    }

    static func signOut(clientId: String) {
        KeychainStore.set("", for: "gd_refresh_" + clientId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func token(params: [String: String], clientId: String,
                              completion: @escaping ([String: Any]) -> Void) {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = (c.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(["error": error?.localizedDescription ?? "network"]); return
            }
            guard let at = json["access_token"] as? String else {
                let err = (json["error"] as? String) ?? "token_error"
                if err == "invalid_grant" { signOut(clientId: clientId) }
                completion(["error": err, "detail": (json["error_description"] as? String) ?? ""]); return
            }
            if let rt = json["refresh_token"] as? String, !rt.isEmpty {
                KeychainStore.set(rt, for: "gd_refresh_" + clientId)
            }
            completion(["access_token": at, "expires_in": (json["expires_in"] as? Int) ?? 3600])
        }.resume()
    }
}

enum KeychainStore {
    private static let service = "com.salha.scan"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

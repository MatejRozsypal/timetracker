import AppKit
import CryptoKit
import Foundation
import Network

/// OAuth 2.0 for installed apps: loopback redirect on 127.0.0.1 with PKCE (S256).
/// The refresh token is stored in a 0600 file in Application Support instead of
/// the Keychain, because ad-hoc signed rebuilds would re-prompt for Keychain
/// access on every build. The scope is calendar.app.created, so the token can
/// only touch calendars this app created.
@MainActor
final class GoogleAuth: ObservableObject {
    static let scope = "https://www.googleapis.com/auth/calendar.app.created"

    struct Token: Codable {
        var refreshToken: String
        var accessToken: String?
        var expiresAt: Date?
    }

    enum AuthError: LocalizedError {
        case notConfigured, cancelled, badResponse(String), revoked
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google client id and secret are missing in config.json"
            case .cancelled: return "Sign-in was cancelled"
            case .badResponse(let s): return "Google said: \(s)"
            case .revoked: return "Google access expired or was revoked. Sign in again."
            }
        }
    }

    @Published private(set) var signedIn = false
    @Published var lastError: String?

    private let tokenURL = Paths.support.appendingPathComponent("token.json")
    private var token: Token?
    private var listener: NWListener?
    private let store: Store

    init(store: Store) {
        self.store = store
        if let data = try? Data(contentsOf: tokenURL), let t = try? JSONDecoder().decode(Token.self, from: data) {
            token = t
            signedIn = true
        }
    }

    func signOut() {
        token = nil
        signedIn = false
        try? FileManager.default.removeItem(at: tokenURL)
    }

    // MARK: Sign-in

    func signIn() async {
        lastError = nil
        do {
            try await runSignIn()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func runSignIn() async throws {
        let config = store.config
        guard config.hasGoogleClient else { throw AuthError.notConfigured }

        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)

        let (port, codeTask) = try await startLoopback(expectedState: state)
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: config.googleClientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
            .init(name: "hd", value: "oneeighty.cz"),
        ]
        NSWorkspace.shared.open(comps.url!)

        let code = try await codeTask.value()
        let body = [
            "code": code,
            "client_id": config.googleClientId,
            "client_secret": config.googleClientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let json = try await postForm("https://oauth2.googleapis.com/token", body)
        guard let refresh = json["refresh_token"] as? String else {
            throw AuthError.badResponse("no refresh_token in response")
        }
        var t = Token(refreshToken: refresh)
        if let access = json["access_token"] as? String, let exp = json["expires_in"] as? Double {
            t.accessToken = access
            t.expiresAt = Date().addingTimeInterval(exp - 60)
        }
        persist(t)
        signedIn = true
    }

    /// Starts a one-shot HTTP listener on a random loopback port and returns the
    /// port plus a task that resolves with the authorization code.
    private func startLoopback(expectedState: String) async throws -> (UInt16, OneShot) {
        listener?.cancel()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        let codeTask = OneShot()
        var finished = false

        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
                let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let items = URLComponents(string: "http://x\(path)")?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let st = items.first { $0.name == "state" }?.value
                let err = items.first { $0.name == "error" }?.value

                let ok = code != nil && st == expectedState
                let html = ok
                    ? "<h2>OE Time Log is connected.</h2><p>You can close this tab.</p>"
                    : "<h2>Sign-in failed.</h2><p>\(err ?? "Try again from the menu bar.")</p>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body style=\"font-family:-apple-system;padding:40px\">\(html)</body></html>"
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })

                // Browsers also request /favicon.ico; only the redirect carries a code or error.
                guard !finished, code != nil || err != nil else { return }
                finished = true
                if ok, let code { codeTask.fulfil(.success(code)) } else { codeTask.fulfil(.failure(AuthError.cancelled)) }
                listener.cancel()
            }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var done = false
            listener.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e):
                    done = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: .main)
        }

        // Abandon the attempt after 5 minutes.
        Task { [weak listener] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            if !finished {
                finished = true
                codeTask.fulfil(.failure(AuthError.cancelled))
                listener?.cancel()
            }
        }
        return (port, codeTask)
    }

    // MARK: Access tokens

    func accessToken() async throws -> String {
        guard var t = token else { throw AuthError.revoked }
        if let a = t.accessToken, let exp = t.expiresAt, exp > Date() { return a }
        let config = store.config
        guard config.hasGoogleClient else { throw AuthError.notConfigured }
        let json: [String: Any]
        do {
            json = try await postForm("https://oauth2.googleapis.com/token", [
                "client_id": config.googleClientId,
                "client_secret": config.googleClientSecret,
                "refresh_token": t.refreshToken,
                "grant_type": "refresh_token",
            ])
        } catch AuthError.badResponse(let msg) where msg.contains("invalid_grant") {
            signOut()
            throw AuthError.revoked
        }
        guard let access = json["access_token"] as? String else { throw AuthError.badResponse("no access_token") }
        t.accessToken = access
        t.expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        persist(t)
        return access
    }

    private func persist(_ t: Token) {
        token = t
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: tokenURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        }
    }

    private func postForm(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let err = (json["error"] as? String) ?? "HTTP \(http.statusCode)"
            let desc = (json["error_description"] as? String).map { " (\($0))" } ?? ""
            throw AuthError.badResponse(err + desc)
        }
        return json
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

/// A single value delivered once from a callback, awaited once. Main thread only.
final class OneShot: @unchecked Sendable {
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    func fulfil(_ r: Result<String, Error>) {
        guard result == nil else { return }
        result = r
        waiter?.resume(with: r)
        waiter = nil
    }

    @MainActor
    func value() async throws -> String {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

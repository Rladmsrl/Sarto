import CryptoKit
import Foundation

/// Response from Sarto Cloud OAuth 2.0 Device Authorization (`POST /api/oauth/device`, RFC 8628).
public struct CloudDeviceAuthStart: Codable, Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let verificationUriComplete: String?
    public let expiresIn: Int
    public let interval: Int

    public init(
        deviceCode: String,
        userCode: String,
        verificationUri: String,
        verificationUriComplete: String?,
        expiresIn: Int,
        interval: Int
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.verificationUriComplete = verificationUriComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    /// Best URL to open in Safari / system browser so the user confirms with one tap.
    public var openURL: URL? {
        if let complete = verificationUriComplete,
           let url = Self.validatedHTTPSURL(complete) {
            return url
        }
        return Self.validatedHTTPSURL(verificationUri)
    }

    private static func validatedHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }
}

/// Access & refresh tokens issued by Sarto Cloud OAuth 2.0 (`/api/oauth/token`).
public struct CloudOAuthTokenSet: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Unix milliseconds after which the access token should be refreshed.
    public let accessExpiresAt: Double

    public init(accessToken: String, refreshToken: String, accessExpiresAt: Double) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
    }

    public var isExpiredOrNearExpiry: Bool {
        Date().timeIntervalSince1970 * 1000.0 >= accessExpiresAt
    }
}

/// Authenticated Sarto Cloud account profile (`GET /api/v1/me`).
public struct CloudAccountProfile: Codable, Sendable, Equatable {
    public let id: String
    public let email: String
    public let name: String?
    public let avatarUrl: String?

    public init(id: String, email: String, name: String? = nil, avatarUrl: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

/// Persisted direct cloud sign-in state for clients without a local daemon (such as iOS).
public struct CloudAccountSessionRecord: Codable, Sendable, Equatable {
    public let origin: String
    public var tokens: CloudOAuthTokenSet
    public var profile: CloudAccountProfile

    public init(origin: String, tokens: CloudOAuthTokenSet, profile: CloudAccountProfile) {
        self.origin = origin
        self.tokens = tokens
        self.profile = profile
    }
}

public enum CloudAccountClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case authorizationPending
    case slowDown(interval: Int?)
    case expiredToken
    case accessDenied
    case serviceError(code: String, message: String, status: Int)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Sarto Cloud URL"
        case .authorizationPending:
            return "Waiting for browser authorization"
        case .slowDown:
            return "Polling slowed down by server"
        case .expiredToken:
            return "Sign-in code expired; please try again"
        case .accessDenied:
            return "Sign-in was declined"
        case .serviceError(_, let message, _):
            return message
        case .unexpectedResponse:
            return "Sarto Cloud returned an unexpected response"
        }
    }
}

private final class CloudNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Pure Swift client for Sarto Cloud OAuth 2.0 Device Flow & Relay Token APIs (`src/shared/account-api.ts`).
public final class CloudAccountClient: Sendable {
    public static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    public static let deviceClientID = "sarto-daemon"
    private static let expiryMarginMs: Double = 60_000

    private let session: URLSession
    private let redirectDelegate: CloudNoRedirectDelegate?

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.redirectDelegate = nil
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 20
            let delegate = CloudNoRedirectDelegate()
            self.redirectDelegate = delegate
            self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        }
    }

    public static func encodeClientInfo(
        deviceName: String,
        os: String,
        arch: String = "arm64",
        version: String? = nil
    ) -> String {
        #if os(macOS)
        let clientKind = "desktop"
        let defaultName = "Mac"
        let defaultOS = "macOS"
        #else
        let clientKind = "mobile"
        let defaultName = "iPhone"
        let defaultOS = "iOS"
        #endif
        var clientInfoObj: [String: Any] = [
            "kind": clientKind,
            "name": Self.trimmed(deviceName, max: 100, fallback: defaultName),
            "os": Self.trimmed(os, max: 40, fallback: defaultOS),
            "arch": Self.trimmed(arch, max: 40, fallback: "arm64"),
        ]
        if let version, !version.isEmpty {
            clientInfoObj["version"] = String(version.prefix(40))
        } else {
            clientInfoObj["version"] = NSNull()
        }
        guard let infoData = try? JSONSerialization.data(withJSONObject: clientInfoObj),
              let infoString = String(data: infoData, encoding: .utf8)
        else { return "{}" }
        return infoString
    }

    public func startDeviceSignIn(
        origin: String,
        deviceName: String,
        os: String,
        arch: String = "arm64",
        version: String? = nil
    ) async throws -> CloudDeviceAuthStart {
        let infoString = Self.encodeClientInfo(
            deviceName: deviceName,
            os: os,
            arch: arch,
            version: version
        )

        let body = try await postForm(
            origin: origin,
            path: "/api/oauth/device",
            fields: [
                "client_id": Self.deviceClientID,
                "client_info": infoString,
            ]
        )
        guard let deviceCode = body["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = body["user_code"] as? String, !userCode.isEmpty,
              let verificationUri = body["verification_uri"] as? String, !verificationUri.isEmpty,
              let expiresIn = Self.jsonInt(body["expires_in"]),
              let interval = Self.jsonInt(body["interval"])
        else {
            throw CloudAccountClientError.unexpectedResponse
        }
        let complete = (body["verification_uri_complete"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CloudDeviceAuthStart(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verificationUri,
            verificationUriComplete: complete,
            expiresIn: expiresIn,
            interval: max(1, interval)
        )
    }

    public func pollDeviceToken(origin: String, deviceCode: String) async throws -> CloudOAuthTokenSet {
        let body = try await postForm(
            origin: origin,
            path: "/api/oauth/token",
            fields: [
                "grant_type": Self.deviceGrantType,
                "client_id": Self.deviceClientID,
                "device_code": deviceCode,
            ]
        )
        return try Self.parseTokenSet(body)
    }

    public func refreshTokens(
        origin: String,
        refreshToken: String,
        clientInfo: String? = nil
    ) async throws -> CloudOAuthTokenSet {
        var fields: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Self.deviceClientID,
            "refresh_token": refreshToken,
        ]
        if let clientInfo, !clientInfo.isEmpty {
            fields["client_info"] = clientInfo
        }
        let body = try await postForm(
            origin: origin,
            path: "/api/oauth/token",
            fields: fields
        )
        return try Self.parseTokenSet(body)
    }

    public func fetchMe(origin: String, accessToken: String) async throws -> CloudAccountProfile {
        let body = try await requestJSON(
            origin: origin,
            path: "/api/v1/me",
            method: "GET",
            bearerToken: accessToken,
            formFields: nil
        )
        guard let account = body["account"] as? [String: Any],
              let id = account["id"] as? String, !id.isEmpty,
              let email = account["email"] as? String, !email.isEmpty
        else {
            throw CloudAccountClientError.unexpectedResponse
        }
        let name = (account["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let avatarUrl = (account["avatarUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CloudAccountProfile(id: id, email: email, name: name, avatarUrl: avatarUrl)
    }

    public func fetchRelayToken(origin: String, accessToken: String) async throws -> CloudRelayTokenInfo {
        let body = try await requestJSON(
            origin: origin,
            path: "/api/v1/relay/token",
            method: "POST",
            bearerToken: accessToken,
            formFields: nil
        )
        guard let token = body["token"] as? String, !token.isEmpty, token.count <= 4096,
              let expiresAt = Self.jsonDouble(body["expiresAt"])
        else {
            throw CloudAccountClientError.unexpectedResponse
        }
        return CloudRelayTokenInfo(token: token, expiresAt: expiresAt)
    }

    public func revoke(origin: String, refreshToken: String) async throws {
        _ = try await requestJSON(
            origin: origin,
            path: "/api/oauth/revoke",
            method: "POST",
            bearerToken: nil,
            formFields: [
                "token": refreshToken,
                "token_type_hint": "refresh_token",
                "client_id": Self.deviceClientID,
            ],
            allowEmptyBody: true
        )
    }

    // MARK: - Helpers

    private func postForm(origin: String, path: String, fields: [String: String]) async throws -> [String: Any] {
        try await requestJSON(
            origin: origin,
            path: path,
            method: "POST",
            bearerToken: nil,
            formFields: fields
        )
    }

    private static func isAllowedOriginURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
        return false
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let d = number.doubleValue
        return d.isFinite ? d : nil
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        guard let d = jsonDouble(value) else { return nil }
        return Int.wholePart(of: d)
    }

    private func requestJSON(
        origin: String,
        path: String,
        method: String,
        bearerToken: String?,
        formFields: [String: String]?,
        allowEmptyBody: Bool = false
    ) async throws -> [String: Any] {
        let base = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(normalized)\(path)"), Self.isAllowedOriginURL(url) else {
            throw CloudAccountClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let formFields {
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.encodeForm(formFields).data(using: .utf8)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAccountClientError.unexpectedResponse
        }
        if (300...399).contains(http.statusCode) {
            throw CloudAccountClientError.unexpectedResponse
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200...299).contains(http.statusCode) {
            if let parsed { return parsed }
            if allowEmptyBody && data.isEmpty { return [:] }
            throw CloudAccountClientError.unexpectedResponse
        }
        let errCode = (parsed?["error"] as? String) ?? "server_error"
        let baseMsg = (parsed?["error_description"] as? String)
            ?? (parsed?["message"] as? String)
            ?? "\(path) answered \(http.statusCode)"
        let reason = (parsed?["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let errMsg = reason.map { "\(baseMsg) (\($0))" } ?? baseMsg
        switch errCode {
        case "authorization_pending":
            throw CloudAccountClientError.authorizationPending
        case "slow_down":
            let nextInterval = Self.jsonInt(parsed?["interval"])
            throw CloudAccountClientError.slowDown(interval: nextInterval)
        case "expired_token":
            throw CloudAccountClientError.expiredToken
        case "access_denied":
            throw CloudAccountClientError.accessDenied
        default:
            throw CloudAccountClientError.serviceError(code: errCode, message: errMsg, status: http.statusCode)
        }
    }

    static func parseTokenSet(_ body: [String: Any], nowMs: Double = Date().timeIntervalSince1970 * 1000.0) throws -> CloudOAuthTokenSet {
        guard let access = body["access_token"] as? String, !access.isEmpty,
              let refresh = body["refresh_token"] as? String, !refresh.isEmpty,
              let expiresIn = Self.jsonDouble(body["expires_in"])
        else {
            throw CloudAccountClientError.unexpectedResponse
        }
        let expiresAt = nowMs + max(0, expiresIn * 1000.0 - expiryMarginMs)
        return CloudOAuthTokenSet(accessToken: access, refreshToken: refresh, accessExpiresAt: expiresAt)
    }

    static func encodeForm(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/?;")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    private static func trimmed(_ raw: String, max: Int, fallback: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : String(s.prefix(max))
    }
}

/// Persists direct Sarto Cloud tokens & account profile in a `0600` file for clients without a daemon.
public struct CloudAccountSessionStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil, appGroupIdentifier: String? = DeviceIdentityStore.defaultAppGroupIdentifier) {
        #if os(macOS)
        let groupID: String? = nil
        #else
        let groupID = appGroupIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        if let fileURL {
            self.fileURL = fileURL
        } else if let groupID,
                  !groupID.isEmpty,
                  let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            self.fileURL = containerURL
                .appendingPathComponent("Sarto", isDirectory: true)
                .appendingPathComponent("cloud-account.json")
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = appSupport
                .appendingPathComponent("Sarto", isDirectory: true)
                .appendingPathComponent("cloud-account.json")
        }
    }

    public func load() -> CloudAccountSessionRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CloudAccountSessionRecord.self, from: data)
    }

    public func save(_ record: CloudAccountSessionRecord) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.resolvingSymlinksInPath().path)
        let data = try JSONEncoder().encode(record)
        let resolved = fileURL.resolvingSymlinksInPath()
        try Self.writeOwnerOnlyAtomically(data: data, to: resolved)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolved.path)
        #if !os(macOS)
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: resolved.path
        )
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = resolved
        try? mutableURL.setResourceValues(values)
    }

    private static func writeOwnerOnlyAtomically(data: Data, to url: URL) throws {
        let tempPath = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            .path
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var ok = data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                base = base.advanced(by: written)
            }
            return true
        }
        if ok && fsync(fd) != 0 { ok = false }
        let savedErrno = errno
        if close(fd) != 0 { ok = false }
        if ok && rename(tempPath, url.path) != 0 { ok = false }
        if !ok {
            let finalErrno = errno != 0 ? errno : savedErrno
            unlink(tempPath)
            throw POSIXError(POSIXErrorCode(rawValue: finalErrno) ?? .EIO)
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Account-authenticated discovery handshake helpers matching `src/shared/remote/discovery.ts`.
public enum DiscoveryPairProtocol {
    /// Binds a discovery handshake apart from a paired device's and a QR code's.
    public static let prologue = Data("sarto-channel/1 discover".utf8)
    public static let codeContext = Data("sarto-pair-code/1".utf8)
    public static let nonceBytes = 32

    public static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// SHA-256 commit to this device's 32-byte nonce, encoded as base64url.
    public static func commit(nonce: Data) -> String {
        BaseEncoding.base64URLEncode(Data(SHA256.hash(data: nonce)))
    }

    /// Six-digit verification code matching `pairCode()` in `src/shared/remote/discovery.ts`.
    public static func pairCode(handshakeHash: Data, hostNonce: Data, deviceNonce: Data) -> String {
        var input = Data(capacity: codeContext.count + handshakeHash.count + hostNonce.count + deviceNonce.count)
        input.append(codeContext)
        input.append(handshakeHash)
        input.append(hostNonce)
        input.append(deviceNonce)
        let digest = Data(SHA256.hash(data: input))
        let number: UInt32 = (UInt32(digest[0]) << 24)
            | (UInt32(digest[1]) << 16)
            | (UInt32(digest[2]) << 8)
            | UInt32(digest[3])
        return String(format: "%06u", number % 1_000_000)
    }
}

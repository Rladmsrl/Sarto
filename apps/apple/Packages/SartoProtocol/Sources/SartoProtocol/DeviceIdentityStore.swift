import Foundation

/// Persisted record of a paired Sarto host (Mac or Linux daemon).
public struct PairedHostRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var platform: String
    /// Base64URL-encoded 32-byte X25519 static public key of the host.
    public let hostPublicKey: String
    /// Optional 32-byte Ed25519 signing public key of the host (hex, base64url, or base64).
    public var hostEd25519PublicKey: String?
    public var addresses: [DirectAddress]
    public var relayID: String?
    public var relayURLs: [String]
    public var lastConnectedAt: Date?

    public init(
        id: String,
        name: String,
        platform: String = "darwin",
        hostPublicKey: String,
        addresses: [DirectAddress] = [],
        relayID: String? = nil,
        relayURLs: [String] = [],
        lastConnectedAt: Date? = nil,
        hostEd25519PublicKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.hostPublicKey = hostPublicKey
        self.hostEd25519PublicKey = hostEd25519PublicKey
        self.addresses = addresses
        self.relayID = relayID
        self.relayURLs = relayURLs
        self.lastConnectedAt = lastConnectedAt
    }

    public var hostPublicKeyData: Data? {
        if let decoded = BaseEncoding.base64URLDecode(hostPublicKey), decoded.count == 32 {
            return decoded
        }
        if let decoded = Data(base64Encoded: hostPublicKey), decoded.count == 32 {
            return decoded
        }
        return nil
    }

    public var hostEd25519PublicKeyData: Data? {
        guard let raw = hostEd25519PublicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        // Check 64-char hex before base64url since 64 hex chars are also valid base64url alphabet.
        if raw.count == 64, let hex = BaseEncoding.hexDecode(raw), hex.count == 32 {
            return hex
        }
        if let b64url = BaseEncoding.base64URLDecode(raw), b64url.count == 32 {
            return b64url
        }
        if let b64 = Data(base64Encoded: raw), b64.count == 32 {
            return b64
        }
        return nil
    }
}

public enum DeviceIdentityStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidPrivateKey

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return "Stored device private key is invalid"
        }
    }
}

/// Persists this Apple device's X25519 static keypair and paired host list locally.
public struct DeviceIdentityStore: Sendable {
    public static let defaultAppGroupIdentifier = "group.dev.sarto.shared"

    private struct StoredState: Codable {
        let privateKeyBase64URL: String
        var hosts: [PairedHostRecord]
    }

    public let fileURL: URL

    private var backupFileURL: URL {
        fileURL.appendingPathExtension("bak")
    }

    public init(fileURL: URL? = nil, appGroupIdentifier: String? = nil) {
        #if os(macOS)
        // The Mac app is signed without a provisioning profile, so it holds no app group: the system
        // denies creating the group container, every save fails and each launch made a new key.
        let groupID: String? = nil
        #else
        let groupID = appGroupIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let legacyURL = appSupport
            .appendingPathComponent("Sarto", isDirectory: true)
            .appendingPathComponent("device-identity.json")
        if let fileURL {
            self.fileURL = fileURL
        } else if let groupID,
                  !groupID.isEmpty,
                  let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            let groupFileURL = containerURL
                .appendingPathComponent("Sarto", isDirectory: true)
                .appendingPathComponent("device-identity.json")
            self.fileURL = groupFileURL
            Self.migrateLegacyIdentityIfNeeded(from: legacyURL, to: groupFileURL)
        } else {
            self.fileURL = legacyURL
        }
    }

    /// Migrates an existing sandbox identity file into the shared App Group container once the
    /// App Group entitlement is enabled, preserving the device's X25519 keypair and paired hosts.
    private static func migrateLegacyIdentityIfNeeded(from legacyURL: URL, to groupFileURL: URL) {
        let fm = FileManager.default
        guard legacyURL.standardizedFileURL != groupFileURL.standardizedFileURL,
              !fm.fileExists(atPath: groupFileURL.path),
              fm.fileExists(atPath: legacyURL.path),
              (try? readIdentity(from: legacyURL)) != nil,
              let bytes = try? Data(contentsOf: legacyURL)
        else { return }
        let dir = groupFileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        writeProtectedFile(data: bytes, to: groupFileURL)
    }

    /// Loads an existing identity from disk. Returns `nil` ONLY when `fileURL` does not exist;
    /// throws if the file exists on disk and cannot be read or decoded.
    public func loadExistingIdentity() throws -> (keyPair: NoiseKeyPair, hosts: [PairedHostRecord])? {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            return try Self.readIdentity(from: fileURL)
        }
        return nil
    }

    /// Loads the persisted identity, or creates and saves a fresh one ONLY if `fileURL` does not exist.
    /// Never overwrites an existing identity file on transient read or decode failures.
    public func loadOrCreateIdentity() -> (keyPair: NoiseKeyPair, hosts: [PairedHostRecord]) {
        let loaded = loadIdentity()
        return (loaded.keyPair, loaded.hosts)
    }

    /// As `loadOrCreateIdentity`, saying too whether the identity is the one on disk. One that is
    /// not was made for this run alone because the stored one could not be read, as before the
    /// first unlock after a restart: the caller loads again later, and `save` keeps it off disk.
    public func loadIdentity() -> (keyPair: NoiseKeyPair, hosts: [PairedHostRecord], isPersisted: Bool) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            if fm.fileExists(atPath: backupFileURL.path) {
                if let recovered = try? Self.readIdentity(from: backupFileURL) {
                    let saved = save(keyPair: recovered.keyPair, hosts: recovered.hosts)
                    return (recovered.keyPair, recovered.hosts, saved)
                }
                // A backup that cannot be read now may hold the device's key: nothing is saved.
                if (try? Data(contentsOf: backupFileURL)) == nil {
                    return (NoiseKeyPair(), [], false)
                }
            }
            let fresh = NoiseKeyPair()
            let saved = save(keyPair: fresh, hosts: [])
            return (fresh, [], saved)
        }

        if let loaded = try? Self.readIdentity(from: fileURL) {
            #if os(macOS)
            restrictExistingPermissions()
            #endif
            return (loaded.keyPair, loaded.hosts, true)
        }

        // Primary file exists on disk yet failed to read/decode (e.g. transient lock or interrupted write):
        // try reading the `.bak` snapshot or return an ephemeral key without clobbering `fileURL`.
        if let backup = try? Self.readIdentity(from: backupFileURL) {
            return (backup.keyPair, backup.hosts, true)
        }
        return (NoiseKeyPair(), [], false)
    }

    /// Whether saving `keyPair` would replace another identity kept on disk, or one that cannot be
    /// read right now. A file whose contents are not an identity at all stands in the way only
    /// while its backup holds another key.
    private func wouldReplaceStoredIdentity(with keyPair: NoiseKeyPair) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        guard (try? Data(contentsOf: fileURL)) != nil else { return true }
        if let stored = try? Self.readIdentity(from: fileURL) {
            return stored.keyPair.privateKeyData != keyPair.privateKeyData
        }
        if let backup = try? Self.readIdentity(from: backupFileURL) {
            return backup.keyPair.privateKeyData != keyPair.privateKeyData
        }
        return false
    }

    /// Saves the identity; false when nothing was written. An identity on disk is never replaced by
    /// another key: a load that failed leaves the app with a key made for one run, and saving that
    /// one would lose every pairing for good.
    @discardableResult
    public func save(keyPair: NoiseKeyPair, hosts: [PairedHostRecord]) -> Bool {
        guard !wouldReplaceStoredIdentity(with: keyPair) else { return false }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        #if os(macOS)
        // The file holds the device's private key, so other local users must not list or read it.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.resolvingSymlinksInPath().path)
        #else
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #endif

        // Preserve the last known-good file in `.bak` before replacing `fileURL`.
        if fm.fileExists(atPath: fileURL.path),
           (try? Self.readIdentity(from: fileURL)) != nil,
           let existingBytes = try? Data(contentsOf: fileURL) {
            Self.writeProtectedFile(data: existingBytes, to: backupFileURL)
        }

        let state = StoredState(
            privateKeyBase64URL: BaseEncoding.base64URLEncode(keyPair.privateKeyData),
            hosts: hosts
        )
        guard let encoded = try? JSONEncoder().encode(state) else { return false }
        Self.writeProtectedFile(data: encoded, to: fileURL)
        return true
    }

    #if os(macOS)
    /// Identities saved by older builds may sit in a world-listable folder.
    private func restrictExistingPermissions() {
        let fm = FileManager.default
        try? fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        )
        for url in [fileURL, backupFileURL] where fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.resolvingSymlinksInPath().path)
        }
    }
    #endif

    public func updateHostEd25519PublicKey(hostId: String, ed25519PublicKey: String) {
        guard var existing = try? loadExistingIdentity() else { return }
        var changed = false
        for idx in existing.hosts.indices {
            if existing.hosts[idx].id == hostId || existing.hosts[idx].relayID == hostId {
                existing.hosts[idx].hostEd25519PublicKey = ed25519PublicKey
                changed = true
            }
        }
        if changed {
            save(keyPair: existing.keyPair, hosts: existing.hosts)
        }
    }

    private static func readIdentity(from url: URL) throws -> (keyPair: NoiseKeyPair, hosts: [PairedHostRecord]) {
        let data = try Data(contentsOf: url)
        let stored = try JSONDecoder().decode(StoredState.self, from: data)
        guard let privBytes = BaseEncoding.base64URLDecode(stored.privateKeyBase64URL) else {
            throw DeviceIdentityStoreError.invalidPrivateKey
        }
        let pair = try NoiseKeyPair(privateKeyData: privBytes)
        return (pair, stored.hosts)
    }

    private static func writeProtectedFile(data: Data, to url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        if !writeOwnerOnlyAtomically(data: data, to: resolved) {
            try? data.write(to: resolved, options: [.atomic])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolved.path)
        #if !os(macOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: resolved.path
        )
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = resolved
        try? mutableURL.setResourceValues(values)
    }

    /// Writes through a sibling temporary file created 0600 and renamed over `url`, so the key is
    /// never readable by others, not even between the write and a later chmod.
    private static func writeOwnerOnlyAtomically(data: Data, to url: URL) -> Bool {
        let tempPath = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            .path
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
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
        if close(fd) != 0 { ok = false }
        if ok && rename(tempPath, url.path) != 0 { ok = false }
        if !ok { unlink(tempPath) }
        return ok
    }
}

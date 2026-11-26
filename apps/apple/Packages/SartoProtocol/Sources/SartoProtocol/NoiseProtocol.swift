import CryptoKit
import Foundation

/// Errors thrown during Noise_IK_25519_AESGCM_SHA256 / Noise_IKpsk1_25519_AESGCM_SHA256 handshakes
/// and transport encryption.
public enum NoiseError: Error, Sendable, Equatable {
    case invalidKeyLength
    case invalidPSKLength
    case missingPSK
    case unexpectedPSK
    case messageTooLong
    case messageTooShort
    case nonceExhausted
    case decryptionFailed
    case keyExchangeFailed
    case remoteStaticRefused
    case handshakeFailed
    case handshakeAlreadyFinished
    case handshakeNotFinished
    case handshakeAlreadySplit
    case wrongTurn
    case missingKeyForToken
    case cannotRekeyWithoutKey
}

public enum NoisePattern: String, Sendable {
    case ik = "IK"
    case ikpsk1 = "IKpsk1"

    var protocolName: String {
        "Noise_\(rawValue)_25519_AESGCM_SHA256"
    }

    var messagePatterns: [[NoiseToken]] {
        switch self {
        case .ik:
            return [[.e, .es, .s, .ss], [.e, .ee, .se]]
        case .ikpsk1:
            return [[.e, .es, .s, .ss, .psk], [.e, .ee, .se]]
        }
    }
}

public enum NoiseRole: Sendable {
    case initiator
    case responder
}

enum NoiseToken: Sendable {
    case e, s, ee, es, se, ss, psk
}

/// X25519 key pair backed by Apple CryptoKit.
public struct NoiseKeyPair: Sendable {
    public let privateKeyData: Data
    public let publicKeyData: Data

    public init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.privateKeyData = key.rawRepresentation
        self.publicKeyData = key.publicKey.rawRepresentation
    }

    public init(privateKeyData: Data) throws {
        guard privateKeyData.count == 32 else { throw NoiseError.invalidKeyLength }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        self.privateKeyData = key.rawRepresentation
        self.publicKeyData = key.publicKey.rawRepresentation
    }

    func dh(remotePublicKey: Data) throws -> Data {
        guard remotePublicKey.count == 32 else { throw NoiseError.invalidKeyLength }
        do {
            let local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
            let secret = try local.sharedSecretFromKeyAgreement(with: remote)
            let bytes = secret.withUnsafeBytes { Data($0) }
            if bytes.allSatisfy({ $0 == 0 }) {
                throw NoiseError.keyExchangeFailed
            }
            return bytes
        } catch let err as NoiseError {
            throw err
        } catch {
            throw NoiseError.keyExchangeFailed
        }
    }
}

/// Constants matching src/shared/remote/noise.ts.
public enum NoiseConstants {
    public static let dhLen = 32
    public static let hashLen = 32
    public static let tagLen = 16
    public static let maxMessage = 65535
    public static let defaultPrologue = Data("sarto-channel/1".utf8)
}

/// AES-256-GCM CipherState following Noise Revision 34 (32 zero bits + 64-bit big-endian counter).
public final class NoiseCipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    private static let maxNonce: UInt64 = UInt64.max - 1
    private static let rekeyNonceBytes = Data([0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])

    public init(keyData: Data? = nil) throws {
        if let keyData {
            guard keyData.count == 32 else { throw NoiseError.invalidKeyLength }
            self.key = SymmetricKey(data: keyData)
        } else {
            self.key = nil
        }
    }

    public var hasKey: Bool { key != nil }

    public func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return plaintext }
        guard plaintext.count + NoiseConstants.tagLen <= NoiseConstants.maxMessage else {
            throw NoiseError.messageTooLong
        }
        let iv = try nextNonce()
        let gcmNonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: ad)
        var out = Data(capacity: sealed.ciphertext.count + sealed.tag.count)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    public func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count <= NoiseConstants.maxMessage else {
            throw NoiseError.messageTooLong
        }
        guard ciphertext.count >= NoiseConstants.tagLen else {
            throw NoiseError.decryptionFailed
        }
        let iv = try nextNonce()
        let gcmNonce = try AES.GCM.Nonce(data: iv)
        let ctEnd = ciphertext.count - NoiseConstants.tagLen
        let ct = ciphertext.prefix(ctEnd)
        let tag = ciphertext.suffix(NoiseConstants.tagLen)
        do {
            let box = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseError.decryptionFailed
        }
    }

    /// Noise Rekey() without resetting the counter, matching src/shared/remote/noise.ts.
    public func rekey() throws {
        guard let key else { throw NoiseError.cannotRekeyWithoutKey }
        let gcmNonce = try AES.GCM.Nonce(data: Self.rekeyNonceBytes)
        let zeros = Data(count: 32)
        let sealed = try AES.GCM.seal(zeros, using: key, nonce: gcmNonce)
        self.key = SymmetricKey(data: sealed.ciphertext.prefix(32))
    }

    private func nextNonce() throws -> Data {
        guard nonce < Self.maxNonce else { throw NoiseError.nonceExhausted }
        var iv = Data(count: 12)
        let current = nonce
        nonce &+= 1
        var bigEndian = current.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            iv.replaceSubrange(4..<12, with: bytes)
        }
        return iv
    }
}

public struct NoiseTransportCiphers {
    public let send: NoiseCipherState
    public let receive: NoiseCipherState
}

private final class SymmetricState {
    private var cipher: NoiseCipherState
    private var chainingKey: Data
    private(set) var hash: Data

    init(protocolName: String) throws {
        let nameData = Data(protocolName.utf8)
        let initialHash: Data
        if nameData.count <= NoiseConstants.hashLen {
            var padded = Data(count: NoiseConstants.hashLen)
            padded.replaceSubrange(0..<nameData.count, with: nameData)
            initialHash = padded
        } else {
            initialHash = Data(SHA256.hash(data: nameData))
        }
        self.chainingKey = initialHash
        self.hash = initialHash
        self.cipher = try NoiseCipherState(keyData: nil)
    }

    var hasKey: Bool { cipher.hasKey }

    func mixKey(_ input: Data) throws {
        let outputs = hkdf(chainingKey: chainingKey, input: input, count: 2)
        chainingKey = outputs[0]
        cipher = try NoiseCipherState(keyData: outputs[1])
    }

    func mixHash(_ data: Data) {
        var combined = Data(capacity: hash.count + data.count)
        combined.append(hash)
        combined.append(data)
        hash = Data(SHA256.hash(data: combined))
    }

    func mixKeyAndHash(_ input: Data) throws {
        let outputs = hkdf(chainingKey: chainingKey, input: input, count: 3)
        chainingKey = outputs[0]
        mixHash(outputs[1])
        cipher = try NoiseCipherState(keyData: outputs[2])
    }

    func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(plaintext, ad: hash)
        mixHash(ciphertext)
        return ciphertext
    }

    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ciphertext, ad: hash)
        mixHash(ciphertext)
        return plaintext
    }

    func split() throws -> (NoiseCipherState, NoiseCipherState) {
        let outputs = hkdf(chainingKey: chainingKey, input: Data(), count: 2)
        return (try NoiseCipherState(keyData: outputs[0]), try NoiseCipherState(keyData: outputs[1]))
    }

    private func hkdf(chainingKey: Data, input: Data, count: Int) -> [Data] {
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: input,
            using: SymmetricKey(data: chainingKey)
        )))
        var outputs: [Data] = []
        outputs.reserveCapacity(count)
        var previous = Data()
        for i in 1...count {
            var block = Data(capacity: previous.count + 1)
            block.append(previous)
            block.append(UInt8(i))
            let mac = Data(HMAC<SHA256>.authenticationCode(for: block, using: tempKey))
            outputs.append(mac)
            previous = mac
        }
        return outputs
    }
}

/// Noise_IK_25519_AESGCM_SHA256 / Noise_IKpsk1_25519_AESGCM_SHA256 handshake state machine.
public final class NoiseHandshake {
    private let pattern: NoisePattern
    private let role: NoiseRole
    private let staticKey: NoiseKeyPair
    private let fixedEphemeral: NoiseKeyPair?
    private let psk: Data?
    private let acceptRemoteStatic: ((Data) -> Bool)?
    private let symmetric: SymmetricState
    private let messages: [[NoiseToken]]

    private var ephemeral: NoiseKeyPair?
    private var remoteEphemeral: Data?
    public private(set) var remoteStaticKey: Data?

    private var index = 0
    private var failed = false
    private var didSplit = false

    public init(
        pattern: NoisePattern,
        role: NoiseRole,
        staticKey: NoiseKeyPair,
        remoteStaticKey: Data? = nil,
        psk: Data? = nil,
        prologue: Data = NoiseConstants.defaultPrologue,
        ephemeral: NoiseKeyPair? = nil,
        acceptRemoteStatic: ((Data) -> Bool)? = nil
    ) throws {
        if pattern == .ikpsk1 {
            guard let psk else { throw NoiseError.missingPSK }
            guard psk.count == 32 else { throw NoiseError.invalidPSKLength }
        } else if psk != nil {
            throw NoiseError.unexpectedPSK
        }

        if role == .initiator {
            guard let remoteStaticKey, remoteStaticKey.count == NoiseConstants.dhLen else {
                throw NoiseError.invalidKeyLength
            }
            self.remoteStaticKey = remoteStaticKey
        } else {
            self.remoteStaticKey = nil
        }

        self.pattern = pattern
        self.role = role
        self.staticKey = staticKey
        self.fixedEphemeral = ephemeral
        self.psk = psk
        self.acceptRemoteStatic = acceptRemoteStatic
        self.messages = pattern.messagePatterns

        self.symmetric = try SymmetricState(protocolName: pattern.protocolName)
        self.symmetric.mixHash(prologue)
        if role == .initiator, let remoteStaticKey {
            self.symmetric.mixHash(remoteStaticKey)
        } else {
            self.symmetric.mixHash(staticKey.publicKeyData)
        }
    }

    public var isFinished: Bool { index == messages.count }

    public var handshakeHash: Data {
        get throws {
            guard isFinished else { throw NoiseError.handshakeNotFinished }
            return symmetric.hash
        }
    }

    public func writeMessage(payload: Data = Data()) throws -> Data {
        try step(writing: true) {
            var out = Data()
            for token in messages[index] {
                switch token {
                case .e:
                    let pair = fixedEphemeral ?? NoiseKeyPair()
                    ephemeral = pair
                    out.append(pair.publicKeyData)
                    try mixEphemeral(pair.publicKeyData)
                case .s:
                    out.append(try symmetric.encryptAndHash(staticKey.publicKeyData))
                default:
                    try mixToken(token)
                }
            }
            out.append(try symmetric.encryptAndHash(payload))
            guard out.count <= NoiseConstants.maxMessage else { throw NoiseError.messageTooLong }
            return out
        }
    }

    public func readMessage(_ message: Data) throws -> Data {
        try step(writing: false) {
            guard message.count <= NoiseConstants.maxMessage else { throw NoiseError.messageTooLong }
            var offset = message.startIndex
            func take(_ length: Int) throws -> Data {
                guard let end = message.index(offset, offsetBy: length, limitedBy: message.endIndex) else {
                    throw NoiseError.messageTooShort
                }
                let slice = Data(message[offset..<end])
                offset = end
                return slice
            }

            for token in messages[index] {
                switch token {
                case .e:
                    let re = try take(NoiseConstants.dhLen)
                    remoteEphemeral = re
                    try mixEphemeral(re)
                case .s:
                    let len = symmetric.hasKey
                        ? NoiseConstants.dhLen + NoiseConstants.tagLen
                        : NoiseConstants.dhLen
                    let rs = try symmetric.decryptAndHash(try take(len))
                    if role == .responder, let accept = acceptRemoteStatic, !accept(rs) {
                        throw NoiseError.remoteStaticRefused
                    }
                    remoteStaticKey = rs
                default:
                    try mixToken(token)
                }
            }

            return try symmetric.decryptAndHash(Data(message[offset..<message.endIndex]))
        }
    }

    public func split() throws -> NoiseTransportCiphers {
        guard isFinished, !failed else { throw NoiseError.handshakeNotFinished }
        guard !didSplit else { throw NoiseError.handshakeAlreadySplit }
        didSplit = true
        let (initiatorToResponder, responderToInitiator) = try symmetric.split()
        switch role {
        case .initiator:
            return NoiseTransportCiphers(send: initiatorToResponder, receive: responderToInitiator)
        case .responder:
            return NoiseTransportCiphers(send: responderToInitiator, receive: initiatorToResponder)
        }
    }

    private func step(writing: Bool, body: () throws -> Data) throws -> Data {
        guard !failed else { throw NoiseError.handshakeFailed }
        guard !isFinished else { throw NoiseError.handshakeAlreadyFinished }
        let initiatorTurn = (index % 2) == 0
        let myTurn = (initiatorTurn == (role == .initiator))
        guard writing == myTurn else { throw NoiseError.wrongTurn }

        failed = true
        let result = try body()
        failed = false
        index += 1
        return result
    }

    private func mixEphemeral(_ publicKey: Data) throws {
        symmetric.mixHash(publicKey)
        if psk != nil {
            try symmetric.mixKey(publicKey)
        }
    }

    private func mixToken(_ token: NoiseToken) throws {
        if token == .psk {
            guard let psk else { throw NoiseError.missingPSK }
            try symmetric.mixKeyAndHash(psk)
            return
        }

        let local: NoiseKeyPair?
        let remote: Data?
        switch (role, token) {
        case (.initiator, .ee), (.responder, .ee):
            local = ephemeral
            remote = remoteEphemeral
        case (.initiator, .es), (.responder, .se):
            local = ephemeral
            remote = remoteStaticKey
        case (.initiator, .se), (.responder, .es):
            local = staticKey
            remote = remoteEphemeral
        case (.initiator, .ss), (.responder, .ss):
            local = staticKey
            remote = remoteStaticKey
        default:
            throw NoiseError.missingKeyForToken
        }

        guard let local, let remote else { throw NoiseError.missingKeyForToken }
        try symmetric.mixKey(try local.dh(remotePublicKey: remote))
    }
}

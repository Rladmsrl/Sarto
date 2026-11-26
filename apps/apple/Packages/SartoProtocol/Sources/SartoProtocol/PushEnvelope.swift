import CryptoKit
import Foundation

/// Unseals and verifies Sarto's end-to-end encrypted APNs push envelopes (src/shared/remote/push.ts).
public struct OpenedPushEnvelope: Sendable, Equatable {
    public let body: Data
    public let signature: Data
    public let signedPayload: Data
}

public enum PushEnvelope {
    private static let versionByte: UInt8 = 0x01
    private static let keyBytes = 32
    private static let tagBytes = 16
    private static let nonceBytes = 12
    private static let signatureBytes = 64
    private static let sealInfo = Data("sarto-push-seal/1".utf8)
    private static let contentPrefix = Data("sarto-push-content/1\n".utf8)
    private static let tagPrefix = Data("sarto-push-tag/1\n".utf8)

    /// Derives the collapse tag for a notification subject on a given host.
    public static func tag(devicePublicKey: Data, hostID: String, subject: String) -> String {
        var input = Data()
        input.append(tagPrefix)
        input.append(devicePublicKey)
        input.append(Data("\(hostID)\n\(subject)".utf8))
        let digest = Data(SHA256.hash(data: input))
        return BaseEncoding.base64URLEncode(digest.prefix(tagBytes))
    }

    /// Decrypts a sealed push envelope addressed to this device's X25519 key pair.
    public static func open(envelope: Data, deviceKey: NoiseKeyPair) -> OpenedPushEnvelope? {
        let minimum = 1 + keyBytes + tagBytes + signatureBytes
        guard envelope.count >= minimum, envelope[envelope.startIndex] == versionByte else {
            return nil
        }

        let header = Data(envelope.prefix(1 + keyBytes))
        let ephemeralPublic = Data(envelope[(envelope.startIndex + 1)..<(envelope.startIndex + 1 + keyBytes)])
        let sealedTail = Data(envelope.dropFirst(1 + keyBytes))

        guard let shared = try? deviceKey.dh(remotePublicKey: ephemeralPublic) else {
            return nil
        }

        var salt = Data(capacity: keyBytes * 2)
        salt.append(ephemeralPublic)
        salt.append(deviceKey.publicKeyData)
        let okm = hkdfSHA256(ikm: shared, salt: salt, info: sealInfo, length: keyBytes + nonceBytes)
        let aesKey = SymmetricKey(data: okm.prefix(keyBytes))
        let nonceData = okm.suffix(nonceBytes)

        guard sealedTail.count >= tagBytes,
              let nonce = try? AES.GCM.Nonce(data: nonceData)
        else { return nil }

        let ct = sealedTail.prefix(sealedTail.count - tagBytes)
        let gcmTag = sealedTail.suffix(tagBytes)

        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: gcmTag),
              let plain = try? AES.GCM.open(box, using: aesKey, authenticating: header),
              plain.count >= signatureBytes
        else { return nil }

        let signature = Data(plain.prefix(signatureBytes))
        let body = Data(plain.dropFirst(signatureBytes))

        var signed = Data(capacity: contentPrefix.count + keyBytes * 2 + body.count)
        signed.append(contentPrefix)
        signed.append(deviceKey.publicKeyData)
        signed.append(ephemeralPublic)
        signed.append(body)

        return OpenedPushEnvelope(body: body, signature: signature, signedPayload: signed)
    }

    /// Opens and verifies a push envelope against the expected host Ed25519 public key.
    public static func openAndVerify(
        envelope: Data,
        deviceKey: NoiseKeyPair,
        hostEd25519PublicKey: Data
    ) -> Data? {
        guard let opened = open(envelope: envelope, deviceKey: deviceKey) else { return nil }
        guard RelayProtocol.verifySignature(
            ed25519PublicKey: hostEd25519PublicKey,
            signature: opened.signature,
            over: opened.signedPayload
        ) else { return nil }
        return opened.body
    }

    private static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let prk = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: ikm,
            using: SymmetricKey(data: salt)
        )))
        var out = Data(capacity: length)
        var previous = Data()
        var counter: UInt8 = 1
        while out.count < length {
            var block = Data(capacity: previous.count + info.count + 1)
            block.append(previous)
            block.append(info)
            block.append(counter)
            previous = Data(HMAC<SHA256>.authenticationCode(for: block, using: prk))
            let needed = min(previous.count, length - out.count)
            out.append(previous.prefix(needed))
            counter &+= 1
        }
        return out
    }
}

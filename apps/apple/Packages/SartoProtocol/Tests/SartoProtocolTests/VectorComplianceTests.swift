import Foundation
import Testing
@testable import SartoProtocol

/// Byte-for-byte cross-language verification against Sarto's official protocol test vectors:
/// - src/shared/remote/noise-vectors.json
/// - src/shared/remote/relay-vectors.json
/// - src/shared/remote/push-vectors.json
@Suite("Sarto Protocol Cross-Language Vector Compliance")
struct VectorComplianceTests {
    private static func repoFile(_ relativePath: String) throws -> Data {
        let testFile = URL(fileURLWithPath: #filePath)
        // apps/apple/Packages/SartoProtocol/Tests/SartoProtocolTests/VectorComplianceTests.swift -> repo root
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return try Data(contentsOf: url)
    }

    @Test("Noise_IK and Noise_IKpsk1 match noise-vectors.json byte-for-byte")
    func noiseVectorsMatch() throws {
        struct MessageVector: Decodable {
            let payload: String
            let ciphertext: String
        }
        struct HandshakeVector: Decodable {
            let protocol_name: String
            let init_prologue: String
            let init_static: String
            let init_ephemeral: String
            let init_remote_static: String
            let init_psks: [String]?
            let resp_prologue: String
            let resp_static: String
            let resp_ephemeral: String
            let resp_psks: [String]?
            let handshake_hash: String
            let messages: [MessageVector]
        }
        struct VectorFile: Decodable { let vectors: [HandshakeVector] }

        let data = try Self.repoFile("src/shared/remote/noise-vectors.json")
        let file = try JSONDecoder().decode(VectorFile.self, from: data)
        #expect(file.vectors.count == 2)

        for vec in file.vectors {
            let pattern: NoisePattern = vec.protocol_name.contains("IKpsk1") ? .ikpsk1 : .ik
            let initStatic = try NoiseKeyPair(privateKeyData: try #require(BaseEncoding.hexDecode(vec.init_static)))
            let initEphemeral = try NoiseKeyPair(privateKeyData: try #require(BaseEncoding.hexDecode(vec.init_ephemeral)))
            let respStatic = try NoiseKeyPair(privateKeyData: try #require(BaseEncoding.hexDecode(vec.resp_static)))
            let respEphemeral = try NoiseKeyPair(privateKeyData: try #require(BaseEncoding.hexDecode(vec.resp_ephemeral)))
            let initRemote = try #require(BaseEncoding.hexDecode(vec.init_remote_static))
            let initPrologue = try #require(BaseEncoding.hexDecode(vec.init_prologue))
            let respPrologue = try #require(BaseEncoding.hexDecode(vec.resp_prologue))
            let initPsk = try vec.init_psks?.first.map { try #require(BaseEncoding.hexDecode($0)) }
            let respPsk = try vec.resp_psks?.first.map { try #require(BaseEncoding.hexDecode($0)) }

            let initiator = try NoiseHandshake(
                pattern: pattern,
                role: .initiator,
                staticKey: initStatic,
                remoteStaticKey: initRemote,
                psk: initPsk,
                prologue: initPrologue,
                ephemeral: initEphemeral
            )
            let responder = try NoiseHandshake(
                pattern: pattern,
                role: .responder,
                staticKey: respStatic,
                psk: respPsk,
                prologue: respPrologue,
                ephemeral: respEphemeral,
                acceptRemoteStatic: { $0 == initStatic.publicKeyData }
            )

            // Message 0: initiator -> responder
            let p0 = try #require(BaseEncoding.hexDecode(vec.messages[0].payload))
            let c0 = try initiator.writeMessage(payload: p0)
            #expect(BaseEncoding.hexEncode(c0) == vec.messages[0].ciphertext)
            let r0 = try responder.readMessage(c0)
            #expect(r0 == p0)

            // Message 1: responder -> initiator
            let p1 = try #require(BaseEncoding.hexDecode(vec.messages[1].payload))
            let c1 = try responder.writeMessage(payload: p1)
            #expect(BaseEncoding.hexEncode(c1) == vec.messages[1].ciphertext)
            let r1 = try initiator.readMessage(c1)
            #expect(r1 == p1)

            #expect(BaseEncoding.hexEncode(try initiator.handshakeHash) == vec.handshake_hash)
            #expect(BaseEncoding.hexEncode(try responder.handshakeHash) == vec.handshake_hash)

            let initTransport = try initiator.split()
            let respTransport = try responder.split()

            // Transport messages 2..5 alternate initiator -> responder and responder -> initiator
            for idx in 2..<vec.messages.count {
                let payload = try #require(BaseEncoding.hexDecode(vec.messages[idx].payload))
                if idx % 2 == 0 {
                    let ct = try initTransport.send.encrypt(payload)
                    #expect(BaseEncoding.hexEncode(ct) == vec.messages[idx].ciphertext)
                    #expect(try respTransport.receive.decrypt(ct) == payload)
                } else {
                    let ct = try respTransport.send.encrypt(payload)
                    #expect(BaseEncoding.hexEncode(ct) == vec.messages[idx].ciphertext)
                    #expect(try initTransport.receive.decrypt(ct) == payload)
                }
            }
        }
    }

    @Test("Ed25519 host ID and relay sign-in signature match relay-vectors.json")
    func relayVectorsMatch() throws {
        struct KeyVec: Decodable {
            let seed: String
            let publicKey: String
            let id: String
        }
        struct SignInVec: Decodable {
            let origin: String
            let nonce: String
            let text: String
            let signature: String
        }
        struct VectorFile: Decodable {
            let key: KeyVec
            let signIn: SignInVec
        }

        let data = try Self.repoFile("src/shared/remote/relay-vectors.json")
        let vec = try JSONDecoder().decode(VectorFile.self, from: data)

        let seed = try #require(BaseEncoding.base64URLDecode(vec.key.seed))
        let expectedPub = try #require(BaseEncoding.base64URLDecode(vec.key.publicKey))

        let derivedID = try RelayProtocol.hostID(fromEd25519PublicKey: expectedPub)
        #expect(derivedID == vec.key.id)

        let text = RelayProtocol.signInText(origin: vec.signIn.origin, hostID: derivedID, nonce: vec.signIn.nonce)
        #expect(String(data: text, encoding: .utf8) == vec.signIn.text)

        let expectedSig = try #require(BaseEncoding.base64URLDecode(vec.signIn.signature))
        #expect(RelayProtocol.verifySignature(ed25519PublicKey: expectedPub, signature: expectedSig, over: text))
        let tamperedText = RelayProtocol.signInText(origin: "https://relay.example.com", hostID: derivedID, nonce: vec.signIn.nonce)
        #expect(!RelayProtocol.verifySignature(ed25519PublicKey: expectedPub, signature: expectedSig, over: tamperedText))

        // Note: Apple CryptoKit may use hedged Ed25519 nonces (valid RFC 8032 signatures that differ
        // per call for fault-injection resistance), so verify public key match + signature validity.
        let signed = try RelayProtocol.signChallenge(
            ed25519Seed: seed,
            origin: vec.signIn.origin,
            hostID: derivedID,
            nonce: vec.signIn.nonce
        )
        #expect(signed.publicKey == expectedPub)
        #expect(signed.signature.count == 64)
        #expect(RelayProtocol.verifySignature(ed25519PublicKey: expectedPub, signature: signed.signature, over: text))
        #expect(!RelayProtocol.verifySignature(ed25519PublicKey: expectedPub, signature: signed.signature, over: tamperedText))
    }

    @Test("E2EE Push envelope decryption and Ed25519 verification match push-vectors.json")
    func pushVectorsMatch() throws {
        struct KeysVec: Decodable {
            let hostPublicKey: String
            let hostId: String
            let devicePrivateKey: String
            let devicePublicKey: String
        }
        struct SealedVec: Decodable {
            let name: String
            let body: String
            let signature: String
            let envelope: String
        }
        struct VectorFile: Decodable {
            let keys: KeysVec
            let tags: [String: String]
            let sealed: [SealedVec]
        }

        let data = try Self.repoFile("src/shared/remote/push-vectors.json")
        let vec = try JSONDecoder().decode(VectorFile.self, from: data)

        let hostPub = try #require(BaseEncoding.base64URLDecode(vec.keys.hostPublicKey))
        let devicePriv = try #require(BaseEncoding.base64URLDecode(vec.keys.devicePrivateKey))
        let deviceKey = try NoiseKeyPair(privateKeyData: devicePriv)
        #expect(BaseEncoding.base64URLEncode(deviceKey.publicKeyData) == vec.keys.devicePublicKey)

        for (subject, expectedTag) in vec.tags {
            let actual = PushEnvelope.tag(
                devicePublicKey: deviceKey.publicKeyData,
                hostID: vec.keys.hostId,
                subject: subject
            )
            #expect(actual == expectedTag)
        }

        for item in vec.sealed {
            let envBytes = try #require(BaseEncoding.base64URLDecode(item.envelope))
            let verifiedBody = try #require(PushEnvelope.openAndVerify(
                envelope: envBytes,
                deviceKey: deviceKey,
                hostEd25519PublicKey: hostPub
            ))
            #expect(String(data: verifiedBody, encoding: .utf8) == item.body)
        }
    }

    @Test("SartoChannel round-trips small JSON, deflated large JSON, and binary streams")
    func channelFramingRoundTrip() throws {
        let clientKey = NoiseKeyPair()
        let hostKey = NoiseKeyPair()
        let initHS = try NoiseHandshake(
            pattern: .ik,
            role: .initiator,
            staticKey: clientKey,
            remoteStaticKey: hostKey.publicKeyData
        )
        let respHS = try NoiseHandshake(
            pattern: .ik,
            role: .responder,
            staticKey: hostKey,
            acceptRemoteStatic: { $0 == clientKey.publicKeyData }
        )

        _ = try respHS.readMessage(try initHS.writeMessage())
        _ = try initHS.readMessage(try respHS.writeMessage())

        let clientChannel = SartoChannel(ciphers: try initHS.split())
        let hostChannel = SartoChannel(ciphers: try respHS.split())

        // 1. Small JSON
        let small = Data("{\"type\":\"hello\",\"protocol\":{\"min\":1,\"max\":4}}".utf8)
        let smallFrames = try clientChannel.seal(.json(small))
        #expect(smallFrames.count == 1)
        #expect(try hostChannel.open(frame: smallFrames[0]) == .json(small))

        // 2. Large JSON (>1 KiB, triggers raw deflate compression)
        let largeText = "{\"items\":[" + Array(repeating: "\"sarto-prism-optical\"", count: 200).joined(separator: ",") + "]}"
        let large = Data(largeText.utf8)
        let largeFrames = try clientChannel.seal(.json(large))
        var decodedLarge: ChannelMessage?
        for frame in largeFrames {
            if let msg = try hostChannel.open(frame: frame) { decodedLarge = msg }
        }
        #expect(decodedLarge == .json(large))

        // 3. Multi-frame binary stream (>65 KiB)
        let bigBlob = Data((0..<70_000).map { UInt8($0 & 0xff) })
        let blobFrames = try hostChannel.seal(.bytes(stream: 42, data: bigBlob))
        #expect(blobFrames.count >= 2)
        var decodedBlob: ChannelMessage?
        for frame in blobFrames {
            if let msg = try clientChannel.open(frame: frame) { decodedBlob = msg }
        }
        #expect(decodedBlob == .bytes(stream: 42, data: bigBlob))
    }
}

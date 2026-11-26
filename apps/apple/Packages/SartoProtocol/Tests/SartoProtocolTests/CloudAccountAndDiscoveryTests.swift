import CryptoKit
import Foundation
import XCTest
@testable import SartoProtocol

final class CloudAccountAndDiscoveryTests: XCTestCase {
    func testDiscoveryPairCodeMatchesSharedWireDerivation() {
        let hash = Data(repeating: 0x11, count: 32)
        let hostNonce = Data(repeating: 0x22, count: 32)
        let deviceNonce = Data(repeating: 0x33, count: 32)

        let code = DiscoveryPairProtocol.pairCode(
            handshakeHash: hash,
            hostNonce: hostNonce,
            deviceNonce: deviceNonce
        )
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))

        // Verify byte-for-byte match against SHA-256("sarto-pair-code/1" || hash || hostNonce || deviceNonce)
        var raw = Data("sarto-pair-code/1".utf8)
        raw.append(hash)
        raw.append(hostNonce)
        raw.append(deviceNonce)
        let digest = Data(SHA256.hash(data: raw))
        let n: UInt32 = (UInt32(digest[0]) << 24)
            | (UInt32(digest[1]) << 16)
            | (UInt32(digest[2]) << 8)
            | UInt32(digest[3])
        XCTAssertEqual(code, String(format: "%06u", n % 1_000_000))
    }

    func testDiscoveryCommitMatchesSHA256Base64URL() {
        let nonce = Data(repeating: 0xAB, count: 32)
        let commit = DiscoveryPairProtocol.commit(nonce: nonce)
        let expected = BaseEncoding.base64URLEncode(Data(SHA256.hash(data: nonce)))
        XCTAssertEqual(commit, expected)
    }

    func testCloudAccountFormEncodingAndTokenParsing() throws {
        let encoded = CloudAccountClient.encodeForm([
            "grant_type": CloudAccountClient.deviceGrantType,
            "client_id": CloudAccountClient.deviceClientID,
        ])
        XCTAssertTrue(encoded.contains("client_id=sarto-daemon"))
        XCTAssertTrue(encoded.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))

        let nowMs: Double = 1_700_000_000_000
        let tokens = try CloudAccountClient.parseTokenSet(
            [
                "access_token": "acc_123",
                "refresh_token": "ref_456",
                "expires_in": 3600,
            ],
            nowMs: nowMs
        )
        XCTAssertEqual(tokens.accessToken, "acc_123")
        XCTAssertEqual(tokens.refreshToken, "ref_456")
        XCTAssertEqual(tokens.accessExpiresAt, nowMs + 3_540_000)
    }

    func testCloudAccountSessionStoreRoundTripsWithRestrictedPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarto-cloud-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CloudAccountSessionStore(fileURL: dir.appendingPathComponent("cloud-account.json"))
        XCTAssertNil(store.load())

        let record = CloudAccountSessionRecord(
            origin: "https://sarto.1o.ink",
            tokens: CloudOAuthTokenSet(accessToken: "a", refreshToken: "r", accessExpiresAt: 9999999999999),
            profile: CloudAccountProfile(id: "u1", email: "user@example.com", name: "User")
        )
        try store.save(record)
        XCTAssertEqual(store.load(), record)

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        store.clear()
        XCTAssertNil(store.load())
    }
}

import CryptoKit
import Foundation
import Testing
@testable import SartoUpdate

/// Signed by Node.js's `crypto.sign` with the key whose seed is the bytes 1 to 32, as the release
/// scripts sign, so the app is checked against what they write.
enum NodeVectors {
    static let publicKey = "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="
    static let updateFile = Data(#"{"version":"0.3.0","files":[{"name":"Sarto-0.3.0-arm64.zip","size":10,"sha512":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBw=="}],"notes":{"en":["Faster start"],"zh-Hans":["启动更快"]}}"#.utf8)
    static let updateSignature = "/cZDRolm4tjT+kJmKb182k6orIzsbUjRZcSXBlUlSoJWfXCrHOyKvynCtR5EBVtWo7Kr+KH8GJnzJUw9xjNdBg=="
    static let listPayload = "eyJzZXJpYWwiOjMsInNvdXJjZXMiOlt7ImlkIjoic2FydG8iLCJ1cmwiOiJodHRwczovL3NhcnRvLjFvLmluay9yZWxlYXNlcyJ9LHsiaWQiOiJtaXJyb3IiLCJ1cmwiOiJodHRwczovL21pcnJvci5leGFtcGxlLmNvbS9zYXJ0byJ9XSwiY29ubmVjdFRpbWVvdXRTZWNvbmRzIjoxMCwic3RhbGxTZWNvbmRzIjoxNX0"
    static let listSignature = "QhWs12W1eBIjvyQtB07pOlIf3BXE5Y9k5wxKi6WlBk8cmNDvdK9U0BdS1BXvreezzD0XwCBFxc9cBLp6cJOhBA"
}

@Suite struct SignatureTests {
    let other = Curve25519.Signing.PrivateKey()
    var otherPublic: String { other.publicKey.rawRepresentation.base64EncodedString() }

    @Test func keysMatchTheReleaseToolsFile() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("tools/sarto/update-keys.json"))
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        #expect(SartoUpdateKeys.release == [keys["release"]?["current"], keys["release"]?["next"]].compactMap { $0 })
        #expect(SartoUpdateKeys.sources == [keys["sources"]?["current"], keys["sources"]?["next"]].compactMap { $0 })
        for key in SartoUpdateKeys.release + SartoUpdateKeys.sources {
            #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: key) ?? Data())) != nil)
        }
    }

    @Test func acceptsAnUpdateFileNodeSigned() {
        let sig = Data((NodeVectors.updateSignature + "\n").utf8)
        #expect(UpdateSignature.verifyUpdateFile(
            name: "latest-mac.json", file: NodeVectors.updateFile, signatureFile: sig, keys: [NodeVectors.publicKey]
        ))
        // Without the newline too, and under either of two keys.
        #expect(UpdateSignature.verifyUpdateFile(
            name: "latest-mac.json", file: NodeVectors.updateFile,
            signatureFile: Data(NodeVectors.updateSignature.utf8), keys: [otherPublic, NodeVectors.publicKey]
        ))
    }

    @Test func refusesAnUpdateFileSignedOtherwise() {
        let sig = Data((NodeVectors.updateSignature + "\n").utf8)
        var changed = NodeVectors.updateFile
        changed[changed.startIndex + 13] = UInt8(ascii: "4")
        #expect(!UpdateSignature.verifyUpdateFile(name: "latest-mac.json", file: changed, signatureFile: sig, keys: [NodeVectors.publicKey]))
        // The name is signed, so another channel's file does not pass.
        #expect(!UpdateSignature.verifyUpdateFile(name: "latest-beta-mac.json", file: NodeVectors.updateFile, signatureFile: sig, keys: [NodeVectors.publicKey]))
        #expect(!UpdateSignature.verifyUpdateFile(name: "latest-mac.json", file: NodeVectors.updateFile, signatureFile: sig, keys: [otherPublic]))
        #expect(!UpdateSignature.verifyUpdateFile(name: "latest-mac.json", file: NodeVectors.updateFile, signatureFile: sig, keys: SartoUpdateKeys.release))
        for bad in [NodeVectors.updateSignature + "\n\n", " " + NodeVectors.updateSignature, "", String(NodeVectors.updateSignature.dropLast(2))] {
            #expect(!UpdateSignature.verifyUpdateFile(name: "latest-mac.json", file: NodeVectors.updateFile, signatureFile: Data(bad.utf8), keys: [NodeVectors.publicKey]))
        }
    }

    @Test func checksFilesBySHA512() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sarto-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        #expect(try FileDigest.sha512(of: url) == Data(SHA512.hash(data: bytes)))
    }
}

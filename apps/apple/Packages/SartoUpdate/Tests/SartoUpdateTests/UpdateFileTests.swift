import CryptoKit
import Foundation
import Testing
@testable import SartoUpdate

@Suite struct UpdateFileTests {
    let hash = Data(repeating: 7, count: 64).base64EncodedString()

    func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func file(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "version": "0.3.0",
            "releaseDate": "2026-11-23T10:00:00.000Z",
            "minimumSystemVersion": "15.0",
            "files": [
                ["name": "Sarto-0.3.0-arm64.zip", "size": 100, "sha512": hash],
                ["name": "Sarto-0.3.0-arm64.dmg", "size": 120, "sha512": hash],
            ],
            "notes": ["en": ["Faster start"], "zh-Hans": ["启动更快"], "fr": ["ignored"]],
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }

    func failure(_ result: Result<UpdateFile, UpdateFileError>) -> String? {
        if case .failure(let error) = result { return error.reason }
        return nil
    }

    @Test func readsAnUpdateFile() throws {
        let read = try UpdateFile.parse(try json(file())).get()
        #expect(read.version == "0.3.0")
        #expect(read.archive(arch: "arm64")?.name == "Sarto-0.3.0-arm64.zip")
        #expect(read.diskImage(arch: "arm64")?.size == 120)
        #expect(read.archive(arch: "x64") == nil)
        let withDelta = try UpdateFile.parse(try json(file(["files": [
            ["name": "Sarto-0.2.9-0.3.0-arm64.delta", "size": 10, "sha512": hash, "from": "0.2.9"],
            ["name": "Sarto-0.3.0-arm64.zip", "size": 100, "sha512": hash],
        ]]))).get()
        #expect(withDelta.archive(arch: "arm64")?.name == "Sarto-0.3.0-arm64.zip")
        #expect(withDelta.delta(from: "0.2.9", arch: "arm64")?.size == 10)
        #expect(withDelta.delta(from: "0.2.8", arch: "arm64") == nil)
        #expect(read.notes == ["en": ["Faster start"], "zh-Hans": ["启动更快"]])
        #expect(read.runtime == nil)
        let withRuntime = try UpdateFile.parse(try json(file(["runtime": String(repeating: "0f", count: 32)]))).get()
        #expect(withRuntime.runtime == String(repeating: "0f", count: 32))
        #expect(read.supports(system: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        #expect(read.supports(system: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)))
        #expect(!read.supports(system: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)))
    }

    @Test func checksTheSignatureFirst() throws {
        let data = NodeVectors.updateFile
        let sig = Data(NodeVectors.updateSignature.utf8)
        #expect(try UpdateFile.verified(data, signatureFile: sig, keys: [NodeVectors.publicKey]).get().version == "0.3.0")
        #expect(failure(UpdateFile.verified(data, signatureFile: sig)) == "its signature does not hold")
    }

    @Test func refusesAFileThatBreaksARule() throws {
        let cases: [(String, [String: Any])] = [
            ("its version is not X.Y.Z", ["version": "v0.3.0"]),
            ("its version is not X.Y.Z", ["version": "0.3"]),
            ("its version is not X.Y.Z", ["version": "0.3.0-beta.1"]),
            ("its minimum system version is not a version", ["minimumSystemVersion": "15.x"]),
            ("it lists no files or more than 16", ["files": []]),
            ("a file has no valid name, size or SHA-512", ["files": [["name": "../Sarto.zip", "size": 1, "sha512": hash]]]),
            ("a file has no valid name, size or SHA-512", ["files": [["name": "Sarto.zip", "size": 0, "sha512": hash]]]),
            ("a file has no valid name, size or SHA-512", ["files": [["name": "Sarto.zip", "size": 1, "sha512": "AAAA"]]]),
            ("it lists Sarto.zip twice", ["files": [["name": "Sarto.zip", "size": 1, "sha512": hash], ["name": "Sarto.zip", "size": 2, "sha512": hash]]]),
            ("its en notes are not a short list", ["notes": ["en": Array(repeating: "x", count: 6)]]),
            ("its en notes are not short lines", ["notes": ["en": [String(repeating: "x", count: 201)]]]),
            ("its runtime is not a fingerprint", ["runtime": "abc"]),
            ("the delta Sarto.delta is not from a version", ["files": [["name": "Sarto.delta", "size": 1, "sha512": hash, "from": "v1"]]]),
            ("its runtime is not a fingerprint", ["runtime": String(repeating: "A", count: 64)]),
        ]
        for (expected, overrides) in cases {
            #expect(failure(UpdateFile.parse(try json(file(overrides)))) == expected)
        }
        #expect(failure(UpdateFile.parse(Data("[1]".utf8))) == "it is not a JSON object")
    }

    @Test func parsesAndVerifiesBetaChannelUpdateFiles() throws {
        let betaJSON = try json(file([
            "version": "0.4.0-beta.261125143512",
            "channel": "beta",
            "build": "261125143512",
            "daemonVersion": "0.5.0-beta.261125143512",
            "daemonBuild": "261125143512",
            "tag": "app-v0.4.0-beta.261125143512",
            "files": [
                ["name": "Sarto-0.4.0-beta.261125143512-arm64.zip", "size": 100, "sha512": hash],
                ["name": "Sarto-0.4.0-beta.261125140000-0.4.0-beta.261125143512-arm64.delta", "size": 12, "sha512": hash, "from": "0.4.0-beta.261125140000"],
            ],
        ]))

        // Stable channel rejects beta files even before signature checks.
        #expect(failure(UpdateFile.parse(betaJSON, channel: .stable)) == "its version is not X.Y.Z")

        let parsed = try UpdateFile.parse(betaJSON, channel: .beta).get()
        #expect(parsed.version == "0.4.0-beta.261125143512")
        #expect(parsed.channel == .beta)
        #expect(parsed.build == "261125143512")
        #expect(parsed.daemonVersion == "0.5.0-beta.261125143512")
        #expect(parsed.daemonBuild == "261125143512")
        #expect(parsed.releaseTag == "app-v0.4.0-beta.261125143512")
        #expect(parsed.delta(from: "0.4.0-beta.261125140000", arch: "arm64")?.size == 12)

        // Signature binds the file to beta-mac.json so it cannot pass as latest-mac.json.
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let sigBytes = try key.signature(for: UpdateSignature.updateFileMessage(name: UpdateFile.betaName, file: betaJSON))
        let sigFile = Data((sigBytes.base64EncodedString() + "\n").utf8)
        #expect(try UpdateFile.verified(betaJSON, signatureFile: sigFile, channel: .beta, keys: [pub]).get().version == "0.4.0-beta.261125143512")
        #expect(failure(UpdateFile.verified(betaJSON, signatureFile: sigFile, channel: .stable, keys: [pub])) == "its signature does not hold")

        // Rejects invalid tags, builds and dev versions on beta channel.
        #expect(failure(UpdateFile.parse(try json(file(["version": "0.4.0-dev.261125143512"])), channel: .beta)) == "its version is not a valid beta or release version")
        #expect(failure(UpdateFile.parse(try json(file(["tag": "../escape"])), channel: .stable)) == "its tag is not a valid release tag")
        #expect(failure(UpdateFile.parse(try json(file(["build": "012345"])), channel: .stable)) == "its build is not a valid build number")
        #expect(failure(UpdateFile.parse(try json(file(["channel": "beta"])), channel: .stable)) == "a stable update file cannot declare channel beta")
    }
}

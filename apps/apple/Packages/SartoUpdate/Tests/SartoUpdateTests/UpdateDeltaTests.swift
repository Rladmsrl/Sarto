import CryptoKit
import Foundation
import Testing
@testable import SartoUpdate

/// A delta tools/sarto/delta.mjs wrote (block 64, patches from 256 bytes) from the old app below to
/// the new one: a patched executable, files kept, moved, added and removed, and a link.
private let nodeFixture = "U0FSVE9ERUxUQTEKAAAFFnsiZnJvbSI6IjEuMC4wIiwidG8iOiIxLjAuMSIsImVudHJpZXMiOlt7InBhdGgiOiJDb250ZW50cyIsImtpbmQiOiJkaXIifSx7InBhdGgiOiJDb250ZW50cy9JbmZvLnBsaXN0Iiwia2luZCI6ImZpbGUiLCJtb2RlIjo0MjAsInNpemUiOjEwLCJzaGEyNTYiOiJjMDMwMzM4NmZlYmU5YjI2NDBhMmEwNWNmYjA0Yzk0ZDIwYzY4NzVkNWY2MjU1NmRkYjhlNzQyYzlmNzQ0NjAxIiwic291cmNlIjp7InR5cGUiOiJkYXRhIiwiZGF0YSI6WzAsMTJdfX0seyJwYXRoIjoiQ29udGVudHMvTWFjT1MiLCJraW5kIjoiZGlyIn0seyJwYXRoIjoiQ29udGVudHMvTWFjT1MvYXBwIiwia2luZCI6ImZpbGUiLCJtb2RlIjo0OTMsInNpemUiOjQxMzMsInNoYTI1NiI6ImQ0NjUyZGI5YWU1MGRiMDJiMjgwYTAxMWVlY2Q1YjQyMjU3OWQwNTZlMTgzZDJmYjMxZjcyNGE4Y2RlYTkzZDAiLCJzb3VyY2UiOnsidHlwZSI6InBhdGNoIiwicGF0aCI6IkNvbnRlbnRzL01hY09TL2FwcCIsIm9wcyI6W1swLDAsMTQ3Ml0sWzEsNjddLFswLDMwMDgsMTA4OF0sWzEsNF0sWzAsMTA4OCwxNDcyXSxbMSwzMF1dLCJkYXRhIjpbMTIsNjRdfX0seyJwYXRoIjoiQ29udGVudHMvUmVzb3VyY2VzIiwia2luZCI6ImRpciJ9LHsicGF0aCI6IkNvbnRlbnRzL1Jlc291cmNlcy9rZWVwLnR4dCIsImtpbmQiOiJmaWxlIiwibW9kZSI6NDIwLCJzaXplIjoxMCwic2hhMjU2IjoiMWNkMjYzZjExMDI2NTZkZDZiNmNmMWQ2MjZkMWE5NmY5ZWJhMDQwNmFmM2NiMmE1MjU2MGQ0NzNkNDgwMTA1MiIsInNvdXJjZSI6eyJ0eXBlIjoib2xkIiwicGF0aCI6IkNvbnRlbnRzL1Jlc291cmNlcy9rZWVwLnR4dCJ9fSx7InBhdGgiOiJDb250ZW50cy9SZXNvdXJjZXMvbGluayIsImtpbmQiOiJsaW5rIiwidGFyZ2V0Ijoia2VlcC50eHQifSx7InBhdGgiOiJDb250ZW50cy9SZXNvdXJjZXMvbW92ZWQudHh0Iiwia2luZCI6ImZpbGUiLCJtb2RlIjo0MjAsInNpemUiOjMzLCJzaGEyNTYiOiI2ZTExNTAxMDM2MWQwNDg4ODMyNzRhNWRjNDBkZWMyNjBmYjhmZGNkMjRlNGU1MDIwMGQzMDFhNDkyNTE1MWIwIiwic291cmNlIjp7InR5cGUiOiJvbGQiLCJwYXRoIjoiQ29udGVudHMvUmVzb3VyY2VzL3N1Yi9tb3ZlZC50eHQifX0seyJwYXRoIjoiQ29udGVudHMvUmVzb3VyY2VzL25ldy50eHQiLCJraW5kIjoiZmlsZSIsIm1vZGUiOjQyMCwic2l6ZSI6MTAsInNoYTI1NiI6IjIxODljZWYzNzUzM2JlOTU4NGZiNzkwZmEzYWI0ODQyZjdjY2Q2NzBjZGU1ZWZjYTYyZmQ0ZWYzNWEzZTQwMmQiLCJzb3VyY2UiOnsidHlwZSI6ImRhdGEiLCJkYXRhIjpbNzYsMTJdfX1dfctLLVcoyMksLuECAOMVkVbSNDC3c/UJjkrMyC+rbemeNHPB8nVb9xw+tYoYcPGGlaOHf3JWYUV9W++U2YtWbti+7+iZy7cevgiFAwBLKkrMS1HISy3nAgA="

@Suite struct UpdateDeltaTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sarto-delta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var appBytes: Data { Data((0..<4096).map { UInt8(($0 * 7) % 251) }) }

    func put(_ app: URL, _ rel: String, _ data: Data, executable: Bool = false) throws {
        let url = app.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    func oldApp() throws -> URL {
        let app = root.appendingPathComponent("old-\(UUID().uuidString).app")
        try put(app, "Contents/Info.plist", Data("old plist\n".utf8))
        try put(app, "Contents/MacOS/app", appBytes, executable: true)
        try put(app, "Contents/Resources/keep.txt", Data("unchanged\n".utf8))
        try put(app, "Contents/Resources/gone.txt", Data("removed\n".utf8))
        try put(app, "Contents/Resources/sub/moved.txt", Data(String(repeating: "moved file\n", count: 3).utf8))
        return app
    }

    func write(_ delta: Data) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).delta")
        try delta.write(to: url)
        return url
    }

    /// A delta laid out as delta.mjs lays one out, from these entries and their payload.
    func delta(_ entries: [[String: Any]], payload: Data = Data()) throws -> URL {
        let manifest = try JSONSerialization.data(withJSONObject: ["from": "1.0.0", "to": "1.0.1", "entries": entries])
        var bytes = Data("SARTODELTA1\n".utf8)
        let length = UInt32(manifest.count)
        bytes.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        bytes.append(manifest)
        bytes.append(payload)
        return try write(bytes)
    }

    func deflate(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func buildsTheNewAppFromADeltaNodeWrote() throws {
        let new = root.appendingPathComponent("new.app")
        let summary = try UpdateDelta.apply(
            delta: try write(Data(base64Encoded: nodeFixture)!), oldApp: try oldApp(), newApp: new
        )
        #expect(summary == UpdateDelta.Summary(from: "1.0.0", to: "1.0.1", files: 5))
        var next = Data(appBytes.prefix(1500))
        next.append(Data(repeating: 0xAA, count: 37))
        next.append(appBytes[1500..<4086])
        next.append(Data(repeating: 0x55, count: 10))
        #expect(try Data(contentsOf: new.appendingPathComponent("Contents/MacOS/app")) == next)
        #expect(try String(contentsOf: new.appendingPathComponent("Contents/Info.plist"), encoding: .utf8) == "new plist\n")
        #expect(try String(contentsOf: new.appendingPathComponent("Contents/Resources/moved.txt"), encoding: .utf8)
            == String(repeating: "moved file\n", count: 3))
        #expect(try String(contentsOf: new.appendingPathComponent("Contents/Resources/new.txt"), encoding: .utf8) == "brand new\n")
        #expect(try fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("Contents/Resources/link").path) == "keep.txt")
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("Contents/Resources/gone.txt").path))
        let mode = try fm.attributesOfItem(atPath: new.appendingPathComponent("Contents/MacOS/app").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func refusesAFileThatComesOutOtherwise() throws {
        let text = Data("hello\n".utf8)
        let compressed = try deflate(text)
        let entry: [String: Any] = [
            "path": "a.txt", "kind": "file", "mode": 0o644, "size": text.count,
            "sha256": hex(Data("other\n".utf8)), "source": ["type": "data", "data": [0, compressed.count]],
        ]
        #expect(throws: UpdateDelta.Failure.mismatch("a.txt does not match the delta")) {
            try UpdateDelta.apply(
                delta: try delta([entry], payload: compressed), oldApp: try oldApp(), newApp: root.appendingPathComponent("n1.app")
            )
        }
        // A file the running app lacks, or has changed, fails the same way.
        let kept: [String: Any] = [
            "path": "keep.txt", "kind": "file", "mode": 0o644, "size": 10,
            "sha256": hex(Data("different\n".utf8)), "source": ["type": "old", "path": "Contents/Resources/keep.txt"],
        ]
        #expect(throws: UpdateDelta.Failure.mismatch("keep.txt does not match the delta")) {
            try UpdateDelta.apply(delta: try delta([kept]), oldApp: try oldApp(), newApp: root.appendingPathComponent("n2.app"))
        }
    }

    @Test func refusesAnythingOutsideTheApp() throws {
        let old = try oldApp()
        let zero = String(repeating: "0", count: 64)
        let escapes: [[String: Any]] = [
            ["path": "../evil", "kind": "dir"],
            ["path": "/etc/evil", "kind": "dir"],
            ["path": "Contents/./x", "kind": "dir"],
            ["path": "Contents/link", "kind": "link", "target": "../../../etc"],
            ["path": "Contents/link", "kind": "link", "target": "/etc/passwd"],
            ["path": "a", "kind": "file", "mode": 0o644, "size": 1, "sha256": zero,
             "source": ["type": "old", "path": "../../outside"]],
            ["path": "a", "kind": "file", "mode": 0o644, "size": 1, "sha256": zero,
             "source": ["type": "data", "data": [0, 9999]]],
            ["path": "a", "kind": "file", "mode": 0o4755, "size": 1, "sha256": zero,
             "source": ["type": "data", "data": [0, 0]]],
            ["path": "a", "kind": "file", "mode": 0o644, "size": 1, "sha256": zero,
             "source": ["type": "patch", "path": "Contents/MacOS/app", "ops": [[0, 4000, 500]], "data": [0, 0]]],
        ]
        for (index, entry) in escapes.enumerated() {
            #expect(throws: UpdateDelta.Failure.self, "\(entry)") {
                try UpdateDelta.apply(delta: try delta([entry]), oldApp: old, newApp: root.appendingPathComponent("e\(index).app"))
            }
        }
        #expect(UpdateDelta.linkStaysInside("Versions/Current/x"))
        #expect(!UpdateDelta.linkStaysInside("../MacOS/app"))
        #expect(!UpdateDelta.linkStaysInside("../outside"))
        // Contents/b -> a/.. reads as inside the app, and is not once Contents/a is a link too.
        let chain: [[String: Any]] = [
            ["path": "Contents", "kind": "dir"],
            ["path": "Contents/a", "kind": "link", "target": "."],
            ["path": "Contents/b", "kind": "link", "target": "a/.."],
        ]
        #expect(throws: UpdateDelta.Failure.self) {
            try UpdateDelta.apply(delta: try delta(chain), oldApp: old, newApp: root.appendingPathComponent("chain.app"))
        }
        #expect(throws: UpdateDelta.Failure.malformed("it has no delta header")) {
            try UpdateDelta.apply(delta: try write(Data("PK\u{3}\u{4}".utf8)), oldApp: old, newApp: root.appendingPathComponent("z.app"))
        }
        let existing = root.appendingPathComponent("existing.app")
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        #expect(throws: UpdateDelta.Failure.self) {
            try UpdateDelta.apply(delta: try delta([]), oldApp: old, newApp: existing)
        }
    }
}

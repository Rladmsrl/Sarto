import CryptoKit
import Foundation
import Testing
@testable import SartoUpdate

@Suite struct SourceListTests {
    let key = Curve25519.Signing.PrivateKey()
    var keys: [String] { [key.publicKey.rawRepresentation.base64EncodedString()] }

    func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func signed(_ list: [String: Any]) throws -> SignedSourceList {
        let bytes = try JSONSerialization.data(withJSONObject: list)
        return SignedSourceList(payload: base64url(bytes), signature: base64url(try key.signature(for: bytes)))
    }

    func list(
        serial: Any = 2,
        sources: [[String: Any]] = [["id": "mirror", "url": "https://mirror.example.com/sarto"]],
        connect: Any = 10,
        stall: Any = 15
    ) -> [String: Any] {
        ["serial": serial, "sources": sources, "connectTimeoutSeconds": connect, "stallSeconds": stall]
    }

    func reason(_ result: SourceListResult) -> String? {
        if case .failed(let reason) = result { return reason }
        return nil
    }

    @Test func acceptsAListNodeSigned() {
        let envelope = SignedSourceList(payload: NodeVectors.listPayload, signature: NodeVectors.listSignature)
        guard case .ok(let list, let kept) = UpdateSources.verify(envelope, minSerial: 3, keys: [NodeVectors.publicKey]) else {
            Issue.record("the list did not verify")
            return
        }
        #expect(kept == envelope)
        #expect(list.serial == 3)
        // The official source moves to the end.
        #expect(list.sources.map(\.id) == ["mirror", "sarto"])
        #expect(reason(UpdateSources.verify(envelope, minSerial: 4, keys: [NodeVectors.publicKey])) == "its serial 3 is older than 4")
        #expect(reason(UpdateSources.verify(envelope, minSerial: 0, keys: keys)) == "its signature does not hold")
    }

    @Test func keepsTheOfficialSourceLast() throws {
        let result = UpdateSources.verify(try signed(list(sources: [["id": "a", "url": "https://a.example.com/r"]])), minSerial: 0, keys: keys)
        guard case .ok(let read, _) = result else { Issue.record("not ok"); return }
        #expect(read.sources == [UpdateSource(id: "a", url: "https://a.example.com/r"), UpdateSources.official])
        let renamed = UpdateSources.withOfficialLast([UpdateSource(id: "x", url: "https://SARTO.1o.ink/releases"), UpdateSource(id: "b", url: "https://b.example.com")])
        #expect(renamed == [UpdateSource(id: "b", url: "https://b.example.com"), UpdateSources.official])
    }

    @Test func refusesAListThatBreaksARule() throws {
        let bad: [(String, [String: Any])] = [
            ("its serial is not a positive integer", list(serial: 0)),
            ("its serial is not a positive integer", list(serial: true)),
            ("its serial is not a positive integer", list(serial: 1.5)),
            ("it lists no sources or more than 8", list(sources: [])),
            ("it lists no sources or more than 8", list(sources: Array(repeating: ["id": "a", "url": "https://a.example.com"], count: 9))),
            ("a source has no valid id", list(sources: [["id": "Mirror", "url": "https://a.example.com"]])),
            ("its timeouts are not whole seconds from 1 to 120", list(connect: 0)),
            ("its timeouts are not whole seconds from 1 to 120", list(stall: 121)),
        ]
        for (expected, document) in bad {
            #expect(reason(UpdateSources.verify(try signed(document), minSerial: 0, keys: keys)) == expected)
        }
        for url in [
            "http://a.example.com", "https://a.example.com/", "https://a.example.com?x=1", "https://a.example.com#x",
            "https://user:pw@a.example.com", "https://a.example.com/a b", "https://a.example.com\\r", "ftp://a.example.com",
        ] {
            let result = UpdateSources.verify(try signed(list(sources: [["id": "a", "url": url]])), minSerial: 0, keys: keys)
            #expect(reason(result) == "source a has no https URL without a query, fragment or credentials", "\(url)")
        }
        #expect(reason(UpdateSources.parse(Data("[]".utf8), minSerial: 0, keys: keys)) == "it is not a signed list")
        #expect(reason(UpdateSources.verify(SignedSourceList(payload: "a+b", signature: "x"), minSerial: 0, keys: keys)) == "it is not a signed list")
    }

    @Test func movesAlongTheSourcesOfARun() {
        let list = SourceList(
            serial: 1,
            sources: [UpdateSource(id: "a", url: "https://a.example.com"), UpdateSources.official],
            connectTimeoutSeconds: 10,
            stallSeconds: 15
        )
        var run = SourceRun(list: list)
        #expect(run.current.id == "a")
        #expect(run.next()?.id == "sarto")
        #expect(run.next() == nil)
        #expect(run.again().current.id == "a")
        #expect(run.fromCurrent().current.id == "sarto")
        #expect(UpdateSources.builtIn.sources == [UpdateSources.github, UpdateSources.official])
        #expect(UpdateSources.officialOnly.sources == [UpdateSources.official])
        #expect(UpdateSources.github.latestFileURL("latest-mac.json")?.absoluteString == "https://github.com/Rladmsrl/Sarto/releases/latest/download/latest-mac.json")
        #expect(UpdateSources.official.latestFileURL("latest-mac.json")?.absoluteString == "https://sarto.1o.ink/releases/latest/download/latest-mac.json")
        #expect(UpdateSources.official.releaseFileURL(version: "0.3.0", name: "Sarto-0.3.0-arm64.zip")?.absoluteString == "https://sarto.1o.ink/releases/download/v0.3.0/Sarto-0.3.0-arm64.zip")
    }

    func release(_ version: String, _ channel: UpdateChannel = .stable) -> UpdateFile {
        UpdateFile(version: version, channel: channel, files: [])
    }

    @Test func betaAsksPastASourceWithoutABetaFile() {
        var run = SourceRun(list: UpdateSources.builtIn)
        var search = UpdateSearch(channel: .beta, current: "0.3.0")
        // GitHub never serves beta-mac.json at latest/download, so its stable file settles nothing.
        let fromGitHub = search.take(own: nil, stable: release("0.3.1"), from: run.fromCurrent())
        #expect(!fromGitHub)
        #expect(run.next()?.id == "sarto")
        let fromSarto = search.take(own: release("0.4.0-beta.261125143512", .beta), stable: release("0.3.1"), from: run.fromCurrent())
        #expect(fromSarto)
        #expect(search.found?.file.version == "0.4.0-beta.261125143512")
        #expect(search.found?.run.current.id == "sarto")
    }

    @Test func betaGraduatesOntoANewerStableRelease() {
        let run = SourceRun(list: UpdateSources.officialOnly)
        var search = UpdateSearch(channel: .beta, current: "0.4.0-beta.261125143512")
        let settled = search.take(own: release("0.4.0-beta.261125143512", .beta), stable: release("0.4.0"), from: run)
        #expect(settled)
        #expect(search.found?.file.version == "0.4.0")
    }

    @Test func stableStopsAtASourceThatIsUpToDate() {
        var run = SourceRun(list: UpdateSources.builtIn)
        var search = UpdateSearch(channel: .stable, current: "0.3.1")
        // A source that lags behind the running version sends the search on.
        let lagging = search.take(own: release("0.3.0"), stable: nil, from: run.fromCurrent())
        #expect(!lagging)
        #expect(run.next() != nil)
        // One offering the running version answers it: no update, and no source after it is asked.
        let upToDate = search.take(own: release("0.3.1"), stable: nil, from: run.fromCurrent())
        #expect(upToDate)
        #expect(search.found?.file.version == "0.3.1")
    }

    @Test func aSourceWithNothingSettlesNothing() {
        let run = SourceRun(list: UpdateSources.officialOnly)
        var search = UpdateSearch(channel: .stable, current: "0.3.1")
        let settled = search.take(own: nil, stable: nil, from: run)
        #expect(!settled)
        #expect(search.found == nil)
    }
}

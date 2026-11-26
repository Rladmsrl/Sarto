import Foundation
import XCTest
@testable import SartoProtocol

final class BrowserProtocolTests: XCTestCase {
    func testCheckAgentNavigationAllowsHttpHttpsAndBlankOnly() {
        XCTAssertEqual(try? BrowserPolicy.checkAgentNavigation("http://localhost:3000/app").get(), "http://localhost:3000/app")
        XCTAssertEqual(try? BrowserPolicy.checkAgentNavigation("https://example.com/path?q=1").get(), "https://example.com/path?q=1")
        XCTAssertEqual(try? BrowserPolicy.checkAgentNavigation("about:blank").get(), "about:blank")

        for forbidden in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "sarto-media://abc", "chrome://settings"] {
            switch BrowserPolicy.checkAgentNavigation(forbidden) {
            case .success:
                XCTFail("Expected forbidden URL to be rejected: \(forbidden)")
            case .failure(let err):
                XCTAssertEqual(err.code, "not_allowed")
            }
        }

        switch BrowserPolicy.checkAgentNavigation("not a url") {
        case .success:
            XCTFail("Expected malformed URL to be rejected")
        case .failure(let err):
            XCTAssertEqual(err.code, "invalid")
        }
    }

    func testLocalHostAndNormalizeUserInputURL() {
        XCTAssertTrue(BrowserPolicy.isLocalHost("localhost"))
        XCTAssertTrue(BrowserPolicy.isLocalHost("127.0.0.1"))
        XCTAssertTrue(BrowserPolicy.isLocalHost("::1"))
        XCTAssertTrue(BrowserPolicy.isLocalHost("[::1]"))
        XCTAssertTrue(BrowserPolicy.isLocalHost("app.localhost"))
        XCTAssertTrue(BrowserPolicy.isLocalHost("demo.test"))
        XCTAssertFalse(BrowserPolicy.isLocalHost("example.com"))

        XCTAssertEqual(BrowserPolicy.normalizeUserInputURL("localhost:5173")?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(BrowserPolicy.normalizeUserInputURL("127.0.0.1:8080/test")?.absoluteString, "http://127.0.0.1:8080/test")
        XCTAssertEqual(BrowserPolicy.normalizeUserInputURL("example.com/docs")?.absoluteString, "https://example.com/docs")
        XCTAssertNil(BrowserPolicy.normalizeUserInputURL("file:///etc/hosts"))
        XCTAssertNil(BrowserPolicy.normalizeUserInputURL("javascript:void(0)"))
    }

    func testParseKeyMatchesCdpSemantics() throws {
        let enter = try BrowserPolicy.parseKey("Enter").get()
        XCTAssertEqual(enter.key, "Enter")
        XCTAssertEqual(enter.code, "Enter")
        XCTAssertEqual(enter.keyCode, 13)
        XCTAssertEqual(enter.text, "\r")

        let ctrlA = try BrowserPolicy.parseKey("Control+a").get()
        XCTAssertEqual(ctrlA.key, "a")
        XCTAssertEqual(ctrlA.code, "KeyA")
        XCTAssertTrue(ctrlA.ctrlKey)
        XCTAssertNil(ctrlA.text)

        let shiftB = try BrowserPolicy.parseKey("Shift+b").get()
        XCTAssertEqual(shiftB.key, "B")
        XCTAssertEqual(shiftB.text, "B")
        XCTAssertTrue(shiftB.shiftKey)

        if case .success = BrowserPolicy.parseKey("BogusMod+Enter") {
            XCTFail("Unknown modifier should fail")
        }
    }

    func testHostEventDecodesAllBrowserEvents() throws {
        let callJSON = """
        {"type":"event","event":{"type":"browser.call","call":{"callId":42,"sessionId":"s1","tool":"browser_navigate","args":{"url":"http://localhost:5173"},"projectPath":"/tmp/demo","forward":{"host":"localhost","port":5173}}}}
        """
        let decodedCall = HostEvent.decode(fromEnvelopeData: Data(callJSON.utf8))
        guard case .browserCall(let call)? = decodedCall else {
            return XCTFail("Expected .browserCall event")
        }
        XCTAssertEqual(call.callId, 42)
        XCTAssertEqual(call.sessionId, "s1")
        XCTAssertEqual(call.tool, "browser_navigate")
        XCTAssertEqual(call.args["url"]?.stringValue, "http://localhost:5173")
        XCTAssertEqual(call.forward, BrowserForward(host: "localhost", port: 5173))

        let originJSON = """
        {"type":"event","event":{"type":"browser.originDecided","sessionId":"s1","requestId":7,"decision":"project"}}
        """
        XCTAssertEqual(
            HostEvent.decode(fromEnvelopeData: Data(originJSON.utf8)),
            .browserOriginDecided(sessionId: "s1", requestId: 7, decision: "project")
        )

        let turnJSON = """
        {"type":"event","event":{"type":"browser.turnEnded","sessionId":"s1"}}
        """
        XCTAssertEqual(
            HostEvent.decode(fromEnvelopeData: Data(turnJSON.utf8)),
            .browserTurnEnded(sessionId: "s1")
        )

        let askJSON = """
        {"type":"event","event":{"type":"browser.askAnswered","sessionId":"s1","outcome":"done"}}
        """
        XCTAssertEqual(
            HostEvent.decode(fromEnvelopeData: Data(askJSON.utf8)),
            .browserAskAnswered(sessionId: "s1", outcome: "done")
        )
    }

    func testLocalBrowserConnectFrameMatchesIdentifyPortSchema() throws {
        let data = try LocalBrowserPortIdentity.connectFrameData(
            deviceId: "0123456789abcdef0123456789abcdef",
            name: "Sarto"
        )
        let obj = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
        XCTAssertEqual(obj?["type"]?.stringValue, "host:connect")
        let dev = obj?["device"]?.objectValue
        XCTAssertEqual(dev?["id"]?.stringValue, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(dev?["name"]?.stringValue, "Sarto")
        XCTAssertEqual(dev?["local"]?.boolValue, true)
        XCTAssertEqual(dev?["browser"]?.boolValue, true)
        XCTAssertEqual(dev?["imageRefs"]?.boolValue, true)
        XCTAssertEqual(dev?["toolDigests"]?.boolValue, true)
    }
}

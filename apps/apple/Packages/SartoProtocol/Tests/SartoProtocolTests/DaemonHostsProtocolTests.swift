import Foundation
import XCTest
@testable import SartoProtocol

/// The local daemon's other hosts: its `hosts.*` events as `src/daemon/control.ts` sends them.
final class DaemonHostsProtocolTests: XCTestCase {
    private let hostJSON = """
    {
      "id": "0123456789abcdef0123456789abcdef",
      "publicKey": "xgs642YfNj4wxl9ohWvh2w2MhhvyFuZlYPlssBaYCAI=",
      "name": "Studio",
      "platform": "darwin",
      "version": "0.3.0",
      "addresses": [],
      "deviceName": "MacBook",
      "addedAt": 1764000000000,
      "lastOnlineAt": 1764000100000,
      "removed": false,
      "relay": { "id": "abcdefghijklmnopqrstuvwxyz", "urls": ["https://sarto.1o.ink"] },
      "connection": { "state": "online", "relay": "https://sarto.1o.ink", "terminal": true }
    }
    """

    func testHostsUpdatedDecodesFromAnEnvelope() throws {
        let data = Data(#"{"type":"event","event":{"type":"hosts.updated","hosts":[\#(hostJSON)]}}"#.utf8)
        guard case .otherHostsUpdated(let hosts)? = HostEvent.decode(fromEnvelopeData: data) else {
            return XCTFail("hosts.updated was not decoded")
        }
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.id, "0123456789abcdef0123456789abcdef")
        XCTAssertTrue(host.connection.isOnline)
        XCTAssertTrue(host.connection.viaRelay)
        XCTAssertTrue(host.connection.allowsTerminal)
        XCTAssertEqual(host.relay?.id, "abcdefghijklmnopqrstuvwxyz")
    }

    func testDirectConnectionIsNotTheRelay() throws {
        let json = #"{"state":"online","address":{"host":"192.168.1.2","port":60021}}"#
        let connection = try JSONDecoder().decode(OtherHostConnection.self, from: Data(json.utf8))
        XCTAssertTrue(connection.isOnline)
        XCTAssertFalse(connection.viaRelay)
        XCTAssertFalse(connection.allowsTerminal)
    }

    func testPairingDecodesItsHostOnceAdded() throws {
        let data = Data(#"{"type":"event","event":{"type":"hosts.pairing","pairId":3,"pairing":{"state":"added","host":\#(hostJSON)}}}"#.utf8)
        guard case .otherHostPairing(let pairId, let pairing)? = HostEvent.decode(fromEnvelopeData: data) else {
            return XCTFail("hosts.pairing was not decoded")
        }
        XCTAssertEqual(pairId, 3)
        XCTAssertTrue(pairing.isFinished)
        XCTAssertEqual(pairing.host?.name, "Studio")
    }

    func testFailedPairingKeepsItsReason() throws {
        let value = try JSONValue(jsonData: Data(#"{"type":"hosts.pairing","pairId":4,"pairing":{"state":"failed","reason":"signed_out"}}"#.utf8))
        guard case .otherHostPairing(_, let pairing) = HostEvent.decode(from: value) else {
            return XCTFail("hosts.pairing was not decoded")
        }
        XCTAssertEqual(pairing.state, "failed")
        XCTAssertEqual(pairing.reason, "signed_out")
    }
}

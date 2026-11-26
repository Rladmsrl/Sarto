import Foundation
import XCTest
@testable import SartoProtocol

final class DeviceProtocolTests: XCTestCase {
    func testDeviceEventDecodesScreenFrameAndOpened() throws {
        let payload = Data([0x01, 0x64, 0x00, 0x33])
        let b64 = payload.base64EncodedString()
        let frameEnvelope = """
        {"type":"event","event":{"type":"device.frame","deviceId":"ios-sim:abc","seq":12,"kind":"description","data":"\(b64)"}}
        """
        let decoded = DeviceEvent.decode(fromEnvelopeData: Data(frameEnvelope.utf8))
        XCTAssertEqual(decoded, .deviceFrame(deviceId: "ios-sim:abc", seq: 12, kind: "description", data: payload))

        // HostEvent also forwards remote multiplexed device events seamlessly
        let hostDecoded = HostEvent.decode(fromEnvelopeData: Data(frameEnvelope.utf8))
        XCTAssertEqual(
            hostDecoded,
            .deviceEvent(.deviceFrame(deviceId: "ios-sim:abc", seq: 12, kind: "description", data: payload))
        )

        let openedEnvelope = """
        {"type":"event","event":{"type":"device.opened","deviceId":"android:emulator-5554","sessionId":"s-42"}}
        """
        XCTAssertEqual(
            DeviceEvent.decode(fromEnvelopeData: Data(openedEnvelope.utf8)),
            .deviceOpened(deviceId: "android:emulator-5554", sessionId: "s-42")
        )
    }

    func testMobileDeviceInfoDecodesWithOperatorAndControl() throws {
        let json = """
        {
          "id": "ios-sim:800C2898",
          "platform": "ios",
          "kind": "simulator",
          "name": "iPhone 18 Pro",
          "osVersion": "27.2",
          "model": "iPhone 18 Pro",
          "state": "booted",
          "connection": null,
          "sessionId": "sess-1",
          "operator": {
            "sessionId": "sess-1",
            "agentName": "Claude Code",
            "user": false,
            "control": { "kind": "agent", "acting": true }
          },
          "problems": [],
          "input": true,
          "bootedByHost": true
        }
        """
        let device = try JSONDecoder().decode(MobileDeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(device.id, "ios-sim:800C2898")
        XCTAssertEqual(device.platform, .ios)
        XCTAssertEqual(device.kind, .simulator)
        XCTAssertEqual(device.state, .booted)
        XCTAssertEqual(device.operator?.agentName, "Claude Code")
        XCTAssertEqual(device.operator?.control?.kind, "agent")
        XCTAssertEqual(device.operator?.control?.acting, true)
    }

    func testDeviceInputActionEncodesProtocolJSON() {
        let touch = DeviceInputAction.touch(phase: "begin", x: 0.5, y: 0.25).toJSONValue().objectValue
        XCTAssertEqual(touch?["type"]?.stringValue, "touch")
        XCTAssertEqual(touch?["phase"]?.stringValue, "begin")
        XCTAssertEqual(touch?["x"]?.doubleValue, 0.5)
        XCTAssertEqual(touch?["y"]?.doubleValue, 0.25)

        let btn = DeviceInputAction.button("rotate").toJSONValue().objectValue
        XCTAssertEqual(btn?["type"]?.stringValue, "button")
        XCTAssertEqual(btn?["button"]?.stringValue, "rotate")
    }
}

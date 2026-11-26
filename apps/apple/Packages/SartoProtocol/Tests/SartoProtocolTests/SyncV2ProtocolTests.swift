import Foundation
import Testing
@testable import SartoProtocol

struct SyncV2ProtocolTests {
    @Test
    func decodesCloudAccountStatusSignedInAndSignedOut() throws {
        let signedInJSON = """
        {
          "origin": "https://cloud.sarto.dev",
          "fixedOrigin": true,
          "account": {
            "state": "signed-in",
            "account": {
              "id": "usr_1",
              "email": "dev@example.com",
              "name": "Dev",
              "avatar": null
            },
            "subscription": "pro",
            "plan": {
              "id": "pro",
              "name": "Pro",
              "maxDevices": 5,
              "storageBytes": 1073741824
            },
            "usage": {
              "devices": 2,
              "storageBytes": 4096
            },
            "points": 100,
            "manageUrl": "https://cloud.sarto.dev/account/",
            "pointsUrl": "https://cloud.sarto.dev/points/",
            "plainText": true
          }
        }
        """
        let status = try JSONDecoder().decode(CloudAccountStatusInfo.self, from: Data(signedInJSON.utf8))
        #expect(status.origin == "https://cloud.sarto.dev")
        #expect(status.fixedOrigin == true)
        #expect(status.account.isSignedIn == true)
        #expect(status.account.account?.email == "dev@example.com")
        #expect(status.account.plan?.maxDevices == 5)
        #expect(status.account.usage?.devices == 2)
        #expect(status.account.plainText == true)

        let signedOutJSON = """
        {
          "origin": "https://self.example.com",
          "fixedOrigin": false,
          "account": {
            "state": "signed-out",
            "reason": "reused",
            "failure": "device-limit",
            "devicesUrl": "https://self.example.com/account/"
          }
        }
        """
        let out = try JSONDecoder().decode(CloudAccountStatusInfo.self, from: Data(signedOutJSON.utf8))
        #expect(out.account.isSignedOut == true)
        #expect(out.account.reason == "reused")
        #expect(out.account.failure == "device-limit")
        #expect(out.account.devicesUrl == "https://self.example.com/account/")
    }

    @Test
    func decodesSartoSyncStatusV2KeybagApprovalAndUsageFields() throws {
        let json = """
        {
          "mode": "account",
          "serverUrl": "https://cloud.sarto.dev",
          "connected": true,
          "syncing": false,
          "lastSyncedAt": 1800000000000,
          "error": null,
          "account": { "id": "usr_1", "email": "dev@example.com", "name": "Dev" },
          "relayId": "abc123",
          "relayToken": null,
          "needsKey": false,
          "keyState": "ready",
          "plainText": false,
          "syncDeviceId": "0123456789abcdef0123456789abcdef",
          "approvalCode": null,
          "pendingApprovals": [
            {
              "deviceId": "fedcba9876543210fedcba9876543210",
              "devicePublicKey": "AAAA",
              "deviceName": "MacBook Air",
              "platform": "darwin",
              "code": "ABCD-EFGH",
              "createdAt": 1800000000000,
              "expiresAt": 1800000900000
            }
          ],
          "usageDeviceId": "0123456789abcdef",
          "usageDevices": [
            {
              "deviceId": "0123456789abcdef",
              "deviceName": "Mac Studio",
              "updatedAt": 1800000000000,
              "rev": 3,
              "hasIsland": true,
              "hasHost": true
            }
          ],
          "hostPublicKey": "BBBB",
          "revisions": { "ui-prefs": 4, "usage": 3 },
          "uiPrefs": {},
          "trustedHosts": []
        }
        """
        let status = try JSONDecoder().decode(SartoSyncStatusInfo.self, from: Data(json.utf8))
        #expect(status.mode == "account")
        #expect(status.isVaultReady == true)
        #expect(status.relayToken == nil)
        #expect(status.keyState == "ready")
        #expect(status.pendingApprovals.count == 1)
        #expect(status.pendingApprovals[0].code == "ABCD-EFGH")
        #expect(status.usageDevices.count == 1)
        #expect(status.usageDevices[0].hasIsland == true)
        #expect(status.usageDevices[0].rev == 3)
    }

    @Test
    func decodesTheStepOfAWaitingMacsApproval() throws {
        let json = """
        {
          "mode": "account",
          "needsKey": true,
          "keyState": "awaiting-approval",
          "approvalCode": "ABCD-EFGH",
          "approvalStage": "confirm",
          "approverName": "Mac Studio",
          "pendingApprovals": []
        }
        """
        let status = try JSONDecoder().decode(SartoSyncStatusInfo.self, from: Data(json.utf8))
        #expect(status.approvalStage == "confirm")
        #expect(status.approverName == "Mac Studio")
        #expect(status.approvalCode == "ABCD-EFGH")

        let earlier = try JSONDecoder().decode(
            SartoSyncStatusInfo.self,
            from: Data(#"{"mode":"account","keyState":"awaiting-approval"}"#.utf8)
        )
        #expect(earlier.approvalStage == nil)
        #expect(earlier.approverName == nil)
    }

    @Test
    func decodesAccountAndSyncUsageControlEvents() throws {
        let accountEvent = """
        {"type":"event","event":{"type":"account.updated","status":{"origin":"https://cloud.sarto.dev","fixedOrigin":false,"account":{"state":"signing-in"}}}}
        """
        let decodedAccount = HostEvent.decode(fromEnvelopeData: Data(accountEvent.utf8))
        if case .accountUpdated(let st)? = decodedAccount {
            #expect(st.account.isSigningIn == true)
        } else {
            Issue.record("Expected accountUpdated event")
        }

        let usageEvent = """
        {"type":"event","event":{"type":"sync.usage.updated","ownDeviceId":"mac1","records":[{"v":1,"deviceId":"mac2","deviceName":"Mac 2","updatedAt":1800000000000,"island":{"updatedAt":1800000000000,"payload":{"schema":1}}}]}}
        """
        let decodedUsage = HostEvent.decode(fromEnvelopeData: Data(usageEvent.utf8))
        if case .syncUsageUpdated(let ownId, let records)? = decodedUsage {
            #expect(ownId == "mac1")
            #expect(records.count == 1)
            #expect(records[0].deviceId == "mac2")
            #expect(records[0].island?.payload.objectValue?["schema"]?.doubleValue == 1)
        } else {
            Issue.record("Expected syncUsageUpdated event")
        }
    }
}

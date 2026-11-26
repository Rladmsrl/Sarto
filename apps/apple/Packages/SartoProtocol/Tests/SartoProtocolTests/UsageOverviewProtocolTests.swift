import Foundation
import XCTest
@testable import SartoProtocol

final class UsageOverviewProtocolTests: XCTestCase {
    func testOverviewDecodesTheHostsModel() throws {
        let json = """
        {
          "generatedAt": 1800000000000,
          "scope": "all",
          "pricesAsOf": "2026-11-20",
          "agents": [{
            "agentId": "claude-code",
            "available": true,
            "signedOut": false,
            "today": { "tokens": 1200, "cost": 0.42, "requests": 3, "unpricedTokens": 50 },
            "activity": { "at": 1799999000000, "model": "claude-fable-5" },
            "localActivity": null,
            "quota": {
              "account": "a1b2c3d4e5f60708",
              "plan": "Max 20×",
              "observedAt": 1799999900000,
              "device": { "id": "0123456789abcdef", "name": "Studio" },
              "primary": "five_hour",
              "secondary": "seven_day",
              "windows": [
                { "id": "five_hour", "kind": "session", "scope": null, "label": "5-hour", "minutes": 300,
                  "usedPercent": 40, "remaining": 0.6, "resetsAt": 1800003600000, "reset": false,
                  "observedAt": 1799999900000,
                  "forecast": { "status": { "kind": "exhausts", "seconds": 5400 },
                                "estimatedRemainingTokens": 900000, "windowTokens": 600000 } },
                { "id": "seven_day", "kind": "weekly", "scope": null, "label": "Weekly", "minutes": 10080,
                  "usedPercent": 0, "remaining": 1, "resetsAt": null, "reset": true, "observedAt": null,
                  "forecast": { "status": { "kind": "reset" }, "estimatedRemainingTokens": null, "windowTokens": 0 } },
                { "id": "seven_day_fable", "kind": "scoped", "scope": "Fable", "label": "Weekly · Fable",
                  "minutes": 10080, "usedPercent": 10, "remaining": 0.9, "resetsAt": 1800500000000,
                  "reset": false, "observedAt": null,
                  "forecast": { "status": { "kind": "survives", "remainingAtReset": 0.7 },
                                "estimatedRemainingTokens": null, "windowTokens": 10 } },
                { "id": "monthly_credits", "kind": "credits", "label": "Monthly", "usedPercent": 5,
                  "remaining": 0.95, "reset": false,
                  "forecast": { "status": { "kind": "someday" }, "windowTokens": 0 } }
              ]
            },
            "otherAccounts": [{ "account": null, "plan": null, "observedAt": null, "device": null,
                                "windows": [], "primary": null, "secondary": null }]
          }, { "agentId": 7 }],
          "models": [
            { "days": 1, "models": [{ "agentId": "claude-code", "model": "claude-fable-5", "tokens": 1200,
                                     "cost": 0.42, "requests": 3,
                                     "price": { "kind": "family", "model": "claude-fable-4", "origin": "bundled" } }] },
            { "days": 7, "models": [{ "agentId": "codex", "model": "gpt-9", "tokens": 5, "cost": 0, "requests": 1,
                                     "price": { "kind": "unpriced", "model": null, "origin": null } }] }
          ],
          "hourly": { "starts": [1799996400000, 1800000000000],
                      "agents": [{ "agentId": "claude-code", "tokens": [0, 1200], "cost": [0, 0.42] }] },
          "daily": { "starts": [], "agents": [] },
          "devices": [{ "id": "fedcba9876543210", "name": "This Mac", "updatedAt": 1799999999000, "thisComputer": true },
                      { "id": "0123456789abcdef", "name": "Studio", "updatedAt": null, "thisComputer": false }],
          "unpricedModels": ["gpt-9"],
          "familyPriced": [{ "model": "claude-fable-5", "standIn": "claude-fable-4" }]
        }
        """
        let overview = try JSONDecoder().decode(UsageOverviewInfo.self, from: Data(json.utf8))

        XCTAssertEqual(overview.scope, "all")
        XCTAssertEqual(overview.agents.count, 1, "an agent that cannot be read is dropped, not the overview")
        let claude = try XCTUnwrap(overview.agents.first)
        XCTAssertEqual(claude.today.requests, 3)
        XCTAssertEqual(claude.activity?.model, "claude-fable-5")
        XCTAssertNil(claude.localActivity)
        let quota = try XCTUnwrap(claude.quota)
        XCTAssertEqual(quota.device?.name, "Studio")
        XCTAssertEqual(quota.primaryWindow?.id, "five_hour")
        XCTAssertEqual(quota.secondaryWindow?.id, "seven_day")
        XCTAssertEqual(quota.windows.count, 4)
        XCTAssertEqual(quota.windows[0].forecast.status, .exhausts(seconds: 5400))
        XCTAssertEqual(quota.windows[0].forecast.estimatedRemainingTokens, 900000)
        XCTAssertEqual(quota.windows[1].forecast.status, .reset)
        XCTAssertTrue(quota.windows[1].reset)
        XCTAssertNil(quota.windows[1].resetsAt)
        XCTAssertEqual(quota.windows[2].scope, "Fable")
        XCTAssertEqual(quota.windows[2].forecast.status, .survives(remainingAtReset: 0.7))
        XCTAssertEqual(quota.windows[3].kind, .other, "a kind a newer host adds reads as other")
        XCTAssertEqual(quota.windows[3].forecast.status, .insufficient)
        XCTAssertEqual(claude.otherAccounts.count, 1)

        XCTAssertEqual(overview.models(days: 1).first?.price.kind, .family)
        XCTAssertEqual(overview.models(days: 1).first?.price.model, "claude-fable-4")
        XCTAssertEqual(overview.models(days: 7).first?.price.kind, .unpriced)
        XCTAssertTrue(overview.models(days: 90).isEmpty)
        XCTAssertEqual(overview.hourly.agents.first?.cost, [0, 0.42])
        XCTAssertEqual(overview.devices.map(\.thisComputer), [true, false])
        XCTAssertNil(overview.devices[1].updatedAt)
        XCTAssertEqual(overview.familyPriced.first?.standIn, "claude-fable-4")
    }

    func testOverviewFromAnOlderHostTakesEmptyValues() throws {
        let overview = try JSONDecoder().decode(UsageOverviewInfo.self, from: Data(#"{"agents":[{"agentId":"codex"}]}"#.utf8))
        XCTAssertEqual(overview.agents.first?.today.tokens, 0)
        XCTAssertNil(overview.agents.first?.quota)
        XCTAssertNil(overview.agents.first?.eligible, "an older host does not decide which quotas show")
        XCTAssertTrue(overview.devices.isEmpty)
        XCTAssertTrue(overview.daily.starts.isEmpty)
    }

    func testOverviewNamesWhichQuotasShowAndTheirAmounts() throws {
        let json = """
        {"agents":[{"agentId":"cursor","name":"Cursor","harnessId":"cursor","eligible":true,
          "quota":{"windows":[{"id":"monthly","kind":"weekly","label":"Monthly","usedPercent":6.8,
            "amount":{"used":27.06,"total":400,"unit":"USD"}}]}}]}
        """
        let cursor = try XCTUnwrap(JSONDecoder().decode(UsageOverviewInfo.self, from: Data(json.utf8)).agents.first)
        XCTAssertEqual(cursor.eligible, true)
        XCTAssertEqual(cursor.name, "Cursor")
        XCTAssertEqual(cursor.harnessId, "cursor")
        let amount = try XCTUnwrap(cursor.quota?.windows.first?.amount)
        XCTAssertEqual(amount.used, 27.06)
        XCTAssertEqual(amount.total, 400)
        XCTAssertEqual(amount.unit, "USD")
    }

    func testUsageChangedEventDecodes() {
        let envelope = #"{"type":"event","event":{"type":"usage.changed"}}"#
        XCTAssertEqual(HostEvent.decode(fromEnvelopeData: Data(envelope.utf8)), .usageChanged)
        XCTAssertEqual(HostEvent.decode(from: .object(["type": .string("usage.changed")])), .usageChanged)
    }
}

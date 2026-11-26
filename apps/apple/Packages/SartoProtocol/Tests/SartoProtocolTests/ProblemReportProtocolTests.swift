import Foundation
import Testing
@testable import SartoProtocol

@Suite("Problem Reports Protocol Models")
struct ProblemReportProtocolTests {
    @Test("Decodes PreparedReportInfo, ReportFileViewInfo, and ReportSubmitResultInfo")
    func decodesPreparedAndSubmitPayloads() throws {
        let preparedJSON = Data("""
        {
          "ok": true,
          "id": "prep-1",
          "size": 4096,
          "redactionCount": 7,
          "files": [
            { "path": "report.json", "size": 512, "kind": "text" },
            { "path": "crash/Sarto.ips", "size": 1024, "kind": "text" },
            { "path": "screenshot.png", "size": 2048, "kind": "image" }
          ]
        }
        """.utf8)
        let prepared = try JSONDecoder().decode(PreparedReportInfo.self, from: preparedJSON)
        #expect(prepared.ok == true)
        #expect(prepared.id == "prep-1")
        #expect(prepared.redactionCount == 7)
        #expect(prepared.files?.count == 3)
        #expect(prepared.files?[0].isSensitive == false)
        #expect(prepared.files?[1].isSensitive == true)

        let submitJSON = Data("""
        {
          "ok": true,
          "id": "SR-7F3K2Q",
          "anonymous": true,
          "consoleUrl": null,
          "issueUrl": "https://github.com/Rladmsrl/Sarto/issues/new?template=bug.yml&report-id=SR-7F3K2Q"
        }
        """.utf8)
        let submitted = try JSONDecoder().decode(ReportSubmitResultInfo.self, from: submitJSON)
        #expect(submitted.ok == true)
        #expect(submitted.id == "SR-7F3K2Q")
        #expect(submitted.anonymous == true)
        #expect(submitted.consoleUrl == nil)
        #expect(submitted.issueUrl?.contains("SR-7F3K2Q") == true)
    }

    @Test("Decodes CloudReportListInfo and serializes ReportClientPayloadInfo")
    func decodesCloudListAndEncodesClientPayload() throws {
        let listJSON = Data("""
        {
          "signedIn": true,
          "origin": "https://sarto.1o.ink",
          "total": 1,
          "countsByStatus": { "submitted": 0, "investigating": 1 },
          "reports": [
            {
              "id": "SR-2B4C6D",
              "title": "Relay reconnect loop",
              "description": "Details",
              "version": "0.3.0",
              "platform": "macOS 15.4 arm64",
              "deviceName": "Mac Studio",
              "status": "investigating",
              "issueUrl": null,
              "fixedInVersion": null,
              "hasBundle": true,
              "bundleSize": 12345,
              "commentCount": 2,
              "createdAt": 1700000000000,
              "updatedAt": 1700000001000,
              "anonymous": false
            }
          ]
        }
        """.utf8)
        let list = try JSONDecoder().decode(CloudReportListInfo.self, from: listJSON)
        #expect(list.signedIn == true)
        #expect(list.reports.count == 1)
        #expect(list.reports[0].id == "SR-2B4C6D")
        #expect(list.reports[0].commentCount == 2)

        let payload = ReportClientPayloadInfo(
            appVersion: "0.3.0",
            osVersion: "macOS 15.4",
            hardware: "Apple M4 Max arm64",
            crashReports: [ReportClientCrashPayload(name: "Sarto.ips", content: "trace")],
            screenshotBase64: "iVBORw=="
        )
        let json = payload.toJSONValue()
        #expect(json.objectValue?["appVersion"]?.stringValue == "0.3.0")
        #expect(json.objectValue?["crashReports"]?.arrayValue?.count == 1)
        #expect(json.objectValue?["screenshot"]?.stringValue == "iVBORw==")
    }
}

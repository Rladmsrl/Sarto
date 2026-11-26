import AppKit
import Darwin
import Foundation
import Observation
import SartoProtocol

/// Where the report sheet should be presented so it attaches to the active window naturally.
enum ProblemReportPresentationTarget: Sendable, Equatable {
    case main
    case settings
}

/// Launch parameters for opening the native Problem Report sheet from any entry point.
struct ProblemReportLaunchRequest: Identifiable, Sendable, Equatable {
    let id = UUID()
    let target: ProblemReportPresentationTarget
    let origin: String?
    let initialDescription: String
    let initialRange: String
    let initialExtras: Set<String>
    let sessionId: String?
    let agentId: String?
    let errorText: String?
    /// Set when opened from an agent-drafted `.problemReport` card so saving or submitting marks it answered.
    let threadEntryId: String?
    /// Non-nil when reporting about a remote Mac instead of the local daemon.
    let remoteHostId: String?
    let remoteHostName: String?
    /// Window screenshot captured before the sheet appeared (nil for remote hosts or if no window is visible).
    let capturedScreenshotBase64: String?
}

@MainActor
@Observable
final class ProblemReportCoordinator {
    var activeRequest: ProblemReportLaunchRequest? = nil
    var showCrashRecoveryBanner: Bool = false
    /// Incrementing token so Settings -> "My Problem Reports" refreshes right after a new submission.
    var reportsRefreshToken: Int = 0

    var onRequestOpenMainWindow: (() -> Void)?

    private var didCheckCrashMarker = false

    var mainWindowRequest: ProblemReportLaunchRequest? {
        get { activeRequest?.target == .main ? activeRequest : nil }
        set {
            if newValue == nil, activeRequest?.target == .main {
                activeRequest = nil
            } else if let newValue {
                activeRequest = newValue
            }
        }
    }

    var settingsWindowRequest: ProblemReportLaunchRequest? {
        get { activeRequest?.target == .settings ? activeRequest : nil }
        set {
            if newValue == nil, activeRequest?.target == .settings {
                activeRequest = nil
            } else if let newValue {
                activeRequest = newValue
            }
        }
    }

    /// Checks whether the previous run exited cleanly; writes the `running` marker for this run.
    func checkAndMarkRunningOnLaunch() {
        guard !didCheckCrashMarker else { return }
        didCheckCrashMarker = true
        let marker = SartoAppPaths.crashMarker()
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let existed = fm.fileExists(atPath: marker.path)
            try? fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stamp = "\(ProcessInfo.processInfo.processIdentifier) \(Int(Date().timeIntervalSince1970))\n"
            try? stamp.write(to: marker, atomically: true, encoding: .utf8)
            if existed {
                await MainActor.run { [weak self] in
                    self?.showCrashRecoveryBanner = true
                }
            }
        }
    }

    /// Removes the `running` marker on clean termination so the next launch does not show the crash notice.
    func removeCrashMarkerOnCleanQuit() {
        let marker = SartoAppPaths.crashMarker()
        try? FileManager.default.removeItem(at: marker)
    }

    func dismissCrashRecoveryBanner() {
        showCrashRecoveryBanner = false
    }

    func notifyReportSubmitted() {
        reportsRefreshToken += 1
    }

    /// Opens the Problem Report sheet, capturing a zero-permission screenshot of Sarto's own window
    /// before the sheet covers it (local Mac only).
    func open(
        target: ProblemReportPresentationTarget = .main,
        origin: String? = nil,
        initialDescription: String = "",
        initialRange: String = "hour",
        initialExtras: Set<String> = [],
        sessionId: String? = nil,
        agentId: String? = nil,
        errorText: String? = nil,
        threadEntryId: String? = nil,
        remoteHostId: String? = nil,
        remoteHostName: String? = nil
    ) {
        let screenshotBase64 = remoteHostId == nil ? Self.captureVisibleWindowScreenshotBase64() : nil
        if target == .main {
            onRequestOpenMainWindow?()
        }
        activeRequest = ProblemReportLaunchRequest(
            target: target,
            origin: origin,
            initialDescription: initialDescription,
            initialRange: initialRange,
            initialExtras: initialExtras,
            sessionId: sessionId,
            agentId: agentId,
            errorText: errorText,
            threadEntryId: threadEntryId,
            remoteHostId: remoteHostId,
            remoteHostName: remoteHostName,
            capturedScreenshotBase64: screenshotBase64
        )
    }

    /// Captures Sarto's own main window via AppKit view caching — requires zero macOS Screen Recording TCC permission.
    private static func captureVisibleWindowScreenshotBase64() -> String? {
        let candidate = NSApp.windows.first { win in
            !(win is NSPanel) && win.isVisible && !win.isMiniaturized && win.identifier?.rawValue.contains("main") == true
        } ?? NSApp.keyWindow
        guard let contentView = candidate?.contentView else { return nil }
        let bounds = contentView.bounds
        guard bounds.width >= 60, bounds.height >= 60 else { return nil }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        contentView.cacheDisplay(in: bounds, to: rep)

        // Downscale wide Retina captures to at most 1600px wide so PNG stays sharp and compact.
        let maxWidth: CGFloat = 1600
        let pngData: Data?
        if CGFloat(rep.pixelsWide) > maxWidth, let cgImage = rep.cgImage {
            let scale = maxWidth / CGFloat(rep.pixelsWide)
            let targetW = max(1, Int(CGFloat(rep.pixelsWide) * scale))
            let targetH = max(1, Int(CGFloat(rep.pixelsHigh) * scale))
            if let ctx = CGContext(
                data: nil,
                width: targetW,
                height: targetH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                if let scaled = ctx.makeImage() {
                    let scaledRep = NSBitmapImageRep(cgImage: scaled)
                    pngData = scaledRep.representation(using: .png, properties: [:])
                } else {
                    pngData = rep.representation(using: .png, properties: [:])
                }
            } else {
                pngData = rep.representation(using: .png, properties: [:])
            }
        } else {
            pngData = rep.representation(using: .png, properties: [:])
        }
        guard let pngData, !pngData.isEmpty else { return nil }
        return pngData.base64EncodedString()
    }

    /// Collects macOS system metadata, client logs, and optional `.ips` crash reports off the main actor.
    static func collectClientDiagnostics(
        rangeKind: String,
        includeCrashReports: Bool,
        screenshotBase64: String?,
        recentDaemonManagerLogs: [String]
    ) async -> ReportClientPayloadInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = (info["SartoVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info["CFBundleShortVersionString"] as? String)
        let rawBuild = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let channel = (info["SartoBuildChannel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let commit = (info["SartoGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let buildParts = [rawBuild, channel, commit].compactMap { $0 }
        let appBuild: String? = buildParts.isEmpty ? nil : String(buildParts.joined(separator: " ").prefix(64))
        let displaySummary: String? = NSScreen.main.map { screen in
            let f = screen.frame
            return "\(Int(f.width))x\(Int(f.height)) @\(Int(screen.backingScaleFactor))x"
        }
        let daemonOutputURL = SartoAppPaths.daemonOutput()

        return await Task.detached(priority: .utility) {
            let osVer = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            let cpuBrand = Self.sysctlString("machdep.cpu.brand_string")
            let hwModel = Self.sysctlString("hw.model")
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let hardware = [cpuBrand ?? hwModel, arch].compactMap { $0 }.joined(separator: " ")

            let now = Date()
            let cutoff = rangeStart(rangeKind, until: now)
            let output = Self.readTailUTF8(url: daemonOutputURL, maxBytes: 128 * 1024) ?? ""
            let lines = (recentDaemonManagerLogs + output.components(separatedBy: .newlines)).filter { line in
                guard let date = logDate(line) else { return false }
                return date >= cutoff && date <= now
            }
            let clientLog = lines.isEmpty ? nil : lines.joined(separator: "\n")

            let crashes: [ReportClientCrashPayload] = includeCrashReports
                ? Self.collectMacCrashReports(rangeKind: rangeKind)
                : []

            return ReportClientPayloadInfo(
                appVersion: appVersion,
                appBuild: appBuild,
                osVersion: osVer,
                hardware: hardware.isEmpty ? nil : hardware,
                display: displaySummary,
                clientLog: clientLog,
                crashReports: crashes,
                screenshotBase64: screenshotBase64
            )
        }.value
    }

    private nonisolated static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func readTailUTF8(url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? NSNumber)?.intValue,
              fileSize > 0
        else { return nil }
        let start = max(0, fileSize - maxBytes)
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func rangeStart(_ kind: String, until now: Date) -> Date {
        switch kind {
        case "hour": return now.addingTimeInterval(-3600)
        case "today": return Calendar.current.startOfDay(for: now)
        default: return now.addingTimeInterval(-48 * 3600)
        }
    }

    private nonisolated static func logDate(_ line: String) -> Date? {
        let stamp: String
        if line.first == "[", let end = line.firstIndex(of: "]") {
            stamp = String(line.dropFirst()[..<end])
        } else if line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let time = record["time"] as? String {
            stamp = time
        } else {
            return nil
        }
        return (try? Date(stamp, strategy: .iso8601)) ??
            (try? Date(stamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    private nonisolated static func collectMacCrashReports(rangeKind: String) -> [ReportClientCrashPayload] {
        let diagDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diagDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = rangeStart(rangeKind, until: Date())

        let candidates: [(url: URL, mtime: Date)] = urls.compactMap { url in
            let name = url.lastPathComponent
            let lower = name.lowercased()
            guard lower.hasPrefix("sarto"),
                  (lower.hasSuffix(".ips") || lower.hasSuffix(".crash"))
            else { return nil }
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = vals.contentModificationDate,
                  mtime >= cutoff
            else { return nil }
            return (url, mtime)
        }
        .sorted { $0.mtime > $1.mtime }
        .prefix(5)
        .map { $0 }

        var results: [ReportClientCrashPayload] = []
        for item in candidates {
            guard let data = try? Data(contentsOf: item.url), !data.isEmpty else { continue }
            let clipped = data.count > 400_000 ? data.prefix(400_000) : data
            let text = String(decoding: clipped, as: UTF8.self)
            results.append(ReportClientCrashPayload(name: item.url.lastPathComponent, content: text))
        }
        return results
    }
}

import Foundation
import SartoProtocol
import Observation
import SwiftUI
#if os(macOS)
import AppKit
import WebKit
#endif

// MARK: - Browser State Models (faithful Swift mirror of src/shared/browser.ts & src/shared/control.ts)

public enum PrismBrowserControlState: Equatable, Sendable {
    case idle
    case agent(acting: Bool)
    case you(since: Date)
    case asks(PrismBrowserControlAsk)

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    public var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

public struct PrismBrowserControlAsk: Equatable, Sendable {
    public let id: Int
    public let step: String // "sign_in" | "code" | "check" | "other"
    public let target: String?
    public let reason: String

    public init(id: Int, step: String, target: String?, reason: String) {
        self.id = id
        self.step = step
        self.target = target
        self.reason = reason
    }
}

public struct PrismBrowserOriginRequest: Equatable, Sendable, Identifiable {
    public let id: Int
    public let sessionId: String
    public let origin: String
    public let projectPath: String

    public init(id: Int, sessionId: String, origin: String, projectPath: String) {
        self.id = id
        self.sessionId = sessionId
        self.origin = origin
        self.projectPath = projectPath
    }
}

public enum PrismBrowserNotice: Equatable, Sendable {
    case downloadBlocked
    case loadFailed(String)
    case crashed
}

public struct PrismBrowserConsoleEntry: Sendable, Equatable {
    public let level: String
    public let text: String
    public let url: String
    public let line: Int
    public let nav: Int
}

public struct PrismBrowserNetworkEntry: Sendable, Equatable {
    public let method: String
    public let url: String
    public let status: Int?
    public let type: String
    public let size: Int?
    public let nav: Int
}

public enum PrismBrowserTabOpener: String, Sendable, Equatable {
    case agent
    case user
}

@MainActor
@Observable
public final class PrismBrowserTab: Identifiable {
    public let id: String
    public let opener: PrismBrowserTabOpener
    public var agentAllowed: Bool
    public var url: String
    public var title: String
    public var isLoading: Bool = false
    public var estimatedProgress: Double = 0
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    public var navGeneration: Int = 1
    public var viewport: BrowserPageSize? = nil
    public var agentUsed: Bool = false

    @ObservationIgnored var consoleMessages: [PrismBrowserConsoleEntry] = []
    @ObservationIgnored var networkRequests: [PrismBrowserNetworkEntry] = []
    @ObservationIgnored var pendingDialogs: [String] = []
    @ObservationIgnored var lastLoadError: String? = nil

    #if os(macOS)
    @ObservationIgnored public let webView: WKWebView
    @ObservationIgnored var navigationContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored var bridgeHandler: PrismWebViewBridge?
    #endif

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let site = BrowserPolicy.siteOf(url), !site.isEmpty { return site }
        if url == "about:blank" || url.isEmpty { return "New Tab" }
        return url
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        opener: PrismBrowserTabOpener,
        initialURL: String = "about:blank"
    ) {
        self.id = id
        self.opener = opener
        self.agentAllowed = (opener == .agent)
        self.agentUsed = (opener == .agent)
        self.viewport = (opener == .agent) ? .desktop : nil
        self.url = initialURL
        self.title = ""

        #if os(macOS)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        let ucc = WKUserContentController()
        let script = WKUserScript(
            source: PrismBrowserScripts.bootstrap,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(script)
        config.userContentController = ucc

        let initialWidth = (opener == .agent) ? BrowserPageSize.desktop.width : 960
        let initialHeight = (opener == .agent) ? BrowserPageSize.desktop.height : 720
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight), configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv
        #endif
    }

    func appendConsole(_ entry: PrismBrowserConsoleEntry) {
        consoleMessages.append(entry)
        if consoleMessages.count > BrowserPolicy.maxConsoleMessages {
            consoleMessages.removeFirst(consoleMessages.count - BrowserPolicy.maxConsoleMessages)
        }
    }

    func appendNetwork(_ entry: PrismBrowserNetworkEntry) {
        networkRequests.append(entry)
        if networkRequests.count > BrowserPolicy.maxNetworkRequests {
            networkRequests.removeFirst(networkRequests.count - BrowserPolicy.maxNetworkRequests)
        }
    }

    #if os(macOS)
    func resolveNavigations(error: Error? = nil) {
        let waiters = Array(navigationContinuations.values)
        navigationContinuations.removeAll()
        for cont in waiters {
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }

    func tearDown() {
        resolveNavigations(error: BrowserToolError(code: "no_page", message: "The tab closed."))
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "prismBrowser")
        webView.stopLoading()
        bridgeHandler = nil
    }
    #endif
}

@MainActor
@Observable
public final class PrismBrowserSessionState {
    public let sessionId: String
    public var tabs: [PrismBrowserTab] = []
    public var selectedTabID: String? = nil
    public var agentTabID: String? = nil
    public var control: PrismBrowserControlState = .idle
    public var originRequest: PrismBrowserOriginRequest? = nil
    public var notice: PrismBrowserNotice? = nil
    public var unseenActivity: Bool = false
    public var heldClickPulseToken: Int = 0

    @ObservationIgnored var sessionAllowedOrigins: Set<String> = []
    @ObservationIgnored var actingCount: Int = 0
    @ObservationIgnored var controlWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored var askWaiters: [UUID: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored var answeredAskOutcome: String? = nil

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    public var selectedTab: PrismBrowserTab? {
        if let id = selectedTabID, let hit = tabs.first(where: { $0.id == id }) {
            return hit
        }
        return tabs.first
    }

    public var agentTab: PrismBrowserTab? {
        if let id = agentTabID, let hit = tabs.first(where: { $0.id == id }) {
            return hit
        }
        return nil
    }

    public var isAgentControllingSelectedTab: Bool {
        control.isAgent && selectedTabID != nil && selectedTabID == agentTabID
    }
}

// MARK: - WKWebView Delegate Bridge (macOS)

#if os(macOS)
@MainActor
final class PrismWebViewBridge: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var controller: PrismBrowserController?
    weak var tab: PrismBrowserTab?
    let sessionId: String

    init(controller: PrismBrowserController, tab: PrismBrowserTab, sessionId: String) {
        self.controller = controller
        self.tab = tab
        self.sessionId = sessionId
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab,
              let dict = message.body as? [String: Any],
              let kind = dict["kind"] as? String
        else { return }

        if kind == "console" {
            let level = (dict["level"] as? String) ?? "log"
            let text = (dict["text"] as? String) ?? ""
            let url = (dict["url"] as? String) ?? tab.url
            let line = (dict["line"] as? Int) ?? 1
            tab.appendConsole(PrismBrowserConsoleEntry(
                level: level,
                text: text,
                url: url,
                line: line,
                nav: tab.navGeneration
            ))
        } else if kind == "network" {
            let method = ((dict["method"] as? String) ?? "GET").uppercased()
            let url = (dict["url"] as? String) ?? ""
            let status = dict["status"] as? Int
            let type = (dict["type"] as? String) ?? "other"
            let size = dict["size"] as? Int
            tab.appendNetwork(PrismBrowserNetworkEntry(
                method: method,
                url: url,
                status: status,
                type: type,
                size: size,
                nav: tab.navGeneration
            ))
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let raw = url.absoluteString
        if navigationAction.targetFrame?.isMainFrame != false {
            if !BrowserPolicy.isAllowedNavigation(raw) {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.shouldPerformDownload {
                controller?.reportNotice(sessionId: sessionId, notice: .downloadBlocked)
                decisionHandler(.cancel)
                return
            }
        } else if BrowserPolicy.isNeverOpened(url) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType {
            controller?.reportNotice(sessionId: sessionId, notice: .downloadBlocked)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab else { return }
        tab.isLoading = true
        tab.estimatedProgress = max(0.12, webView.estimatedProgress)
        tab.lastLoadError = nil
        if let url = webView.url?.absoluteString, !url.isEmpty {
            tab.url = url
        }
        controller?.clearNotice(sessionId: sessionId)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab else { return }
        tab.navGeneration &+= 1
        syncMetadata(from: webView, to: tab)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab else { return }
        tab.isLoading = false
        tab.estimatedProgress = 1.0
        syncMetadata(from: webView, to: tab)
        tab.resolveNavigations(error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(webView: webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(webView: webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        tab.isLoading = false
        controller?.reportNotice(sessionId: sessionId, notice: .crashed)
        tab.resolveNavigations(error: BrowserToolError(
            code: "no_page",
            message: "The page crashed. Reload it with browser_reload, or open another with browser_navigate."
        ))
    }

    // Target=_blank links open in-place rather than popping stray native windows
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, BrowserPolicy.isAllowedNavigation(url.absoluteString) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // Non-blocking JS dialogs
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        tab?.pendingDialogs.append("An alert dialog was accepted.")
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        tab?.pendingDialogs.append("A confirm dialog was dismissed.")
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        tab?.pendingDialogs.append("A prompt dialog was dismissed.")
        completionHandler(nil)
    }

    private func handleLoadFailure(webView: WKWebView, error: Error) {
        guard let tab else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            tab.isLoading = false
            syncMetadata(from: webView, to: tab)
            tab.resolveNavigations(error: nil)
            return
        }
        tab.isLoading = false
        tab.estimatedProgress = 0
        syncMetadata(from: webView, to: tab)
        let desc = nsError.localizedDescription
        tab.lastLoadError = desc
        controller?.reportNotice(sessionId: sessionId, notice: .loadFailed(desc))
        tab.resolveNavigations(error: BrowserToolError(
            code: "navigation_failed",
            message: "Could not load page: \(desc)"
        ))
    }

    private func syncMetadata(from webView: WKWebView, to tab: PrismBrowserTab) {
        if let url = webView.url?.absoluteString, !url.isEmpty {
            tab.url = url
        }
        tab.title = webView.title ?? ""
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
        tab.estimatedProgress = webView.estimatedProgress
    }
}
#endif

// MARK: - Main Browser Controller (Manages per-session tabs, policy, control & all 17 MCP tools)

@MainActor
@Observable
public final class PrismBrowserController {
    private static let projectOriginsDefaultsKey = "dev.sarto.browser.projectAllowedOrigins"
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    public private(set) var sessions: [String: PrismBrowserSessionState] = [:]

    @ObservationIgnored private var nextOriginRequestID: Int = 1
    @ObservationIgnored private var nextAskID: Int = 1
    @ObservationIgnored private var pendingOriginWaiters: [Int: (sessionId: String, origin: String, projectPath: String, continuation: CheckedContinuation<String, Never>)] = [:]
    @ObservationIgnored private var projectAllowedOrigins: [String: Set<String>] = [:]

    // Host RPC callbacks wired by SartoState
    @ObservationIgnored public var onWaitingChanged: ((Int, Bool) -> Void)?
    @ObservationIgnored public var onOriginRequested: ((String, Int, String) -> Void)?
    @ObservationIgnored public var onOriginSettled: ((Int, String) -> Void)?
    @ObservationIgnored public var onHandedBack: ((String, Int) -> Void)?
    @ObservationIgnored public var onAgentOpenedBrowser: ((String) -> Void)?
    @ObservationIgnored public var onProjectAllowedOriginsChanged: (() -> Void)?

    public init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.projectOriginsDefaultsKey) as? [String: [String]] {
            var map: [String: Set<String>] = [:]
            for (k, v) in saved { map[k] = Set(v) }
            self.projectAllowedOrigins = map
        }
    }

    /// Exports allowed origins per project with the user's home directory normalized to `~`
    /// so entries stay portable across Macs with different usernames.
    public func exportedProjectAllowedOrigins() -> [String: [String]] {
        let home = NSHomeDirectory()
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        var out: [String: [String]] = [:]
        for (rawPath, origins) in projectAllowedOrigins where !origins.isEmpty {
            let portablePath: String
            if rawPath == home {
                portablePath = "~"
            } else if rawPath.hasPrefix(homePrefix) {
                portablePath = "~/" + String(rawPath.dropFirst(homePrefix.count))
            } else {
                portablePath = rawPath
            }
            out[portablePath] = Array(origins).sorted()
        }
        return out
    }

    /// Applies synced project allowed origins without triggering `onProjectAllowedOriginsChanged`.
    public func applySyncedProjectAllowedOrigins(_ synced: [String: [String]]) {
        let home = NSHomeDirectory()
        var next: [String: Set<String>] = [:]
        for (portablePath, origins) in synced where !origins.isEmpty {
            let expanded: String
            if portablePath == "~" {
                expanded = home
            } else if portablePath.hasPrefix("~/") {
                expanded = (home as NSString).appendingPathComponent(String(portablePath.dropFirst(2)))
            } else {
                expanded = portablePath
            }
            next[expanded] = Set(origins)
        }
        guard next != projectAllowedOrigins else { return }
        projectAllowedOrigins = next
        persistProjectOrigins(notify: false)
    }

    /// Applies a per-project patch of synced allowed origins without clobbering unrelated projects
    /// or triggering `onProjectAllowedOriginsChanged`. An empty array removes that project's entry.
    public func applySyncedProjectAllowedOriginsPatch(_ updates: [String: [String]]) {
        guard !updates.isEmpty else { return }
        let home = NSHomeDirectory()
        var next = projectAllowedOrigins
        for (portablePath, origins) in updates {
            let expanded: String
            if portablePath == "~" {
                expanded = home
            } else if portablePath.hasPrefix("~/") {
                expanded = (home as NSString).appendingPathComponent(String(portablePath.dropFirst(2)))
            } else {
                expanded = portablePath
            }
            if origins.isEmpty {
                next.removeValue(forKey: expanded)
            } else {
                next[expanded] = Set(origins)
            }
        }
        guard next != projectAllowedOrigins else { return }
        projectAllowedOrigins = next
        persistProjectOrigins(notify: false)
    }

    public func state(for sessionId: String) -> PrismBrowserSessionState {
        if let existing = sessions[sessionId] { return existing }
        let created = PrismBrowserSessionState(sessionId: sessionId)
        sessions[sessionId] = created
        return created
    }

    public func peekState(for sessionId: String?) -> PrismBrowserSessionState? {
        guard let sessionId else { return nil }
        return sessions[sessionId]
    }

    public func hasUnseenActivity(for sessionId: String?) -> Bool {
        guard let sessionId, let s = sessions[sessionId] else { return false }
        return s.unseenActivity || s.control.isActive || s.originRequest != nil
    }

    public func markSeen(sessionId: String?) {
        guard let sessionId, let s = sessions[sessionId] else { return }
        s.unseenActivity = false
    }

    public func removeSession(_ sessionId: String) {
        guard let s = sessions.removeValue(forKey: sessionId) else { return }
        #if os(macOS)
        for tab in s.tabs { tab.tearDown() }
        #endif
        releaseAllWaiters(in: s, error: BrowserToolError(code: "no_page", message: "The session closed."))
    }

    // MARK: - User Actions from Browser Pane UI

    @discardableResult
    public func openUserTab(sessionId: String, urlString: String? = nil) -> PrismBrowserTab {
        let s = state(for: sessionId)
        let targetURL = urlString.flatMap { BrowserPolicy.normalizeUserInputURL($0)?.absoluteString } ?? "about:blank"
        let tab = createTab(in: s, opener: .user, initialURL: targetURL)
        s.selectedTabID = tab.id
        #if os(macOS)
        if let url = URL(string: targetURL) {
            tab.webView.load(URLRequest(url: url))
        }
        #endif
        return tab
    }

    public func navigateUser(sessionId: String, rawInput: String) {
        guard let normalized = BrowserPolicy.normalizeUserInputURL(rawInput) else { return }
        let s = state(for: sessionId)
        let tab: PrismBrowserTab
        if let current = s.selectedTab {
            tab = current
        } else {
            tab = createTab(in: s, opener: .user, initialURL: normalized.absoluteString)
            s.selectedTabID = tab.id
        }
        tab.url = normalized.absoluteString
        s.notice = nil
        #if os(macOS)
        tab.webView.load(URLRequest(url: normalized))
        #endif
    }

    public func selectUserTab(sessionId: String, tabId: String) {
        let s = state(for: sessionId)
        guard s.tabs.contains(where: { $0.id == tabId }) else { return }
        s.selectedTabID = tabId
    }

    public func closeUserTab(sessionId: String, tabId: String) {
        let s = state(for: sessionId)
        guard let idx = s.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let removed = s.tabs.remove(at: idx)
        #if os(macOS)
        removed.tearDown()
        #endif
        if s.selectedTabID == tabId {
            if !s.tabs.isEmpty {
                let nextIdx = min(idx, s.tabs.count - 1)
                s.selectedTabID = s.tabs[nextIdx].id
            } else {
                s.selectedTabID = nil
            }
        }
        if s.agentTabID == tabId {
            s.agentTabID = s.tabs.first(where: { $0.opener == .agent })?.id
        }
    }

    public func goBack(sessionId: String) {
        #if os(macOS)
        state(for: sessionId).selectedTab?.webView.goBack()
        #endif
    }

    public func goForward(sessionId: String) {
        #if os(macOS)
        state(for: sessionId).selectedTab?.webView.goForward()
        #endif
    }

    public func reload(sessionId: String) {
        let s = state(for: sessionId)
        s.notice = nil
        #if os(macOS)
        if let tab = s.selectedTab {
            if tab.webView.url == nil, let url = URL(string: tab.url) {
                tab.webView.load(URLRequest(url: url))
            } else {
                tab.webView.reload()
            }
        }
        #endif
    }

    public func stopLoading(sessionId: String) {
        #if os(macOS)
        state(for: sessionId).selectedTab?.webView.stopLoading()
        #endif
    }

    public func openSelectedInSystemBrowser(sessionId: String) {
        #if os(macOS)
        guard let raw = state(for: sessionId).selectedTab?.url,
              let url = URL(string: raw),
              BrowserPolicy.isHttp(url)
        else { return }
        NSWorkspace.shared.open(url)
        #endif
    }

    public func pulseHeldClick(sessionId: String) {
        state(for: sessionId).heldClickPulseToken &+= 1
    }

    public func setUserViewport(sessionId: String, tabId: String, size: BrowserPageSize?) {
        let s = state(for: sessionId)
        guard let tab = s.tabs.first(where: { $0.id == tabId }) else { return }
        applyViewport(size, to: tab)
    }

    @discardableResult
    private func applyViewport(
        _ size: BrowserPageSize?,
        to tab: PrismBrowserTab,
        reloadIfNeeded: Bool = true
    ) -> Bool {
        let wasMobile = tab.viewport?.mobile ?? false
        let isMobile = size?.mobile ?? false
        tab.viewport = size

        #if os(macOS)
        tab.webView.customUserAgent = isMobile ? Self.mobileUserAgent : nil
        if let size, tab.webView.superview == nil {
            tab.webView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        let hasLoadedHTTP: Bool
        if let currentURL = tab.webView.url, BrowserPolicy.isHttp(currentURL) {
            hasLoadedHTTP = true
        } else {
            hasLoadedHTTP = false
        }
        let needsReload = (wasMobile != isMobile) && hasLoadedHTTP
        if needsReload && reloadIfNeeded {
            tab.webView.reload()
        }
        return needsReload
        #else
        return false
        #endif
    }

    private func markAgentUsed(_ tab: PrismBrowserTab) {
        tab.agentUsed = true
        if tab.viewport == nil {
            applyViewport(.desktop, to: tab)
        }
    }

    // MARK: - Surface Control Ownership (Take over / Hand back / Ask Done & Skip)

    public func takeOver(sessionId: String) {
        let s = state(for: sessionId)
        guard case .agent = s.control else { return }
        s.control = .you(since: Date())
    }

    public func handBack(sessionId: String) {
        let s = state(for: sessionId)
        guard case .you(let since) = s.control else { return }
        let durationMs = max(0, Int(Date().timeIntervalSince(since) * 1000))
        s.control = .agent(acting: s.actingCount > 0)
        let waiters = Array(s.controlWaiters.values)
        s.controlWaiters.removeAll()
        for cont in waiters { cont.resume() }
        onHandedBack?(sessionId, durationMs)
    }

    public func answerAskFromUI(sessionId: String, outcome: String) {
        settleAsk(sessionId: sessionId, outcome: outcome)
    }

    public func handleAskAnsweredFromHost(sessionId: String, outcome: String) {
        settleAsk(sessionId: sessionId, outcome: outcome)
    }

    public func handleTurnEnded(sessionId: String) {
        guard let s = sessions[sessionId] else { return }
        s.control = .idle
        s.actingCount = 0
        s.answeredAskOutcome = nil
        let err = BrowserToolError(code: "stopped", message: "The user stopped.")
        releaseAllWaiters(in: s, error: err)
    }

    public func answerOriginFromUI(sessionId: String, requestId: Int, decision: String) {
        settleOrigin(sessionId: sessionId, requestId: requestId, decision: decision, notifyHost: true)
    }

    public func handleOriginDecidedFromHost(sessionId: String, requestId: Int, decision: String) {
        settleOrigin(sessionId: sessionId, requestId: requestId, decision: decision, notifyHost: false)
    }

    func reportNotice(sessionId: String, notice: PrismBrowserNotice) {
        state(for: sessionId).notice = notice
    }

    func clearNotice(sessionId: String) {
        state(for: sessionId).notice = nil
    }

    // MARK: - Host Event Entry Point: All 16 MCP `browser_*` Tools

    public func handleDeviceCall(_ call: BrowserDeviceCall) async -> BrowserCallAnswer {
        #if !os(macOS)
        return .error(BrowserToolError(
            code: "unavailable",
            message: "The built-in browser is available only on macOS."
        ))
        #else
        let s = state(for: call.sessionId)
        if let allowTabID = call.allowTab,
           let tab = s.tabs.first(where: { $0.id == allowTabID }) {
            tab.agentAllowed = true
        }

        do {
            let result = try await executeCall(call, in: s)
            return .result(result)
        } catch let err as BrowserToolError {
            return .error(err)
        } catch {
            return .error(BrowserToolError(code: "invalid", message: error.localizedDescription))
        }
        #endif
    }

    #if os(macOS)
    private func executeCall(_ call: BrowserDeviceCall, in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        if call.tool == "browser_ask_user" {
            return try await runAskUser(call: call, in: s)
        }

        // Wait if the user currently holds control (Take over)
        try await beginAgentControl(call: call, in: s)
        defer { endAgentControl(in: s) }

        switch call.tool {
        case "browser_navigate":
            return try await runNavigate(call: call, in: s)
        case "browser_navigate_back":
            return try await runNavigateBack(in: s)
        case "browser_reload":
            return try await runReload(in: s)
        case "browser_snapshot":
            return try await runSnapshot(in: s)
        case "browser_click":
            return try await runClick(args: call.args, in: s)
        case "browser_type":
            return try await runType(args: call.args, in: s)
        case "browser_press_key":
            return try await runPressKey(args: call.args, in: s)
        case "browser_scroll":
            return try await runScroll(args: call.args, in: s)
        case "browser_select_option":
            return try await runSelectOption(args: call.args, in: s)
        case "browser_take_screenshot":
            return try await runScreenshot(args: call.args, in: s)
        case "browser_wait_for":
            return try await runWaitFor(call: call, in: s)
        case "browser_console_messages":
            return try runConsoleMessages(args: call.args, in: s)
        case "browser_network_requests":
            return try runNetworkRequests(args: call.args, in: s)
        case "browser_evaluate":
            return try await runEvaluate(args: call.args, in: s)
        case "browser_tabs":
            return try runTabs(args: call.args, in: s)
        case "browser_resize":
            return try await runResize(args: call.args, in: s)
        default:
            throw BrowserToolError(code: "invalid", message: "Unknown browser tool \"\(call.tool)\".")
        }
    }

    // MARK: - Tool Implementations

    private func runNavigate(call: BrowserDeviceCall, in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let rawURL = call.args["url"]?.stringValue ?? ""
        let checkedURL: String
        switch BrowserPolicy.checkAgentNavigation(rawURL) {
        case .success(let valid): checkedURL = valid
        case .failure(let err): throw err
        }

        // Enforce origin policy for non-local sites
        if let parsed = URL(string: checkedURL), !BrowserPolicy.isLocalAddress(parsed) {
            guard let origin = BrowserPolicy.originOf(checkedURL) else {
                throw BrowserToolError(code: "not_allowed", message: "That address cannot be opened in Sarto.")
            }
            if !isOriginAllowed(origin: origin, session: s, projectPath: call.projectPath) {
                s.unseenActivity = true
                onAgentOpenedBrowser?(s.sessionId)
                let decision = await requestOriginApproval(
                    callId: call.callId,
                    session: s,
                    origin: origin,
                    projectPath: call.projectPath
                )
                guard decision == "session" || decision == "project" else {
                    throw BrowserToolError(
                        code: "not_allowed",
                        message: "The user did not allow opening \(origin) in Sarto's browser."
                    )
                }
            }
        }

        let tab = try ensureUsableAgentTab(in: s, createIfNeeded: true)
        s.selectedTabID = tab.id
        s.unseenActivity = true
        onAgentOpenedBrowser?(s.sessionId)

        guard let targetURL = URL(string: checkedURL) else {
            throw BrowserToolError(code: "invalid", message: "\"\(checkedURL)\" is not a valid URL.")
        }

        tab.url = checkedURL
        s.notice = nil
        try await loadAndWait(tab: tab, url: targetURL)
        try await settleBrief(tab: tab)

        let snap = try await captureSnapshot(tab: tab)
        let dialogs = tab.pendingDialogs.drain()
        let titleSuffix = snap.title.isEmpty ? "" : ", \"\(snap.title)\""
        let summary = (["Opened \(snap.url)\(titleSuffix)."] + dialogs).joined(separator: " ")
        return BrowserCallResult(
            text: summary,
            value: [
                "url": .string(snap.url),
                "title": snap.title.isEmpty ? .null : .string(snap.title),
                "snapshot": .string(snap.outline),
            ]
        )
    }

    private func runNavigateBack(in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        guard tab.webView.canGoBack else {
            throw BrowserToolError(code: "navigation_failed", message: "There is no previous page to go back to.")
        }
        try await waitForNavigation(tab: tab) {
            tab.webView.goBack()
        }
        try await settleBrief(tab: tab)
        return try await afterActionResult(tab: tab, message: "Went back one page.")
    }

    private func runReload(in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        try await waitForNavigation(tab: tab) {
            if tab.webView.url == nil, let url = URL(string: tab.url) {
                tab.webView.load(URLRequest(url: url))
            } else {
                tab.webView.reload()
            }
        }
        try await settleBrief(tab: tab)
        return try await afterActionResult(tab: tab, message: "Reloaded the page.")
    }

    private func runSnapshot(in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let snap = try await captureSnapshot(tab: tab)
        let titleSuffix = snap.title.isEmpty ? "" : ", \"\(snap.title)\""
        return BrowserCallResult(
            text: "Snapshotted the page at \(snap.url)\(titleSuffix).",
            value: [
                "url": .string(snap.url),
                "title": snap.title.isEmpty ? .null : .string(snap.title),
                "snapshot": .string(snap.outline),
            ]
        )
    }

    private func runClick(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let ref = args["ref"]?.stringValue ?? ""
        let doubleClick = args["double"]?.boolValue ?? false
        let button = args["button"]?.stringValue ?? "left"
        let desc = describeElement(args: args)

        let res = try await callBridgeJSON(
            tab: tab,
            expression: "window.__prismBrowser && window.__prismBrowser.click(\(jsLiteral(ref)), \(tab.navGeneration), \(jsLiteral(button)), \(doubleClick ? "true" : "false"), \(jsLiteral(desc)))"
        )
        try checkBridgeError(res)
        try await settleBrief(tab: tab)
        return try await afterActionResult(tab: tab, message: "Clicked \(desc)\(doubleClick ? " twice" : "").")
    }

    private func runType(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let ref = args["ref"]?.stringValue ?? ""
        let text = args["text"]?.stringValue ?? ""
        let slowly = args["slowly"]?.boolValue ?? false
        let submit = args["submit"]?.boolValue ?? false
        let desc = describeElement(args: args)

        let res = try await callBridgeJSON(
            tab: tab,
            expression: "window.__prismBrowser && window.__prismBrowser.type(\(jsLiteral(ref)), \(tab.navGeneration), \(jsLiteral(text)), \(slowly ? "true" : "false"), \(submit ? "true" : "false"), \(jsLiteral(desc)))"
        )
        try checkBridgeError(res)
        try await settleBrief(tab: tab)
        let preview = text.count > 60 ? "\(text.prefix(60))…" : text
        return try await afterActionResult(
            tab: tab,
            message: "Typed \(jsLiteral(preview)) into \(desc)\(submit ? " and pressed Enter" : "")."
        )
    }

    private func runPressKey(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let rawKey = args["key"]?.stringValue ?? ""
        let stroke: BrowserKeyStroke
        switch BrowserPolicy.parseKey(rawKey) {
        case .success(let parsed): stroke = parsed
        case .failure(let err): throw err
        }

        let strokeObj: [String: Any] = [
            "key": stroke.key,
            "code": stroke.code,
            "keyCode": stroke.keyCode,
            "text": stroke.text ?? NSNull(),
            "altKey": stroke.altKey,
            "ctrlKey": stroke.ctrlKey,
            "metaKey": stroke.metaKey,
            "shiftKey": stroke.shiftKey,
        ]
        let strokeJSON = jsonEncodeAny(strokeObj)
        let res = try await callBridgeJSON(
            tab: tab,
            expression: "window.__prismBrowser && window.__prismBrowser.pressKey(\(strokeJSON))"
        )
        try checkBridgeError(res)
        try await settleBrief(tab: tab)
        return try await afterActionResult(tab: tab, message: "Pressed \(rawKey).")
    }

    private func runScroll(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let direction = args["direction"]?.stringValue ?? ""
        let amount = args["amount"]?.doubleValue ?? 1.0
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw BrowserToolError(code: "invalid", message: "direction must be up, down, left or right.")
        }
        guard amount.isFinite && amount > 0 && amount <= 50 else {
            throw BrowserToolError(code: "invalid", message: "amount must be a number of screens from 0 to 50.")
        }
        let refJS = args["ref"]?.stringValue.map(jsLiteral) ?? "null"
        let res = try await callBridgeJSON(
            tab: tab,
            expression: "window.__prismBrowser && window.__prismBrowser.scroll(\(refJS), \(tab.navGeneration), \(jsLiteral(direction)), \(amount))"
        )
        try checkBridgeError(res)
        try await settleBrief(tab: tab)
        return try await afterActionResult(tab: tab, message: "Scrolled \(direction) \(amount) screen(s).")
    }

    private func runSelectOption(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let ref = args["ref"]?.stringValue ?? ""
        let values = (args["values"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !values.isEmpty else {
            throw BrowserToolError(code: "invalid", message: "values must list at least one option.")
        }
        let desc = describeElement(args: args)
        let valuesJSON = jsonEncodeAny(values)
        let res = try await callBridgeJSON(
            tab: tab,
            expression: "window.__prismBrowser && window.__prismBrowser.selectOption(\(jsLiteral(ref)), \(tab.navGeneration), \(valuesJSON), \(jsLiteral(desc)))"
        )
        try checkBridgeError(res)
        try await settleBrief(tab: tab)
        let listed = values.map(jsLiteral).joined(separator: ", ")
        return try await afterActionResult(tab: tab, message: "Selected \(listed) in \(desc).")
    }

    private func runScreenshot(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let fullPage = args["full_page"]?.boolValue ?? false
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        var what = "the page"

        if let ref = args["ref"]?.stringValue {
            let res = try await callBridgeJSON(
                tab: tab,
                expression: "window.__prismBrowser && window.__prismBrowser.elementRect(\(jsLiteral(ref)), \(tab.navGeneration))"
            )
            try checkBridgeError(res)
            guard let x = res["x"] as? Double,
                  let y = res["y"] as? Double,
                  let w = res["width"] as? Double,
                  let h = res["height"] as? Double,
                  w > 0, h > 0
            else {
                throw BrowserToolError(code: "invalid", message: "That element has no box to capture.")
            }
            config.rect = CGRect(x: max(0, x), y: max(0, y), width: w, height: h)
            what = describeElement(args: args)
        } else if fullPage {
            let metrics = try await callBridgeJSON(
                tab: tab,
                expression: "({ width: Math.max(document.documentElement.scrollWidth, window.innerWidth), height: Math.min(\(BrowserPolicy.maxPageHeight), Math.max(document.documentElement.scrollHeight, window.innerHeight)) })"
            )
            if let w = metrics["width"] as? Double, let h = metrics["height"] as? Double, w > 0, h > 0 {
                config.rect = CGRect(x: 0, y: 0, width: w, height: h)
            }
            what = "the whole page"
        }

        // Ensure webView has a valid non-zero frame before taking snapshot
        if tab.webView.bounds.width < 10 || tab.webView.bounds.height < 10 {
            let w = CGFloat(tab.viewport?.width ?? BrowserPageSize.desktop.width)
            let h = CGFloat(tab.viewport?.height ?? BrowserPageSize.desktop.height)
            tab.webView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        }

        let image = try await takeSnapshot(webView: tab.webView, config: config)
        guard let pngBase64 = encodeCappedPNG(image: image, maxSide: CGFloat(BrowserPolicy.maxShotSide)) else {
            throw BrowserToolError(code: "invalid", message: "Could not encode page screenshot.")
        }

        let url = tab.webView.url?.absoluteString ?? tab.url
        let title = tab.webView.title ?? tab.title
        return BrowserCallResult(
            text: "Took a screenshot of \(what) at \(url.isEmpty ? "about:blank" : url).",
            value: [
                "url": .string(url),
                "title": title.isEmpty ? .null : .string(title),
            ],
            image: pngBase64
        )
    }

    private func runWaitFor(call: BrowserDeviceCall, in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let text = call.args["text"]?.stringValue
        let gone = call.args["text_gone"]?.stringValue
        let seconds = call.args["time"]?.doubleValue
        if text == nil && gone == nil && seconds == nil {
            throw BrowserToolError(code: "invalid", message: "Give text, text_gone or time to wait for.")
        }
        if let seconds, (!seconds.isFinite || seconds < 0 || seconds > 30) {
            throw BrowserToolError(code: "invalid", message: "time must be 0 to 30 seconds.")
        }

        let limit = seconds ?? 30.0
        let deadline = Date().addingTimeInterval(limit)

        if text != nil || gone != nil {
            var matched = false
            while true {
                try await gateAgentControl(call: call, in: s)
                let body = (try? await evalString(tab: tab, expression: "document.body ? document.body.innerText : ''")) ?? ""
                if let text {
                    matched = body.contains(text)
                } else if let gone {
                    matched = !body.contains(gone)
                }
                if matched || Date() >= deadline { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !matched {
                let msg = text != nil
                    ? "\"\(text!)\" did not appear within \(Int(limit)) s."
                    : "\"\(gone!)\" was still on the page after \(Int(limit)) s."
                throw BrowserToolError(code: "timeout", message: msg)
            }
        } else {
            let until = Date().addingTimeInterval(seconds ?? 0)
            while Date() < until {
                try await gateAgentControl(call: call, in: s)
                let rem = min(0.1, max(0.01, until.timeIntervalSinceNow))
                try? await Task.sleep(for: .milliseconds(Int(rem * 1000)))
            }
        }

        let snap = try await captureSnapshot(tab: tab)
        let message: String
        if let text { message = "\"\(text)\" appeared." }
        else if let gone { message = "\"\(gone)\" left the page." }
        else { message = "Waited \(seconds ?? 0) s." }
        return BrowserCallResult(
            text: message,
            value: [
                "url": .string(snap.url),
                "title": snap.title.isEmpty ? .null : .string(snap.title),
                "snapshot": .string(snap.outline),
            ]
        )
    }

    private func runConsoleMessages(args: [String: JSONValue], in s: PrismBrowserSessionState) throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let since = args["since_navigation"]?.boolValue ?? false
        let filtered = tab.consoleMessages.filter { !since || $0.nav == tab.navGeneration }
        let items: [JSONValue] = filtered.map { msg in
            .object([
                "level": .string(msg.level),
                "text": .string(msg.text),
                "url": .string(msg.url),
                "line": .number(Double(msg.line)),
            ])
        }
        let text = items.isEmpty
            ? "No console messages."
            : "\(items.count) console message\(items.count == 1 ? "" : "s"), oldest first."
        return BrowserCallResult(text: text, value: ["messages": .array(items)])
    }

    private func runNetworkRequests(args: [String: JSONValue], in s: PrismBrowserSessionState) throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let since = args["since_navigation"]?.boolValue ?? false
        let filtered = tab.networkRequests.filter { !since || $0.nav == tab.navGeneration }
        let items: [JSONValue] = filtered.map { req in
            .object([
                "method": .string(req.method),
                "url": .string(req.url),
                "status": req.status.map { .number(Double($0)) } ?? .null,
                "type": .string(req.type),
                "size": req.size.map { .number(Double($0)) } ?? .null,
            ])
        }
        let text = items.isEmpty
            ? "No network requests."
            : "\(items.count) network request\(items.count == 1 ? "" : "s"), oldest first."
        return BrowserCallResult(text: text, value: ["requests": .array(items)])
    }

    private func runEvaluate(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let source = args["function"]?.stringValue ?? ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserToolError(code: "invalid", message: "function must be JavaScript.")
        }
        let refJS = args["ref"]?.stringValue.map(jsLiteral) ?? "null"
        let res = try await callAsyncBridgeJSON(
            tab: tab,
            body: """
            if (!window.__prismBrowser) return { error: { code: 'invalid', message: 'Browser bridge not ready.' } };
            return await window.__prismBrowser.evaluate(fnSource, ref, navId);
            """,
            arguments: [
                "fnSource": source,
                "ref": args["ref"]?.stringValue ?? NSNull(),
                "navId": tab.navGeneration,
            ]
        )
        _ = refJS
        try checkBridgeError(res)
        var json = (res["json"] as? String) ?? "null"
        if json.utf8.count > BrowserPolicy.maxEvaluateBytes {
            json = Self.truncateUTF8Prefix(json, maxBytes: BrowserPolicy.maxEvaluateBytes) + "\n… the value was longer than 64 KB"
        }
        let url = tab.webView.url?.absoluteString ?? tab.url
        return BrowserCallResult(
            text: "Ran the function on \(url.isEmpty ? "about:blank" : url).",
            value: ["value": .string(json)]
        )
    }

    private func runTabs(args: [String: JSONValue], in s: PrismBrowserSessionState) throws -> BrowserCallResult {
        let action = args["action"]?.stringValue ?? ""
        switch action {
        case "list":
            return tabListResult(in: s, message: tabListSummary(in: s))

        case "new":
            guard s.tabs.count < BrowserPolicy.maxSessionTabs else {
                throw BrowserToolError(code: "invalid", message: "Maximum of \(BrowserPolicy.maxSessionTabs) tabs reached.")
            }
            let tab = createTab(in: s, opener: .agent, initialURL: "about:blank")
            s.agentTabID = tab.id
            s.selectedTabID = tab.id
            s.unseenActivity = true
            onAgentOpenedBrowser?(s.sessionId)
            return tabListResult(in: s, message: "Opened a new tab at index \(s.tabs.count - 1).")

        case "select":
            guard let idxDouble = args["index"]?.doubleValue else {
                throw BrowserToolError(code: "invalid", message: "index is required for select.")
            }
            let idx = Int(idxDouble)
            guard idx >= 0 && idx < s.tabs.count else {
                throw BrowserToolError(code: "invalid", message: "Tab index \(idx) is out of range.")
            }
            let target = s.tabs[idx]
            if target.opener == .user && !target.agentAllowed {
                throw BrowserToolError(
                    code: "needs_allow",
                    message: "This tab was opened by the user and needs their permission.",
                    tab: BrowserToolErrorTab(id: target.id, title: target.displayTitle)
                )
            }
            s.agentTabID = target.id
            s.selectedTabID = target.id
            markAgentUsed(target)
            return tabListResult(in: s, message: "Switched to tab \(idx).")

        case "close":
            let targetIdx: Int
            if let idxDouble = args["index"]?.doubleValue {
                let idx = Int(idxDouble)
                guard idx >= 0 && idx < s.tabs.count else {
                    throw BrowserToolError(code: "invalid", message: "Tab index \(idx) is out of range.")
                }
                targetIdx = idx
            } else if let aid = s.agentTabID, let idx = s.tabs.firstIndex(where: { $0.id == aid }) {
                targetIdx = idx
            } else {
                throw BrowserToolError(code: "no_page", message: "There is no tab to close.")
            }
            let target = s.tabs[targetIdx]
            if target.opener == .user && !target.agentAllowed {
                throw BrowserToolError(
                    code: "needs_allow",
                    message: "This tab was opened by the user and needs their permission.",
                    tab: BrowserToolErrorTab(id: target.id, title: target.displayTitle)
                )
            }
            closeUserTab(sessionId: s.sessionId, tabId: target.id)
            return tabListResult(in: s, message: "Closed tab \(targetIdx).")

        default:
            throw BrowserToolError(code: "invalid", message: "Unknown tabs action \"\(action)\".")
        }
    }

    private func runResize(args: [String: JSONValue], in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let size: BrowserPageSize
        switch BrowserPageSize.parse(args: args) {
        case .success(let parsed): size = parsed
        case .failure(let err): throw err
        }

        let tab = try requireUsableAgentTab(in: s)
        let needsReload = applyViewport(size, to: tab, reloadIfNeeded: false)
        if needsReload {
            try await waitForNavigation(tab: tab) {
                tab.webView.reload()
            }
        }
        try await settleBrief(tab: tab)

        let detail = size.mobile ? "\(size.name.rawValue), mobile" : size.name.rawValue
        let message = "Resized to \(size.width)x\(size.height) (\(detail))."
        let after = try await afterActionResult(tab: tab, message: message)
        var value = after.value
        value["size"] = .string(size.name.rawValue)
        value["width"] = .number(Double(size.width))
        value["height"] = .number(Double(size.height))
        value["mobile"] = .bool(size.mobile)
        return BrowserCallResult(text: after.text, value: value)
    }

    private func runAskUser(call: BrowserDeviceCall, in s: PrismBrowserSessionState) async throws -> BrowserCallResult {
        let tab = try requireUsableAgentTab(in: s)
        let step = call.args["step"]?.stringValue ?? "other"
        let reason = call.args["reason"]?.stringValue ?? ""
        let target = BrowserPolicy.siteOf(tab.webView.url?.absoluteString ?? tab.url)

        if let answered = s.answeredAskOutcome {
            s.answeredAskOutcome = nil
            return try await askOutcomeResult(outcome: answered, tab: tab, in: s)
        }

        if case .asks = s.control {
            // Re-entered while user is still completing the same step; keep waiting cleanly.
        } else {
            let ask = PrismBrowserControlAsk(id: nextAskID, step: step, target: target, reason: reason)
            nextAskID &+= 1
            s.control = .asks(ask)
        }
        s.unseenActivity = true
        onAgentOpenedBrowser?(s.sessionId)
        onWaitingChanged?(call.callId, true)
        defer { onWaitingChanged?(call.callId, false) }

        let outcome = try await waitForAskOutcome(in: s, timeoutSeconds: BrowserPolicy.controlWaitSeconds)
        return try await askOutcomeResult(outcome: outcome, tab: tab, in: s)
    }

    private func askOutcomeResult(
        outcome: String,
        tab: PrismBrowserTab,
        in s: PrismBrowserSessionState
    ) async throws -> BrowserCallResult {
        let url = tab.webView.url?.absoluteString ?? tab.url
        let title = tab.webView.title ?? tab.title
        if outcome == "skipped" {
            return BrowserCallResult(
                text: "The user skipped this step. Go on without it, or say in your reply what you need.",
                value: [
                    "outcome": .string("skipped"),
                    "url": .string(url),
                    "title": title.isEmpty ? .null : .string(title),
                    "snapshot": .string(""),
                ]
            )
        }
        let snap = try await captureSnapshot(tab: tab)
        return BrowserCallResult(
            text: "The user did the step and pressed Done. Snapshotted the page at \(snap.url).",
            value: [
                "outcome": .string("done"),
                "url": .string(snap.url),
                "title": snap.title.isEmpty ? .null : .string(snap.title),
                "snapshot": .string(snap.outline),
            ]
        )
    }

    // MARK: - Control & Origin Approval Helpers

    private func beginAgentControl(call: BrowserDeviceCall, in s: PrismBrowserSessionState) async throws {
        s.answeredAskOutcome = nil
        if case .idle = s.control {
            s.control = .agent(acting: true)
            s.actingCount = 1
            return
        }
        if case .agent = s.control {
            s.actingCount += 1
            s.control = .agent(acting: true)
            return
        }
        try await waitForAgentControl(call: call, in: s)
        s.actingCount += 1
        s.control = .agent(acting: true)
    }

    private func gateAgentControl(call: BrowserDeviceCall, in s: PrismBrowserSessionState) async throws {
        if case .agent = s.control { return }
        if case .idle = s.control {
            throw BrowserToolError(code: "stopped", message: "The user stopped.")
        }
        try await waitForAgentControl(call: call, in: s)
    }

    private func endAgentControl(in s: PrismBrowserSessionState) {
        s.actingCount = max(0, s.actingCount - 1)
        if case .agent = s.control {
            s.control = .agent(acting: s.actingCount > 0)
        }
    }

    private func waitForAgentControl(call: BrowserDeviceCall, in s: PrismBrowserSessionState) async throws {
        onWaitingChanged?(call.callId, true)
        defer { onWaitingChanged?(call.callId, false) }

        let waiterID = UUID()
        let timeoutSec = BrowserPolicy.controlWaitSeconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                s.controlWaiters[waiterID] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSec))
                    guard let self,
                          let live = self.sessions[s.sessionId],
                          let cont = live.controlWaiters.removeValue(forKey: waiterID)
                    else { return }
                    cont.resume(throwing: BrowserToolError(
                        code: "user_has_control",
                        message: "The user still has control of the browser; call again to keep waiting."
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let cont = self?.sessions[s.sessionId]?.controlWaiters.removeValue(forKey: waiterID) {
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func waitForAskOutcome(in s: PrismBrowserSessionState, timeoutSeconds: TimeInterval) async throws -> String {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                s.askWaiters[waiterID] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard let self,
                          let live = self.sessions[s.sessionId],
                          let cont = live.askWaiters.removeValue(forKey: waiterID)
                    else { return }
                    cont.resume(throwing: BrowserToolError(
                        code: "user_has_control",
                        message: "The user is still doing the step you asked for in the browser; call browser_ask_user again to keep waiting."
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let cont = self?.sessions[s.sessionId]?.askWaiters.removeValue(forKey: waiterID) {
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    private static func truncateUTF8Prefix(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let utf8 = string.utf8
        guard utf8.count > maxBytes else { return string }
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end > utf8.startIndex && (utf8[end] & 0b1100_0000) == 0b1000_0000 {
            end = utf8.index(before: end)
        }
        return String(Substring(utf8[..<end]))
    }

    private func isOriginAllowed(origin: String, session: PrismBrowserSessionState, projectPath: String) -> Bool {
        if session.sessionAllowedOrigins.contains(origin) { return true }
        if !projectPath.isEmpty, projectAllowedOrigins[projectPath]?.contains(origin) == true { return true }
        return false
    }

    private func requestOriginApproval(
        callId: Int,
        session: PrismBrowserSessionState,
        origin: String,
        projectPath: String
    ) async -> String {
        let reqId = nextOriginRequestID
        nextOriginRequestID &+= 1
        session.originRequest = PrismBrowserOriginRequest(
            id: reqId,
            sessionId: session.sessionId,
            origin: origin,
            projectPath: projectPath
        )
        onWaitingChanged?(callId, true)
        onOriginRequested?(session.sessionId, reqId, origin)

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            pendingOriginWaiters[reqId] = (
                sessionId: session.sessionId,
                origin: origin,
                projectPath: projectPath,
                continuation: continuation
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(BrowserPolicy.originWaitSeconds))
                self?.settleOrigin(sessionId: session.sessionId, requestId: reqId, decision: "timeout", notifyHost: true)
            }
        }

        onWaitingChanged?(callId, false)
        return decision
    }

    // MARK: - Tab & WebView Low-Level Helpers

    private func requireUsableAgentTab(in s: PrismBrowserSessionState) throws -> PrismBrowserTab {
        try ensureUsableAgentTab(in: s, createIfNeeded: false)
    }

    private func ensureUsableAgentTab(
        in s: PrismBrowserSessionState,
        createIfNeeded: Bool
    ) throws -> PrismBrowserTab {
        if let tab = s.agentTab {
            if tab.opener == .user && !tab.agentAllowed {
                throw BrowserToolError(
                    code: "needs_allow",
                    message: "This tab was opened by the user and needs their permission.",
                    tab: BrowserToolErrorTab(id: tab.id, title: tab.displayTitle)
                )
            }
            markAgentUsed(tab)
            return tab
        }
        if !createIfNeeded {
            if let userTab = s.selectedTab, userTab.opener == .user && !userTab.agentAllowed {
                throw BrowserToolError(
                    code: "needs_allow",
                    message: "This tab was opened by the user and needs their permission.",
                    tab: BrowserToolErrorTab(id: userTab.id, title: userTab.displayTitle)
                )
            }
            if let allowed = s.selectedTab, allowed.agentAllowed {
                s.agentTabID = allowed.id
                markAgentUsed(allowed)
                return allowed
            }
            throw BrowserToolError(
                code: "no_page",
                message: "This session has no page yet. Use browser_navigate to open one."
            )
        }
        let created = createTab(in: s, opener: .agent, initialURL: "about:blank")
        s.agentTabID = created.id
        markAgentUsed(created)
        return created
    }

    private func loadAndWait(tab: PrismBrowserTab, url: URL) async throws {
        if url.absoluteString == "about:blank" {
            tab.webView.loadHTMLString("<!doctype html><html><head><title></title></head><body></body></html>", baseURL: nil)
            try? await Task.sleep(for: .milliseconds(80))
            tab.url = "about:blank"
            tab.title = ""
            return
        }
        try await waitForNavigation(tab: tab) {
            tab.webView.load(URLRequest(url: url))
        }
    }

    private func waitForNavigation(tab: PrismBrowserTab, start: () -> Void) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                tab.navigationContinuations[waiterID] = continuation
                start()
                Task { @MainActor [weak tab] in
                    try? await Task.sleep(for: .seconds(25))
                    guard let cont = tab?.navigationContinuations.removeValue(forKey: waiterID) else { return }
                    cont.resume(throwing: BrowserToolError(
                        code: "timeout",
                        message: "The page did not finish loading within 25 s."
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak tab] in
                if let cont = tab?.navigationContinuations.removeValue(forKey: waiterID) {
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func settleBrief(tab: PrismBrowserTab) async throws {
        // Give SPA frameworks a brief settle window after load/click/type
        let deadline = Date().addingTimeInterval(0.35)
        while tab.isLoading && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func afterActionResult(tab: PrismBrowserTab, message: String) async throws -> BrowserCallResult {
        let snap = try await captureSnapshot(tab: tab)
        let dialogs = tab.pendingDialogs.drain()
        return BrowserCallResult(
            text: ([message] + dialogs).joined(separator: " "),
            value: [
                "url": .string(snap.url),
                "title": snap.title.isEmpty ? .null : .string(snap.title),
                "snapshot": .string(snap.outline),
            ]
        )
    }

    private func captureSnapshot(tab: PrismBrowserTab) async throws -> (url: String, title: String, outline: String) {
        let res = try await callBridgeJSON(
            tab: tab,
            expression: "window.__prismBrowser ? window.__prismBrowser.snapshot(\(tab.navGeneration), \(BrowserPolicy.maxSnapshotLines)) : null"
        )
        let url = tab.webView.url?.absoluteString ?? tab.url
        let title = tab.webView.title ?? tab.title
        let outline = (res["outline"] as? String)
            ?? "- Page: \(title.isEmpty ? "Untitled" : title) (\(url.isEmpty ? "about:blank" : url))"
        tab.url = url
        tab.title = title
        return (url: url.isEmpty ? "about:blank" : url, title: title, outline: outline)
    }

    private func callBridgeJSON(tab: PrismBrowserTab, expression: String) async throws -> [String: Any] {
        let result = try await tab.webView.evaluateJavaScript(expression)
        if let dict = result as? [String: Any] {
            return dict
        }
        return [:]
    }

    private func callAsyncBridgeJSON(
        tab: PrismBrowserTab,
        body: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let result = try await tab.webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            contentWorld: .page
        )
        if let dict = result as? [String: Any] {
            return dict
        }
        return [:]
    }

    private func evalString(tab: PrismBrowserTab, expression: String) async throws -> String {
        let result = try await tab.webView.evaluateJavaScript(expression)
        return (result as? String) ?? ""
    }

    private func checkBridgeError(_ dict: [String: Any]) throws {
        if let err = dict["error"] as? [String: Any] {
            let code = (err["code"] as? String) ?? "invalid"
            let message = (err["message"] as? String) ?? "The browser action failed."
            throw BrowserToolError(code: code, message: message)
        }
    }

    private func tabListSummary(in s: PrismBrowserSessionState) -> String {
        if s.tabs.isEmpty { return "No tabs open." }
        return "\(s.tabs.count) tab\(s.tabs.count == 1 ? "" : "s") open."
    }

    private func tabListResult(in s: PrismBrowserSessionState, message: String) -> BrowserCallResult {
        let list: [JSONValue] = s.tabs.enumerated().map { index, tab in
            .object([
                "index": .number(Double(index)),
                "url": .string(tab.url),
                "title": .string(tab.title),
                "current": .bool(tab.id == s.agentTabID),
                "released": .bool(false),
                "yours": .bool(tab.opener == .agent),
                "usable": .bool(tab.agentAllowed),
            ])
        }
        return BrowserCallResult(text: message, value: ["tabs": .array(list)])
    }

    private func takeSnapshot(webView: WKWebView, config: WKSnapshotConfiguration) async throws -> NSImage {
        struct SnapshotBox: @unchecked Sendable {
            let image: NSImage
        }
        let box: SnapshotBox = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let image {
                    cont.resume(returning: SnapshotBox(image: image))
                } else {
                    cont.resume(throwing: BrowserToolError(code: "invalid", message: "Empty screenshot image."))
                }
            }
        }
        return box.image
    }

    private func encodeCappedPNG(image: NSImage, maxSide: CGFloat) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }
        let longest = max(w, h)
        let finalCG: CGImage
        if longest > maxSide {
            let scale = maxSide / longest
            let nw = max(1, Int((w * scale).rounded()))
            let nh = max(1, Int((h * scale).rounded()))
            guard let ctx = CGContext(
                data: nil,
                width: nw,
                height: nh,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            guard let scaled = ctx.makeImage() else { return nil }
            finalCG = scaled
        } else {
            finalCG = cgImage
        }
        let rep = NSBitmapImageRep(cgImage: finalCG)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }
    #endif

    // MARK: - Shared Private Helpers

    private func createTab(
        in s: PrismBrowserSessionState,
        opener: PrismBrowserTabOpener,
        initialURL: String
    ) -> PrismBrowserTab {
        let tab = PrismBrowserTab(opener: opener, initialURL: initialURL)
        #if os(macOS)
        let bridge = PrismWebViewBridge(controller: self, tab: tab, sessionId: s.sessionId)
        tab.bridgeHandler = bridge
        tab.webView.navigationDelegate = bridge
        tab.webView.uiDelegate = bridge
        tab.webView.configuration.userContentController.add(bridge, name: "prismBrowser")
        #endif
        s.tabs.append(tab)
        return tab
    }

    private func settleAsk(sessionId: String, outcome: String) {
        let s = state(for: sessionId)
        let normalized = (outcome == "done") ? "done" : "skipped"
        if case .asks = s.control {
            s.control = .agent(acting: s.actingCount > 0)
        }
        if s.askWaiters.isEmpty {
            s.answeredAskOutcome = normalized
        } else {
            let waiters = Array(s.askWaiters.values)
            s.askWaiters.removeAll()
            for cont in waiters { cont.resume(returning: normalized) }
        }
    }

    private func settleOrigin(sessionId: String, requestId: Int, decision: String, notifyHost: Bool) {
        guard let entry = pendingOriginWaiters.removeValue(forKey: requestId) else { return }
        if let s = sessions[sessionId] {
            if s.originRequest?.id == requestId {
                s.originRequest = nil
            }
            if decision == "session" {
                s.sessionAllowedOrigins.insert(entry.origin)
            } else if decision == "project" {
                s.sessionAllowedOrigins.insert(entry.origin)
                if !entry.projectPath.isEmpty {
                    projectAllowedOrigins[entry.projectPath, default: []].insert(entry.origin)
                    persistProjectOrigins()
                }
            }
        }
        if notifyHost {
            onOriginSettled?(requestId, decision)
        }
        entry.continuation.resume(returning: decision)
    }

    private func releaseAllWaiters(in s: PrismBrowserSessionState, error: Error) {
        let control = Array(s.controlWaiters.values)
        s.controlWaiters.removeAll()
        for cont in control { cont.resume(throwing: error) }

        let asks = Array(s.askWaiters.values)
        s.askWaiters.removeAll()
        for cont in asks { cont.resume(throwing: error) }

        for (reqId, entry) in pendingOriginWaiters where entry.sessionId == s.sessionId {
            pendingOriginWaiters.removeValue(forKey: reqId)
            entry.continuation.resume(returning: "deny")
        }
        s.originRequest = nil
    }

    private func persistProjectOrigins(notify: Bool = true) {
        var raw: [String: [String]] = [:]
        for (k, v) in projectAllowedOrigins {
            raw[k] = Array(v).sorted()
        }
        UserDefaults.standard.set(raw, forKey: Self.projectOriginsDefaultsKey)
        if notify {
            onProjectAllowedOriginsChanged?()
        }
    }

    private func describeElement(args: [String: JSONValue]) -> String {
        if let el = args["element"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !el.isEmpty {
            return "\"\(el)\""
        }
        if let ref = args["ref"]?.stringValue, !ref.isEmpty {
            return "ref \(ref)"
        }
        return "the element"
    }

    private func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let str = String(data: data, encoding: .utf8),
              str.count >= 2
        else { return "\"\"" }
        return String(str.dropFirst().dropLast())
    }

    private func jsonEncodeAny(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let str = String(data: data, encoding: .utf8)
        else { return "null" }
        return str
    }
}

private extension Array {
    mutating func drain() -> [Element] {
        let copy = self
        removeAll()
        return copy
    }
}

// MARK: - Injected WKUserScript Automation Bridge (DOM Accessibility Outline, Actions, Console & Network)

#if os(macOS)
private enum PrismBrowserScripts {
    static let bootstrap = #"""
    (function () {
      if (window.__prismBrowser) return;

      const post = (payload) => {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.prismBrowser) {
            window.webkit.messageHandlers.prismBrowser.postMessage(payload);
          }
        } catch (_) {}
      };

      const stringifyArg = (v) => {
        if (typeof v === 'string') return v;
        if (v instanceof Error) return v.stack || v.message || String(v);
        try { return JSON.stringify(v); } catch (_) { return String(v); }
      };

      // 1. Console interception
      const levels = [['log','log'], ['info','info'], ['warn','warn'], ['error','error'], ['debug','debug']];
      for (const [fn, level] of levels) {
        const orig = console[fn];
        if (typeof orig !== 'function') continue;
        console[fn] = function (...args) {
          post({ kind: 'console', level, text: args.map(stringifyArg).join(' '), url: location.href, line: 1 });
          return orig.apply(this, args);
        };
      }
      window.addEventListener('error', (ev) => {
        post({
          kind: 'console',
          level: 'error',
          text: ev.message || 'Uncaught error',
          url: ev.filename || location.href,
          line: ev.lineno || 1,
        });
      });
      window.addEventListener('unhandledrejection', (ev) => {
        post({
          kind: 'console',
          level: 'error',
          text: 'Unhandled rejection: ' + stringifyArg(ev.reason),
          url: location.href,
          line: 1,
        });
      });

      // 2. Network interception (fetch, XHR, PerformanceObserver — metadata only, no headers/bodies)
      if (typeof window.fetch === 'function') {
        const origFetch = window.fetch.bind(window);
        window.fetch = function (input, init) {
          const method = (init && init.method) || (input && input.method) || 'GET';
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          return origFetch(input, init).then(
            (res) => {
              const len = res.headers && res.headers.get ? parseInt(res.headers.get('content-length') || '', 10) : NaN;
              post({
                kind: 'network',
                method: String(method).toUpperCase(),
                url: String(res.url || url),
                status: res.status || null,
                type: 'fetch',
                size: Number.isFinite(len) ? len : null,
              });
              return res;
            },
            (err) => {
              post({
                kind: 'network',
                method: String(method).toUpperCase(),
                url: String(url),
                status: null,
                type: 'fetch',
                size: null,
              });
              throw err;
            }
          );
        };
      }
      if (typeof XMLHttpRequest !== 'undefined') {
        const origOpen = XMLHttpRequest.prototype.open;
        const origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
          this.__prismMethod = String(method || 'GET').toUpperCase();
          this.__prismUrl = String(url || '');
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
          const self = this;
          const finish = () => {
            post({
              kind: 'network',
              method: self.__prismMethod || 'GET',
              url: self.responseURL || self.__prismUrl || '',
              status: self.status || null,
              type: 'xhr',
              size: typeof self.responseText === 'string' ? self.responseText.length : null,
            });
          };
          this.addEventListener('loadend', finish, { once: true });
          return origSend.apply(this, arguments);
        };
      }
      try {
        if (typeof PerformanceObserver !== 'undefined') {
          const po = new PerformanceObserver((list) => {
            for (const entry of list.getEntries()) {
              if (entry.initiatorType === 'fetch' || entry.initiatorType === 'xmlhttprequest') continue;
              post({
                kind: 'network',
                method: 'GET',
                url: String(entry.name || ''),
                status: entry.responseStatus || null,
                type: String(entry.initiatorType || 'resource'),
                size: typeof entry.encodedBodySize === 'number' ? Math.round(entry.encodedBodySize) : null,
              });
            }
          });
          po.observe({ type: 'resource', buffered: true });
        }
      } catch (_) {}

      // 3. Accessibility-tree style DOM snapshot & ref registry
      const refs = new Map();
      let refNav = 0;

      const ACTIONABLE = new Set([
        'link', 'button', 'textbox', 'searchbox', 'combobox', 'listbox',
        'checkbox', 'radio', 'switch', 'slider', 'spinbutton', 'tab',
        'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem',
      ]);
      const CONTAINERS = new Set([
        'banner', 'main', 'navigation', 'region', 'form', 'list', 'menu', 'menubar',
        'tablist', 'tree', 'row', 'rowgroup', 'table', 'listbox', 'combobox', 'grid',
        'group', 'toolbar', 'dialog', 'alertdialog', 'iframe',
      ]);

      const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim();
      const quote = (s) => '"' + clean(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

      const isVisible = (el) => {
        if (!el || el.nodeType !== 1) return false;
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
        const style = window.getComputedStyle(el);
        if (!style || style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) {
          return false;
        }
        return true;
      };

      const roleOf = (el) => {
        const explicit = clean(el.getAttribute('role') || '').toLowerCase().split(' ')[0];
        if (explicit && explicit !== 'presentation' && explicit !== 'none') return explicit;
        const tag = el.tagName.toLowerCase();
        if (tag === 'a' && el.hasAttribute('href')) return 'link';
        if (tag === 'button' || tag === 'summary') return 'button';
        if (tag === 'select') return el.multiple ? 'listbox' : 'combobox';
        if (tag === 'option') return 'option';
        if (tag === 'textarea') return 'textbox';
        if (tag === 'input') {
          const t = (el.getAttribute('type') || 'text').toLowerCase();
          if (t === 'hidden') return 'none';
          if (t === 'checkbox') return 'checkbox';
          if (t === 'radio') return 'radio';
          if (t === 'range') return 'slider';
          if (t === 'number') return 'spinbutton';
          if (t === 'search') return 'searchbox';
          if (t === 'button' || t === 'submit' || t === 'reset') return 'button';
          return 'textbox';
        }
        if (/^h[1-6]$/.test(tag)) return 'heading';
        if (tag === 'nav') return 'navigation';
        if (tag === 'main') return 'main';
        if (tag === 'header') return 'banner';
        if (tag === 'form') return 'form';
        if (tag === 'ul' || tag === 'ol') return 'list';
        if (tag === 'li') return 'listitem';
        if (tag === 'table') return 'table';
        if (tag === 'tr') return 'row';
        if (tag === 'dialog') return 'dialog';
        if (tag === 'img') return 'image';
        if (tag === 'iframe') return 'iframe';
        if (el.isContentEditable) return 'textbox';
        if (typeof el.onclick === 'function' || el.getAttribute('tabindex') === '0') return 'button';
        return 'generic';
      };

      const labelOf = (el, role) => {
        const ariaLabel = clean(el.getAttribute('aria-label') || '');
        if (ariaLabel) return ariaLabel;
        const labelledBy = clean(el.getAttribute('aria-labelledby') || '');
        if (labelledBy) {
          const text = labelledBy.split(/\s+/).map((id) => {
            const target = document.getElementById(id);
            return target ? clean(target.innerText || target.textContent) : '';
          }).filter(Boolean).join(' ');
          if (text) return text;
        }
        if (el.id) {
          const lbl = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (lbl) {
            const t = clean(lbl.innerText || lbl.textContent);
            if (t) return t;
          }
        }
        const tag = el.tagName.toLowerCase();
        if (tag === 'img') return clean(el.getAttribute('alt') || '');
        if (tag === 'input' || tag === 'textarea' || tag === 'select') {
          if (role === 'button') return clean(el.value || el.getAttribute('title') || '');
          return clean(el.getAttribute('placeholder') || el.getAttribute('name') || el.getAttribute('title') || '');
        }
        if (role === 'heading' || ACTIONABLE.has(role) || role === 'listitem') {
          return clean(el.innerText || el.textContent || '').slice(0, 140);
        }
        return clean(el.getAttribute('title') || '');
      };

      const resolveElement = (ref, navId) => {
        if (!/^e\d+$/.test(String(ref || ''))) {
          return { error: { code: 'invalid', message: '"' + ref + '" is not a ref such as e12.' } };
        }
        const el = refs.get(ref);
        if (!el || refNav !== navId || !el.isConnected) {
          return { error: { code: 'stale_ref', message: 'Ref ' + ref + ' is no longer on the page. Take a new snapshot.' } };
        }
        return { el };
      };

      window.__prismBrowser = {
        snapshot(navId, maxLines) {
          refs.clear();
          refNav = navId;
          const lines = [];
          const cap = maxLines || 2000;
          const walk = (node, depth) => {
            if (!node || node.nodeType !== 1) return;
            const tag = node.tagName.toLowerCase();
            if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'template') return;
            if (!isVisible(node)) return;

            const role = roleOf(node);
            if (role === 'none') return;

            const childElements = [];
            if (node.shadowRoot) {
              for (const c of node.shadowRoot.children) childElements.push(c);
            }
            for (const c of node.children) childElements.push(c);
            if (tag === 'iframe') {
              try {
                if (node.contentDocument && node.contentDocument.body) {
                  childElements.push(node.contentDocument.body);
                }
              } catch (_) {}
            }

            const actionable = ACTIONABLE.has(role);
            const name = labelOf(node, role);
            const isLeafText = role === 'generic' && childElements.length === 0;
            const ownText = isLeafText ? clean(node.textContent || '').slice(0, 160) : '';

            const emit = actionable || CONTAINERS.has(role) || role === 'heading' || role === 'image' || role === 'listitem' || (isLeafText && ownText !== '');

            if (!emit) {
              for (const child of childElements) walk(child, depth);
              return;
            }

            const displayRole = isLeafText ? 'text' : role;
            const displayName = isLeafText ? ownText : name;
            let line = '  '.repeat(Math.min(depth, 16)) + '- ' + displayRole;
            if (displayName) line += ' ' + quote(displayName);

            if (role === 'heading') {
              const lvl = /^h([1-6])$/.exec(tag);
              if (lvl) line += ' [level=' + lvl[1] + ']';
            }
            if (node.checked === true || node.getAttribute('aria-checked') === 'true') line += ' [checked]';
            if (node.getAttribute('aria-expanded') === 'true') line += ' [expanded]';
            if (node.selected === true || node.getAttribute('aria-selected') === 'true') line += ' [selected]';
            if (node.disabled === true || node.getAttribute('aria-disabled') === 'true') line += ' [disabled]';

            if (role === 'textbox' || role === 'searchbox' || role === 'combobox') {
              const val = typeof node.value === 'string' ? node.value : (node.isContentEditable ? clean(node.innerText || '') : '');
              if (val) line += ' [value=' + quote(val.slice(0, 80)) + ']';
            }

            if (actionable) {
              const ref = 'e' + (refs.size + 1);
              refs.set(ref, node);
              line += ' [ref=' + ref + ']';
            }
            if (CONTAINERS.has(role) && childElements.length > 0) line += ':';
            lines.push(line);

            // Don't double-walk text inside leaf actionable controls like simple links/buttons
            const skipChildren = (role === 'button' || role === 'link' || role === 'heading')
              && !childElements.some((c) => ACTIONABLE.has(roleOf(c)) || CONTAINERS.has(roleOf(c)));
            if (!skipChildren) {
              for (const child of childElements) walk(child, depth + 1);
            }
          };

          if (document.body) {
            for (const c of document.body.children) walk(c, 0);
          }

          const more = Math.max(0, lines.length - cap);
          const trimmed = more > 0 ? lines.slice(0, cap) : lines;
          const head = '- Page: ' + (clean(document.title) || 'Untitled') + ' (' + (location.href || 'about:blank') + ')';
          const all = [head, ...trimmed];
          if (more > 0) all.push('… ' + more + ' more lines');
          return { outline: all.join('\n'), refCount: refs.size };
        },

        click(ref, navId, button, doubleClick, desc) {
          const found = resolveElement(ref, navId);
          if (found.error) return found;
          const el = found.el;
          try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          const rect = el.getBoundingClientRect();
          if (rect.width <= 0 || rect.height <= 0) {
            return { error: { code: 'invalid', message: desc + ' is not visible on the page. Scroll it into view, then click again.' } };
          }
          const cx = rect.left + rect.width / 2;
          const cy = rect.top + rect.height / 2;
          const at = document.elementFromPoint(cx, cy);
          if (at && at !== el && !el.contains(at) && !at.contains(el)) {
            const name = at.tagName ? at.tagName.toLowerCase() : 'element';
            const id = at.id ? '#' + at.id : '';
            const txt = clean(at.innerText || at.textContent || '').slice(0, 60);
            const cov = txt ? name + id + ' "' + txt + '"' : name + id;
            return { error: { code: 'invalid', message: 'The centre of ' + desc + ' is covered by ' + cov + '. Scroll it or close what covers it, then click again.' } };
          }
          const btnIdx = button === 'right' ? 2 : (button === 'middle' ? 1 : 0);
          const init = { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy, button: btnIdx };
          el.dispatchEvent(new PointerEvent('pointerover', init));
          el.dispatchEvent(new MouseEvent('mouseenter', init));
          el.dispatchEvent(new PointerEvent('pointerdown', init));
          el.dispatchEvent(new MouseEvent('mousedown', init));
          if (typeof el.focus === 'function') el.focus();
          el.dispatchEvent(new PointerEvent('pointerup', init));
          el.dispatchEvent(new MouseEvent('mouseup', init));
          if (button === 'right') {
            el.dispatchEvent(new MouseEvent('contextmenu', init));
          } else {
            if (typeof el.click === 'function') el.click();
            else el.dispatchEvent(new MouseEvent('click', init));
            if (doubleClick) {
              el.dispatchEvent(new MouseEvent('dblclick', { ...init, detail: 2 }));
            }
          }
          return { ok: true };
        },

        type(ref, navId, text, slowly, submit, desc) {
          const found = resolveElement(ref, navId);
          if (found.error) return found;
          const el = found.el;
          try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          if (typeof el.focus === 'function') el.focus();
          const setNativeValue = (node, val) => {
            const proto = node.tagName === 'TEXTAREA'
              ? window.HTMLTextAreaElement.prototype
              : window.HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            if (setter) setter.call(node, val);
            else node.value = val;
          };
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
            if (slowly) {
              setNativeValue(el, '');
              el.dispatchEvent(new Event('input', { bubbles: true }));
              let acc = '';
              for (const ch of text) {
                el.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true, cancelable: true }));
                acc += ch;
                setNativeValue(el, acc);
                el.dispatchEvent(new InputEvent('input', { data: ch, inputType: 'insertText', bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true }));
              }
            } else {
              setNativeValue(el, text);
              el.dispatchEvent(new InputEvent('input', { data: text, inputType: 'insertText', bubbles: true }));
            }
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else if (el.isContentEditable) {
            el.textContent = text;
            el.dispatchEvent(new InputEvent('input', { data: text, inputType: 'insertText', bubbles: true }));
          } else {
            return { error: { code: 'invalid', message: desc + ' is not an editable field.' } };
          }
          if (submit) {
            const evInit = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
            el.dispatchEvent(new KeyboardEvent('keydown', evInit));
            el.dispatchEvent(new KeyboardEvent('keypress', evInit));
            el.dispatchEvent(new KeyboardEvent('keyup', evInit));
            if (el.form) {
              if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
              else el.form.submit();
            }
          }
          return { ok: true };
        },

        pressKey(stroke) {
          const el = document.activeElement || document.body || document.documentElement;
          const init = {
            key: stroke.key,
            code: stroke.code,
            keyCode: stroke.keyCode,
            which: stroke.keyCode,
            altKey: !!stroke.altKey,
            ctrlKey: !!stroke.ctrlKey,
            metaKey: !!stroke.metaKey,
            shiftKey: !!stroke.shiftKey,
            bubbles: true,
            cancelable: true,
          };
          const ok = el.dispatchEvent(new KeyboardEvent('keydown', init));
          if (stroke.text) el.dispatchEvent(new KeyboardEvent('keypress', init));
          if (ok) {
            if ((stroke.ctrlKey || stroke.metaKey) && stroke.key.toLowerCase() === 'a') {
              if (typeof el.select === 'function') el.select();
              else {
                const range = document.createRange();
                range.selectNodeContents(document.body);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
              }
            } else if (stroke.key === 'Enter') {
              if (el.tagName === 'BUTTON' || el.tagName === 'A') el.click();
              else if (el.form && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
            } else if (stroke.key === 'PageDown') {
              window.scrollBy(0, window.innerHeight * 0.9);
            } else if (stroke.key === 'PageUp') {
              window.scrollBy(0, -window.innerHeight * 0.9);
            }
          }
          el.dispatchEvent(new KeyboardEvent('keyup', init));
          return { ok: true };
        },

        scroll(ref, navId, direction, amount) {
          let target = null;
          if (ref !== null) {
            const found = resolveElement(ref, navId);
            if (found.error) return found;
            target = found.el;
          }
          const w = target ? (target.clientWidth || window.innerWidth) : window.innerWidth;
          const h = target ? (target.clientHeight || window.innerHeight) : window.innerHeight;
          const dx = direction === 'left' ? -w * amount : (direction === 'right' ? w * amount : 0);
          const dy = direction === 'up' ? -h * amount : (direction === 'down' ? h * amount : 0);
          if (target) target.scrollBy({ left: dx, top: dy, behavior: 'instant' });
          else window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
          return { ok: true };
        },

        selectOption(ref, navId, wanted, desc) {
          const found = resolveElement(ref, navId);
          if (found.error) return found;
          const el = found.el;
          if (el.tagName !== 'SELECT') {
            return { error: { code: 'invalid', message: desc + ': not a select element' } };
          }
          const options = Array.from(el.options);
          const chosen = options.filter((o) => wanted.includes(o.value) || wanted.includes(o.label) || wanted.includes(o.text));
          if (chosen.length === 0) {
            return { error: { code: 'invalid', message: 'no option matches ' + wanted.join(', ') + '; the options are: ' + options.map((o) => o.value).join(', ') } };
          }
          if (!el.multiple) el.value = chosen[0].value;
          else for (const o of options) o.selected = chosen.includes(o);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { ok: true };
        },

        elementRect(ref, navId) {
          const found = resolveElement(ref, navId);
          if (found.error) return found;
          const el = found.el;
          try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
          const r = el.getBoundingClientRect();
          return { x: r.x, y: r.y, width: r.width, height: r.height };
        },

        async evaluate(fnSource, ref, navId) {
          let arg = undefined;
          if (ref !== null && ref !== undefined) {
            const found = resolveElement(ref, navId);
            if (found.error) return found;
            arg = found.el;
          }
          try {
            const fn = (0, eval)('(' + fnSource + ')');
            if (typeof fn !== 'function') {
              return { error: { code: 'invalid', message: 'function must evaluate to a JavaScript function.' } };
            }
            const raw = await fn(arg);
            let json;
            try { json = JSON.stringify(raw === undefined ? null : raw); } catch (_) { json = String(raw); }
            return { json: json || 'null' };
          } catch (e) {
            return { error: { code: 'invalid', message: 'The function failed: ' + (e && e.message ? e.message : String(e)) } };
          }
        },
      };
    })();
    """#
}
#endif

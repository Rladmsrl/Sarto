import SartoProtocol
import PrismDesign
import SwiftUI
#if os(macOS)
import AppKit
import WebKit
#endif

// MARK: - Native Built-in Browser Workbench Pane (Obsidian Prism Tokens)

public struct BrowserWorkbenchView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier

    @Bindable public var browser: PrismBrowserController
    public let sessionId: String?
    public let agentDisplayName: String

    @State private var addressText: String = ""
    @State private var isEditingAddress: Bool = false

    public init(
        browser: PrismBrowserController,
        sessionId: String?,
        agentDisplayName: String
    ) {
        self.browser = browser
        self.sessionId = sessionId
        self.agentDisplayName = agentDisplayName
    }

    public var body: some View {
        let sessionState = sessionId.map { browser.state(for: $0) }
        let selectedTab = sessionState?.selectedTab

        VStack(spacing: 0) {
            if let sid = sessionId, let s = sessionState {
                if !s.tabs.isEmpty {
                    tabStrip(sessionId: sid, state: s)
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                    addressBar(sessionId: sid, state: s, tab: selectedTab)
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                }

                if let req = s.originRequest {
                    originApprovalBar(sessionId: sid, request: req)
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                }

                if let notice = s.notice {
                    noticeBar(sessionId: sid, notice: notice)
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                }

                if let tab = selectedTab {
                    ZStack(alignment: .bottom) {
                        if let vp = tab.viewport {
                            fittedWebView(tab: tab, viewport: vp)
                        } else {
                            fullWebView(tab: tab)
                        }

                        // Agent-driving capture shield: clicking without taking over nudges the Take over pill
                        if s.isAgentControllingSelectedTab {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    browser.pulseHeldClick(sessionId: sid)
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 0)
                                        .strokeBorder(tokens.primary.opacity(0.65), lineWidth: 2)
                                        .allowsHitTesting(false)
                                )
                        }

                        // Floating control pill / Ask-User Done-Skip card
                        controlOverlay(sessionId: sid, state: s)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyBrowserState(sessionId: sid)
                }
            } else {
                noSessionEmptyState
            }
        }
        .background(tokens.surface1)
        .onAppear {
            browser.markSeen(sessionId: sessionId)
            syncAddressFromTab(selectedTab)
        }
        .onChange(of: sessionId) { _, next in
            browser.markSeen(sessionId: next)
            syncAddressFromTab(next.flatMap { browser.peekState(for: $0)?.selectedTab })
        }
        .onChange(of: selectedTab?.id) { _, _ in
            syncAddressFromTab(selectedTab)
        }
        .onChange(of: selectedTab?.url) { _, _ in
            if !isEditingAddress {
                syncAddressFromTab(selectedTab)
            }
        }
    }

    // MARK: - 1. Multi-Tab Strip (SurfaceTabs style)

    private func tabStrip(sessionId: String, state s: PrismBrowserSessionState) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(s.tabs) { tab in
                        let selected = tab.id == s.selectedTab?.id
                        let isAgentTab = tab.id == s.agentTabID && s.control.isActive
                        HStack(spacing: 5) {
                            if isAgentTab {
                                Circle()
                                    .fill(tokens.primary)
                                    .frame(width: 6, height: 6)
                            } else {
                                Image(systemName: tab.isLoading ? "arrow.trianglehead.2.clockwise" : "globe")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(selected ? tokens.primary : tokens.placeholder)
                            }

                            Text(tab.displayTitle)
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? tokens.foreground : tokens.secondaryForeground)
                                .lineLimit(1)
                                .frame(maxWidth: 136, alignment: .leading)

                            Button {
                                browser.closeUserTab(sessionId: sessionId, tabId: tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .frame(width: 15, height: 15)
                                    .background(Circle().fill(selected ? tokens.hoverWash : Color.clear))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 5)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(selected ? tokens.surface2 : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .strokeBorder(selected ? tokens.borderEtched : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            browser.selectUserTab(sessionId: sessionId, tabId: tab.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Button {
                browser.openUserTab(sessionId: sessionId)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.hoverWash))
            }
            .buttonStyle(.plain)
            .help(l10n.tr("browser.newTab"))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(tokens.sidebar.opacity(0.65))
    }

    // MARK: - 2. Navigation & Address Bar

    private func addressBar(
        sessionId: String,
        state s: PrismBrowserSessionState,
        tab: PrismBrowserTab?
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                navIconButton(
                    systemName: "chevron.left",
                    disabled: !(tab?.canGoBack ?? false),
                    help: l10n.tr("browser.back")
                ) {
                    browser.goBack(sessionId: sessionId)
                }

                navIconButton(
                    systemName: "chevron.right",
                    disabled: !(tab?.canGoForward ?? false),
                    help: l10n.tr("browser.forward")
                ) {
                    browser.goForward(sessionId: sessionId)
                }

                if tab?.isLoading == true {
                    navIconButton(
                        systemName: "xmark",
                        disabled: false,
                        help: l10n.tr("browser.stop")
                    ) {
                        browser.stopLoading(sessionId: sessionId)
                    }
                } else {
                    navIconButton(
                        systemName: "arrow.clockwise",
                        disabled: tab == nil,
                        help: l10n.tr("browser.reload")
                    ) {
                        browser.reload(sessionId: sessionId)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: isLocalURL(addressText) ? "bolt.horizontal.fill" : "lock.fill")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(isLocalURL(addressText) ? tokens.primary : tokens.placeholder)

                    TextField(
                        l10n.tr("browser.addressPlaceholder"),
                        text: $addressText,
                        onEditingChanged: { editing in
                            isEditingAddress = editing
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .onSubmit {
                        isEditingAddress = false
                        browser.navigateUser(sessionId: sessionId, rawInput: addressText)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2))
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder(isEditingAddress ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1)
                )

                viewportSizeMenu(sessionId: sessionId, tab: tab)

                navIconButton(
                    systemName: "arrow.up.right.square",
                    disabled: !(tab.map { BrowserPolicy.isHttp(URL(string: $0.url) ?? URL(string: "about:blank")!) } ?? false),
                    help: l10n.tr("browser.openExternal")
                ) {
                    browser.openSelectedInSystemBrowser(sessionId: sessionId)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Thin cobalt loading progress bar
            if let tab, tab.isLoading {
                GeometryReader { geo in
                    Rectangle()
                        .fill(tokens.primary)
                        .frame(width: max(24, geo.size.width * min(1, max(0.15, tab.estimatedProgress))), height: 2)
                        .animation(.easeOut(duration: 0.18), value: tab.estimatedProgress)
                }
                .frame(height: 2)
            }
        }
        .background(tokens.sidebar.opacity(0.45))
    }

    // MARK: - 3. Origin Approval Bar & Notices

    private func originApprovalBar(sessionId: String, request: PrismBrowserOriginRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                Text(l10n.tr("browser.originAsk", agentDisplayName, request.origin))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Button {
                    browser.answerOriginFromUI(sessionId: sessionId, requestId: request.id, decision: "session")
                } label: {
                    Text(l10n.tr("browser.originAllowSession"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tokens.primary))
                }
                .buttonStyle(.plain)

                if !request.projectPath.isEmpty {
                    Button {
                        browser.answerOriginFromUI(sessionId: sessionId, requestId: request.id, decision: "project")
                    } label: {
                        Text(l10n.tr("browser.originAllowProject"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(tokens.surface2))
                            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    browser.answerOriginFromUI(sessionId: sessionId, requestId: request.id, decision: "deny")
                } label: {
                    Text(l10n.tr("browser.originDeny"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tokens.hoverWash))
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.warning.opacity(0.10))
    }

    private func noticeBar(sessionId: String, notice: PrismBrowserNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(tokens.warning)

            Text(noticeText(notice))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.foreground)
                .lineLimit(2)

            Spacer()

            switch notice {
            case .downloadBlocked:
                Button {
                    browser.openSelectedInSystemBrowser(sessionId: sessionId)
                } label: {
                    Text(l10n.tr("browser.openExternal"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.primary)
                }
                .buttonStyle(.plain)

            case .loadFailed, .crashed:
                Button {
                    browser.reload(sessionId: sessionId)
                } label: {
                    Text(l10n.tr("browser.reload"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tokens.surface2.opacity(0.95))
    }

    // MARK: - 4. Agent Control Overlay Pill & Ask-User Banner

    @ViewBuilder
    private func controlOverlay(sessionId: String, state s: PrismBrowserSessionState) -> some View {
        switch s.control {
        case .idle:
            EmptyView()

        case .agent(let acting):
            if s.selectedTabID == s.agentTabID {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tokens.primary)
                        .frame(width: 7, height: 7)

                    Text(acting
                         ? l10n.tr("browser.control.acting", agentDisplayName)
                         : l10n.tr("browser.control.using", agentDisplayName))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.foreground)

                    Button {
                        browser.takeOver(sessionId: sessionId)
                    } label: {
                        Text(l10n.tr("browser.control.takeOver"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(tokens.primary))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(tokens.surface2.opacity(0.95))
                        .shadow(color: Color.black.opacity(0.28), radius: 12, y: 4)
                )
                .overlay(Capsule().strokeBorder(tokens.primaryBorder, lineWidth: 1))
                .scaleEffect(s.heldClickPulseToken > 0 ? 1.0 : 1.0)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        case .you:
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.warning)

                Text(l10n.tr("browser.control.youHold"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.foreground)

                Button {
                    browser.handBack(sessionId: sessionId)
                } label: {
                    Text(l10n.tr("browser.control.handBack"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tokens.primary))
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(tokens.surface2.opacity(0.95))
                    .shadow(color: Color.black.opacity(0.28), radius: 12, y: 4)
            )
            .overlay(Capsule().strokeBorder(tokens.warning.opacity(0.5), lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))

        case .asks(let ask):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.primary)
                    Text(l10n.tr("browser.ask.title", agentDisplayName))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Spacer()
                }
                if !ask.reason.isEmpty {
                    Text(ask.reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        browser.answerAskFromUI(sessionId: sessionId, outcome: "done")
                    } label: {
                        Text(l10n.tr("browser.ask.done"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(tokens.primary))
                    }
                    .buttonStyle(.plain)

                    Button {
                        browser.answerAskFromUI(sessionId: sessionId, outcome: "skipped")
                    } label: {
                        Text(l10n.tr("browser.ask.skip"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(tokens.hoverWash))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .padding(12)
            .frame(maxWidth: 380)
            .background(
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .fill(tokens.surface2.opacity(0.97))
                    .shadow(color: Color.black.opacity(0.32), radius: 16, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .strokeBorder(tokens.primaryBorder, lineWidth: 1)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 5. Empty States

    private func emptyBrowserState(sessionId: String) -> some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .fill(tokens.surface2)
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                            .strokeBorder(tokens.borderEtched, lineWidth: 1)
                    )
                Image(systemName: "globe")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tokens.primary)
            }

            VStack(spacing: 4) {
                Text(l10n.tr("browser.empty.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("browser.empty.hint", agentDisplayName))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 290)
            }

            HStack(spacing: 6) {
                TextField(l10n.tr("browser.addressPlaceholder"), text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .onSubmit {
                        browser.navigateUser(sessionId: sessionId, rawInput: addressText)
                    }

                Button {
                    browser.navigateUser(sessionId: sessionId, rawInput: addressText)
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(tokens.primary))
                }
                .buttonStyle(.plain)
                .disabled(BrowserPolicy.normalizeUserInputURL(addressText) == nil)
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 34)
            .frame(maxWidth: 320)
            .background(Capsule().fill(tokens.surface2))
            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))

            HStack(spacing: 6) {
                ForEach(["localhost:3000", "localhost:5173", "localhost:8080"], id: \.self) { host in
                    Button {
                        addressText = "http://\(host)"
                        browser.navigateUser(sessionId: sessionId, rawInput: "http://\(host)")
                    } label: {
                        Text(host)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.secondaryForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(tokens.hoverWash))
                            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSessionEmptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 24))
                .foregroundStyle(tokens.mutedForeground)
            Text(l10n.tr("browser.empty.noSession"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Text(l10n.tr("browser.empty.noSessionHint"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fullWebView(tab: PrismBrowserTab) -> some View {
        #if os(macOS)
        PrismWKWebViewHost(webView: tab.webView)
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        nonMacWebViewPlaceholder(tab: tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private func fittedWebView(tab: PrismBrowserTab, viewport vp: BrowserPageSize) -> some View {
        GeometryReader { geo in
            let availableW = max(1.0, Double(geo.size.width))
            let room = max(1.0, Double(geo.size.height) - BrowserPageSize.sizeLineRoom)
            let scale = min(1.0, availableW / Double(vp.width), room / Double(vp.height))
            let displayW = CGFloat(Double(vp.width) * scale)
            let displayH = CGFloat(Double(vp.height) * scale)
            let percent = Int((scale * 100.0).rounded())

            VStack(spacing: 0) {
                ZStack {
                    #if os(macOS)
                    PrismWKWebViewHost(webView: tab.webView)
                        .id(tab.id)
                        .frame(width: CGFloat(vp.width), height: CGFloat(vp.height))
                        .scaleEffect(scale, anchor: .center)
                    #else
                    nonMacWebViewPlaceholder(tab: tab)
                    #endif
                }
                .frame(width: displayW, height: displayH)
                .clipped()
                .overlay(
                    Rectangle()
                        .strokeBorder(tokens.borderEtched, lineWidth: 1)
                        .allowsHitTesting(false)
                )

                HStack(spacing: 6) {
                    Text("\(vp.width) × \(vp.height)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(tokens.mutedForeground)

                    if percent < 100 {
                        Text("\(percent)%")
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(tokens.placeholder)
                    }

                    if vp.mobile {
                        Text(l10n.tr("browser.size.mobileTag"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primary.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(tokens.primaryBorder, lineWidth: 1))
                    }
                }
                .frame(height: CGFloat(BrowserPageSize.sizeLineRoom))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(tokens.sidebar.opacity(0.35))
    }

    #if !os(macOS)
    private func nonMacWebViewPlaceholder(tab: PrismBrowserTab) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 26))
                .foregroundStyle(tokens.mutedForeground)
            Text(tab.url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tokens.secondaryForeground)
        }
    }
    #endif

    private func viewportSizeMenu(sessionId: String, tab: PrismBrowserTab?) -> some View {
        let current = tab?.viewport
        return Menu {
            if let tab {
                Button {
                    browser.setUserViewport(sessionId: sessionId, tabId: tab.id, size: nil)
                } label: {
                    viewportMenuItemLabel(l10n.tr("browser.size.fit"), selected: current == nil)
                }

                Divider()

                Button {
                    browser.setUserViewport(sessionId: sessionId, tabId: tab.id, size: .desktop)
                } label: {
                    viewportMenuItemLabel(
                        "\(l10n.tr("browser.size.desktop"))  \(BrowserPageSize.desktop.width)×\(BrowserPageSize.desktop.height)",
                        selected: current == .desktop
                    )
                }

                Button {
                    browser.setUserViewport(sessionId: sessionId, tabId: tab.id, size: .tablet)
                } label: {
                    viewportMenuItemLabel(
                        "\(l10n.tr("browser.size.tablet"))  \(BrowserPageSize.tablet.width)×\(BrowserPageSize.tablet.height)",
                        selected: current == .tablet
                    )
                }

                Button {
                    browser.setUserViewport(sessionId: sessionId, tabId: tab.id, size: .phone)
                } label: {
                    viewportMenuItemLabel(
                        "\(l10n.tr("browser.size.phone"))  \(BrowserPageSize.phone.width)×\(BrowserPageSize.phone.height)",
                        selected: current == .phone
                    )
                }

                if let vp = current, vp.name == .custom {
                    Divider()
                    Button {} label: {
                        viewportMenuItemLabel(
                            "\(l10n.tr("browser.size.custom"))  \(vp.width)×\(vp.height)",
                            selected: true
                        )
                    }
                    .disabled(true)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewportIconName(for: current))
                    .font(.system(size: 10.5, weight: .medium))
                Text(viewportButtonLabel(for: current))
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .foregroundStyle(current != nil ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(current != nil ? tokens.surface2 : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .strokeBorder(current != nil ? tokens.borderEtched : Color.clear, lineWidth: 1)
            )
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(tab == nil)
        .help(viewportTooltip(for: current))
    }

    @ViewBuilder
    private func viewportMenuItemLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func viewportIconName(for viewport: BrowserPageSize?) -> String {
        guard let viewport else { return "aspectratio" }
        switch viewport.name {
        case .desktop: return "desktopcomputer"
        case .tablet: return "ipad"
        case .phone: return "iphone"
        case .custom: return "aspectratio"
        }
    }

    private func viewportButtonLabel(for viewport: BrowserPageSize?) -> String {
        guard let viewport else { return l10n.tr("browser.size.fit") }
        switch viewport.name {
        case .desktop: return l10n.tr("browser.size.desktop")
        case .tablet: return l10n.tr("browser.size.tablet")
        case .phone: return l10n.tr("browser.size.phone")
        case .custom: return "\(viewport.width)×\(viewport.height)"
        }
    }

    private func viewportTooltip(for viewport: BrowserPageSize?) -> String {
        guard let viewport else { return l10n.tr("browser.size.fit") }
        let name: String
        switch viewport.name {
        case .desktop: name = l10n.tr("browser.size.desktop")
        case .tablet: name = l10n.tr("browser.size.tablet")
        case .phone: name = l10n.tr("browser.size.phone")
        case .custom: name = l10n.tr("browser.size.custom")
        }
        return "\(name) (\(viewport.width)×\(viewport.height))"
    }

    private func navIconButton(
        systemName: String,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disabled ? tokens.placeholder.opacity(0.45) : tokens.mutedForeground)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private func syncAddressFromTab(_ tab: PrismBrowserTab?) {
        let raw = tab?.url ?? ""
        addressText = (raw == "about:blank") ? "" : raw
    }

    private func isLocalURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host else { return false }
        return BrowserPolicy.isLocalHost(host)
    }

    private func noticeText(_ notice: PrismBrowserNotice) -> String {
        switch notice {
        case .downloadBlocked:
            return l10n.tr("browser.notice.downloadBlocked")
        case .loadFailed(let err):
            return l10n.tr("browser.notice.loadFailed", err)
        case .crashed:
            return l10n.tr("browser.notice.crashed")
        }
    }
}

#if os(macOS)
private struct PrismWKWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(webView, to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView {
            attach(webView, to: nsView)
        }
    }

    private func attach(_ webView: WKWebView, to container: NSView) {
        for sub in container.subviews where sub !== webView {
            sub.removeFromSuperview()
        }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
#endif

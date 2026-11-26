import Foundation
import XCTest
@testable import UsageCore

final class UsageFocusTests: XCTestCase {
  // MARK: - UsageFocusPicker: Live Sarto App Context vs File Fallback

  func testUsageFocusPickerForegroundWorkbenchOverridesNewerFileActivity() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let providers = [
      UsageFocusProviderInfo(
        id: "claude",
        hasQuota: true,
        localLastActivity: now.addingTimeInterval(-7200),
        lastActivity: now.addingTimeInterval(-7200),
        localLastModel: "claude-sonnet-4-5"
      ),
      UsageFocusProviderInfo(
        id: "codex",
        hasQuota: true,
        localLastActivity: now.addingTimeInterval(-30),
        lastActivity: now.addingTimeInterval(-30),
        localLastModel: "gpt-5.4"
      ),
    ]
    let context = AppUsageFocusContext(
      isAppForeground: true,
      hasVisibleMainWindow: true,
      workbench: AppUsageFocusCandidate(
        providerId: "claude",
        modelHints: ["claude-opus-4-7", "Opus 4.7"],
        activityAt: now.addingTimeInterval(-300),
        isWorkbenchSelection: true,
        isLiveSession: false,
        isLocalHost: true
      ),
      recentSessions: []
    )

    let pick = UsageFocusPicker.pick(visibleProviders: providers, appContext: context, now: now)
    XCTAssertEqual(pick?.providerId, "claude")
    XCTAssertEqual(pick?.modelHints, ["claude-opus-4-7", "Opus 4.7"])
    XCTAssertEqual(pick?.source, .appWorkbench)
    XCTAssertEqual(pick?.isLocalActive, true)
  }

  func testUsageFocusPickerModelSwitchDoesNotLeakStaleFileModel() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let providers = [
      UsageFocusProviderInfo(
        id: "antigravity",
        hasQuota: true,
        localLastActivity: now.addingTimeInterval(-60),
        lastActivity: now.addingTimeInterval(-60),
        localLastModel: "claude-sonnet-4-6"
      ),
    ]
    let context = AppUsageFocusContext(
      isAppForeground: true,
      hasVisibleMainWindow: true,
      workbench: AppUsageFocusCandidate(
        providerId: "antigravity",
        modelHints: ["gemini-4-neon", "Gemini 4 Neon"],
        activityAt: now,
        isWorkbenchSelection: true
      ),
      recentSessions: []
    )

    let pick = UsageFocusPicker.pick(visibleProviders: providers, appContext: context, now: now)
    XCTAssertEqual(pick?.providerId, "antigravity")
    XCTAssertEqual(pick?.modelHints, ["gemini-4-neon", "Gemini 4 Neon"])
    XCTAssertFalse(pick?.modelHints.contains { UsageModelScope.isAntigravityThirdParty($0) } ?? true)
  }

  func testUsageFocusPickerBackgroundKeepsRecentSelectionUntilNewerExternalCLI() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let providers = [
      UsageFocusProviderInfo(
        id: "claude",
        hasQuota: true,
        localLastActivity: now.addingTimeInterval(-600),
        lastActivity: now.addingTimeInterval(-600),
        localLastModel: "claude-sonnet-4-5"
      ),
      UsageFocusProviderInfo(
        id: "codex",
        hasQuota: true,
        localLastActivity: now.addingTimeInterval(-120),
        lastActivity: now.addingTimeInterval(-120),
        localLastModel: "gpt-5.4"
      ),
    ]

    // User selected Claude in Sarto 30s ago then switched to Safari: Claude stays active over 2m-old Codex.
    let recentWorkbench = AppUsageFocusContext(
      isAppForeground: false,
      hasVisibleMainWindow: true,
      workbench: AppUsageFocusCandidate(
        providerId: "claude",
        modelHints: ["claude-opus-4-7"],
        activityAt: now.addingTimeInterval(-30),
        isWorkbenchSelection: true
      ),
      recentSessions: []
    )
    let keptPick = UsageFocusPicker.pick(visibleProviders: providers, appContext: recentWorkbench, now: now)
    XCTAssertEqual(keptPick?.providerId, "claude")
    XCTAssertEqual(keptPick?.source, .appWorkbench)

    // If Sarto was untouched for 20m and Codex ran in Terminal 2m ago, external CLI takes over.
    let staleWorkbench = AppUsageFocusContext(
      isAppForeground: false,
      hasVisibleMainWindow: true,
      workbench: AppUsageFocusCandidate(
        providerId: "claude",
        modelHints: ["claude-opus-4-7"],
        activityAt: now.addingTimeInterval(-1200),
        isWorkbenchSelection: true
      ),
      recentSessions: []
    )
    let externalPick = UsageFocusPicker.pick(visibleProviders: providers, appContext: staleWorkbench, now: now)
    XCTAssertEqual(externalPick?.providerId, "codex")
    XCTAssertEqual(externalPick?.modelHints, ["gpt-5.4"])
    XCTAssertEqual(externalPick?.source, .localFile)
  }

  func testUsageFocusPickerClosedMainWindowAndLiveSessionPriority() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let providers = [
      UsageFocusProviderInfo(id: "claude", hasQuota: true),
      UsageFocusProviderInfo(id: "antigravity", hasQuota: true),
    ]

    // Main window closed (menu-bar resident): ignores hidden workbench and uses recent session.
    let closedWindow = AppUsageFocusContext(
      isAppForeground: false,
      hasVisibleMainWindow: false,
      workbench: AppUsageFocusCandidate(
        providerId: "claude",
        modelHints: ["claude-opus-4-7"],
        activityAt: now,
        isWorkbenchSelection: true
      ),
      recentSessions: [
        AppUsageFocusCandidate(
          providerId: "antigravity",
          modelHints: ["claude-sonnet-4-6"],
          activityAt: now.addingTimeInterval(-180),
          isWorkbenchSelection: false,
          isLiveSession: false
        ),
      ]
    )
    let closedPick = UsageFocusPicker.pick(visibleProviders: providers, appContext: closedWindow, now: now)
    XCTAssertEqual(closedPick?.providerId, "antigravity")
    XCTAssertEqual(closedPick?.source, .appSession)

    // Actively running Sarto session wins even while app is in background and another CLI ran earlier.
    let liveBackground = AppUsageFocusContext(
      isAppForeground: false,
      hasVisibleMainWindow: false,
      workbench: nil,
      recentSessions: [
        AppUsageFocusCandidate(
          providerId: "antigravity",
          modelHints: ["gemini-4-neon"],
          activityAt: now.addingTimeInterval(-10),
          isWorkbenchSelection: false,
          isLiveSession: true
        ),
      ]
    )
    let livePick = UsageFocusPicker.pick(
      visibleProviders: [
        UsageFocusProviderInfo(id: "claude", hasQuota: true, localLastActivity: now.addingTimeInterval(-5), lastActivity: now.addingTimeInterval(-5), localLastModel: "claude-opus-4-7"),
        UsageFocusProviderInfo(id: "antigravity", hasQuota: true),
      ],
      appContext: liveBackground,
      now: now
    )
    XCTAssertEqual(livePick?.providerId, "antigravity")
    XCTAssertEqual(livePick?.source, .appSession)
  }

  func testUsageFocusPickerRespectsHiddenUnmeasuredRemoteSyncAndPins() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // 1. Workbench provider has no quota while another visible provider does: keep quota provider.
    let mixedQuota = [
      UsageFocusProviderInfo(id: "antigravity", hasQuota: false, localLastActivity: now.addingTimeInterval(-10)),
      UsageFocusProviderInfo(id: "claude", hasQuota: true, localLastActivity: now.addingTimeInterval(-600), lastActivity: now.addingTimeInterval(-600), localLastModel: "claude-sonnet-4-5"),
    ]
    let agyWorkbench = AppUsageFocusContext(
      isAppForeground: true,
      hasVisibleMainWindow: true,
      workbench: AppUsageFocusCandidate(providerId: "antigravity", modelHints: ["gemini-4-neon"], activityAt: now, isWorkbenchSelection: true),
      recentSessions: []
    )
    let quotaPick = UsageFocusPicker.pick(visibleProviders: mixedQuota, appContext: agyWorkbench, now: now)
    XCTAssertEqual(quotaPick?.providerId, "claude")

    // 2. Stale local Sarto session (> 1h) yields to fresher remote synced Mac activity.
    let remoteSynced = [
      UsageFocusProviderInfo(id: "claude", hasQuota: true, localLastActivity: now.addingTimeInterval(-7200), lastActivity: now.addingTimeInterval(-7200)),
      UsageFocusProviderInfo(id: "codex", hasQuota: true, localLastActivity: nil, lastActivity: now.addingTimeInterval(-120), lastModel: "gpt-5.4"),
    ]
    let staleSarto = AppUsageFocusContext(
      isAppForeground: false,
      hasVisibleMainWindow: true,
      workbench: AppUsageFocusCandidate(providerId: "claude", modelHints: ["claude-sonnet-4-5"], activityAt: now.addingTimeInterval(-7200), isWorkbenchSelection: true),
      recentSessions: []
    )
    let remotePick = UsageFocusPicker.pick(visibleProviders: remoteSynced, appContext: staleSarto, now: now)
    XCTAssertEqual(remotePick?.providerId, "codex")
    XCTAssertEqual(remotePick?.source, .syncedFile)
    XCTAssertEqual(remotePick?.isLocalActive, false)

    // 3. Explicit pin wins over foreground workbench and still adopts Sarto model hints for the pinned provider.
    let pinnedPick = UsageFocusPicker.pick(
      visibleProviders: [
        UsageFocusProviderInfo(id: "claude", hasQuota: true),
        UsageFocusProviderInfo(id: "antigravity", hasQuota: true, localLastActivity: now.addingTimeInterval(-300), localLastModel: "gemini-4-neon"),
      ],
      appContext: AppUsageFocusContext(
        isAppForeground: true,
        hasVisibleMainWindow: true,
        workbench: AppUsageFocusCandidate(providerId: "claude", modelHints: ["claude-opus-4-7"], activityAt: now, isWorkbenchSelection: true),
        recentSessions: [
          AppUsageFocusCandidate(providerId: "antigravity", modelHints: ["claude-sonnet-4-6"], activityAt: now.addingTimeInterval(-30), isWorkbenchSelection: false),
        ]
      ),
      pinnedProviderId: "antigravity",
      now: now
    )
    XCTAssertEqual(pinnedPick?.providerId, "antigravity")
    XCTAssertEqual(pinnedPick?.modelHints, ["claude-sonnet-4-6"])
    XCTAssertEqual(pinnedPick?.source, .pinned)
  }
}

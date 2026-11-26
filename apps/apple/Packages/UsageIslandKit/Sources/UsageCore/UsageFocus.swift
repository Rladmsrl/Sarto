import Foundation

/// A real-time channel and model focus candidate reported by the host app (Sarto) so the
/// collapsed Dynamic Island and Usage tab follow what the user is actually working on instead
/// of relying solely on local log file timestamps.
public struct AppUsageFocusCandidate: Sendable, Equatable {
  /// Usage provider ID (`"claude"`, `"codex"`, `"antigravity"`).
  public let providerId: String
  /// Ordered model hints (canonical `modelId`, resolved `shownAs` alias, raw `value`, display
  /// name) used to match scoped quota windows. Empty when the session has no known model yet.
  public let modelHints: [String]
  /// When the user last selected this context or when the underlying session last updated.
  public let activityAt: Date
  /// True when this candidate comes from the currently displayed workbench session or composer.
  public let isWorkbenchSelection: Bool
  /// True when a session on this provider is currently running, starting, or waiting on the user.
  public let isLiveSession: Bool
  /// True when the session runs on this Mac (local daemon), false for a remote host.
  public let isLocalHost: Bool

  public init(
    providerId: String,
    modelHints: [String] = [],
    activityAt: Date,
    isWorkbenchSelection: Bool = false,
    isLiveSession: Bool = false,
    isLocalHost: Bool = true
  ) {
    self.providerId = providerId
    self.modelHints = modelHints
    self.activityAt = activityAt
    self.isWorkbenchSelection = isWorkbenchSelection
    self.isLiveSession = isLiveSession
    self.isLocalHost = isLocalHost
  }
}

/// Snapshot of the host app's live channel/model context for focus resolution.
public struct AppUsageFocusContext: Sendable, Equatable {
  /// True when the app is the active foreground application with a visible main window.
  public let isAppForeground: Bool
  /// True when the app's main workbench window is visible (even if behind another application).
  public let hasVisibleMainWindow: Bool
  /// Currently selected session or New Session composer candidate, if mapped to a usage provider.
  public let workbench: AppUsageFocusCandidate?
  /// Best session candidate per provider (live sessions first, then most recently updated).
  public let recentSessions: [AppUsageFocusCandidate]

  public init(
    isAppForeground: Bool,
    hasVisibleMainWindow: Bool,
    workbench: AppUsageFocusCandidate?,
    recentSessions: [AppUsageFocusCandidate]
  ) {
    self.isAppForeground = isAppForeground
    self.hasVisibleMainWindow = hasVisibleMainWindow
    self.workbench = workbench
    self.recentSessions = recentSessions
  }
}

/// Provider metadata needed by `UsageFocusPicker`, decoupled from SwiftUI views.
public struct UsageFocusProviderInfo: Sendable, Equatable {
  public let id: String
  public let hasQuota: Bool
  public let localLastActivity: Date?
  public let lastActivity: Date?
  public let localLastModel: String?
  public let lastModel: String?

  public init(
    id: String,
    hasQuota: Bool,
    localLastActivity: Date? = nil,
    lastActivity: Date? = nil,
    localLastModel: String? = nil,
    lastModel: String? = nil
  ) {
    self.id = id
    self.hasQuota = hasQuota
    self.localLastActivity = localLastActivity
    self.lastActivity = lastActivity
    self.localLastModel = localLastModel
    self.lastModel = lastModel
  }
}

/// Result of resolving which provider and model hints the Dynamic Island should display.
public struct UsageFocusPick: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    case pinned
    case appWorkbench
    case appSession
    case localFile
    case syncedFile
    case fallback
  }

  public let providerId: String
  public let modelHints: [String]
  public let isLocalActive: Bool
  public let source: Source

  public init(providerId: String, modelHints: [String], isLocalActive: Bool, source: Source) {
    self.providerId = providerId
    self.modelHints = modelHints
    self.isLocalActive = isLocalActive
    self.source = source
  }
}

/// Pure priority resolver combining live host-app state with file-scanned and multi-Mac synced
/// activity so the collapsed Dynamic Island tracks Sarto immediately while still picking up
/// external CLI runs when Sarto sits idle in the background.
public enum UsageFocusPicker {
  /// Window within which local activity is considered recent.
  public static let localWindow: TimeInterval = 3600
  /// Small margin so log flushes written moments after switching sessions in Sarto do not
  /// immediately steal focus back while Sarto is in the background.
  public static let externalOverrideGrace: TimeInterval = 15

  public static func pick(
    visibleProviders: [UsageFocusProviderInfo],
    appContext: AppUsageFocusContext? = nil,
    pinnedProviderId: String? = nil,
    now: Date = Date()
  ) -> UsageFocusPick? {
    guard !visibleProviders.isEmpty else { return nil }

    if let pinnedProviderId, let pinned = visibleProviders.first(where: { $0.id == pinnedProviderId }) {
      let appCandidate = matchingCandidate(for: pinned.id, in: appContext)
      let fileLocalFresh = isLocalFresh(pinned.localLastActivity, now: now)
      let hints = resolvedHints(
        for: pinned,
        appCandidate: appCandidate,
        isAppForeground: appContext?.isAppForeground ?? false,
        preferLocalFile: fileLocalFresh
      )
      let isLocal = fileLocalFresh || isCandidateLocalFresh(
        appCandidate,
        isAppForeground: appContext?.isAppForeground ?? false,
        now: now
      )
      return UsageFocusPick(
        providerId: pinned.id,
        modelHints: hints,
        isLocalActive: isLocal,
        source: .pinned
      )
    }

    let quotaVisible = visibleProviders.filter(\.hasQuota)
    let pool = quotaVisible.isEmpty ? visibleProviders : quotaVisible
    let poolById = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    let recentLocalFile = pool
      .filter { isLocalFresh($0.localLastActivity, now: now) }
      .max { ($0.localLastActivity ?? .distantPast) < ($1.localLastActivity ?? .distantPast) }

    let latestAnyFile = pool
      .filter { $0.lastActivity != nil }
      .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }

    if let app = appContext {
      let workbench = app.workbench.flatMap { poolById[$0.providerId] != nil ? $0 : nil }
      let liveSession = app.recentSessions.first { $0.isLiveSession && poolById[$0.providerId] != nil }
      let recentSession = app.recentSessions.first { poolById[$0.providerId] != nil }

      // 1. When Sarto is foreground, trust the workbench selection the user is looking at right now.
      if app.isAppForeground {
        if let workbench, let provider = poolById[workbench.providerId] {
          return makeAppPick(
            candidate: workbench,
            provider: provider,
            isAppForeground: true,
            source: .appWorkbench,
            now: now
          )
        }
        if let liveSession, let provider = poolById[liveSession.providerId] {
          return makeAppPick(
            candidate: liveSession,
            provider: provider,
            isAppForeground: true,
            source: .appSession,
            now: now
          )
        }
      }

      // 2. An actively running or awaiting-approval Sarto session takes priority even in background.
      if let liveSession, let provider = poolById[liveSession.providerId] {
        return makeAppPick(
          candidate: liveSession,
          provider: provider,
          isAppForeground: app.isAppForeground,
          source: .appSession,
          now: now
        )
      }

      // 3. Otherwise choose Sarto's freshest known context (visible workbench vs recent session).
      let sartoBest: AppUsageFocusCandidate?
      if app.hasVisibleMainWindow {
        switch (workbench, recentSession) {
        case let (w?, r?):
          sartoBest = w.activityAt >= r.activityAt ? w : r
        case let (w?, nil):
          sartoBest = w
        case let (nil, r?):
          sartoBest = r
        case (nil, nil):
          sartoBest = nil
        }
      } else {
        sartoBest = recentSession
      }

      // 4. Compare Sarto's context against external CLI files and multi-Mac synced activity.
      if let sarto = sartoBest, let sartoProvider = poolById[sarto.providerId] {
        if let file = recentLocalFile,
           let fileAt = file.localLastActivity,
           file.id != sarto.providerId,
           fileAt > sarto.activityAt.addingTimeInterval(externalOverrideGrace) {
          return makeFilePick(provider: file, isLocalActive: true, source: .localFile)
        }

        let sartoIsRecent = isLocalFresh(sarto.activityAt, now: now)
        if !sartoIsRecent {
          if let file = recentLocalFile {
            return makeFilePick(provider: file, isLocalActive: true, source: .localFile)
          }
          if let latest = latestAnyFile,
             let latestAt = latest.lastActivity,
             latestAt > sarto.activityAt {
            let isLocal = latest.localLastActivity != nil && latest.localLastActivity == latest.lastActivity
            return makeFilePick(
              provider: latest,
              isLocalActive: isLocal && isLocalFresh(latest.localLastActivity, now: now),
              source: isLocal ? .localFile : .syncedFile
            )
          }
        }

        return makeAppPick(
          candidate: sarto,
          provider: sartoProvider,
          isAppForeground: app.isAppForeground,
          source: sarto.isWorkbenchSelection ? .appWorkbench : .appSession,
          now: now
        )
      }
    }

    // 5. File-based fallback (disconnected startup, no mapped Sarto sessions, or external CLI only).
    if let local = recentLocalFile {
      return makeFilePick(provider: local, isLocalActive: true, source: .localFile)
    }
    if let latest = latestAnyFile {
      let isLocal = latest.localLastActivity != nil && latest.localLastActivity == latest.lastActivity
      return makeFilePick(
        provider: latest,
        isLocalActive: isLocal && isLocalFresh(latest.localLastActivity, now: now),
        source: isLocal ? .localFile : .syncedFile
      )
    }
    return makeFilePick(provider: pool[0], isLocalActive: false, source: .fallback)
  }

  /// Resolves the best model hints for a specific provider (used for peer rows in the Usage tab).
  public static func modelHints(
    for provider: UsageFocusProviderInfo,
    appContext: AppUsageFocusContext? = nil,
    now: Date = Date()
  ) -> [String] {
    let appCandidate = matchingCandidate(for: provider.id, in: appContext)
    return resolvedHints(
      for: provider,
      appCandidate: appCandidate,
      isAppForeground: appContext?.isAppForeground ?? false,
      preferLocalFile: isLocalFresh(provider.localLastActivity, now: now)
    )
  }

  private static func matchingCandidate(
    for providerId: String,
    in appContext: AppUsageFocusContext?
  ) -> AppUsageFocusCandidate? {
    guard let app = appContext else { return nil }
    let workbenchMatch = (app.isAppForeground || app.hasVisibleMainWindow)
      ? app.workbench.flatMap { $0.providerId == providerId ? $0 : nil }
      : nil
    let sessionMatch = app.recentSessions.first { $0.providerId == providerId }
    if app.isAppForeground, let workbenchMatch { return workbenchMatch }
    if let sessionMatch, sessionMatch.isLiveSession { return sessionMatch }
    switch (workbenchMatch, sessionMatch) {
    case let (w?, s?): return w.activityAt >= s.activityAt ? w : s
    case let (w?, nil): return w
    case let (nil, s?): return s
    case (nil, nil): return nil
    }
  }

  private static func makeAppPick(
    candidate: AppUsageFocusCandidate,
    provider: UsageFocusProviderInfo,
    isAppForeground: Bool,
    source: UsageFocusPick.Source,
    now: Date
  ) -> UsageFocusPick {
    let fileLocalFresh = isLocalFresh(provider.localLastActivity, now: now)
    let hints = resolvedHints(
      for: provider,
      appCandidate: candidate,
      isAppForeground: isAppForeground,
      preferLocalFile: fileLocalFresh
    )
    let isLocal = fileLocalFresh || isCandidateLocalFresh(
      candidate,
      isAppForeground: isAppForeground,
      now: now
    )
    return UsageFocusPick(
      providerId: provider.id,
      modelHints: hints,
      isLocalActive: isLocal,
      source: source
    )
  }

  private static func makeFilePick(
    provider: UsageFocusProviderInfo,
    isLocalActive: Bool,
    source: UsageFocusPick.Source
  ) -> UsageFocusPick {
    UsageFocusPick(
      providerId: provider.id,
      modelHints: fileModelHints(for: provider, preferLocal: isLocalActive),
      isLocalActive: isLocalActive,
      source: source
    )
  }

  private static func resolvedHints(
    for provider: UsageFocusProviderInfo,
    appCandidate: AppUsageFocusCandidate?,
    isAppForeground: Bool,
    preferLocalFile: Bool
  ) -> [String] {
    if let candidate = appCandidate {
      let externalModelNewer = !(isAppForeground && candidate.isWorkbenchSelection)
        && !candidate.isLiveSession
        && provider.localLastActivity.map { $0 > candidate.activityAt.addingTimeInterval(externalOverrideGrace) } == true
      if externalModelNewer {
        let fileHints = fileModelHints(for: provider, preferLocal: true)
        if !fileHints.isEmpty { return fileHints }
      }
      if !candidate.modelHints.isEmpty {
        return candidate.modelHints
      }
    }
    return fileModelHints(for: provider, preferLocal: preferLocalFile)
  }

  private static func fileModelHints(for provider: UsageFocusProviderInfo, preferLocal: Bool) -> [String] {
    let model = (preferLocal ? provider.localLastModel : provider.lastModel)
      ?? provider.localLastModel
      ?? provider.lastModel
    guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return []
    }
    return [trimmed]
  }

  private static func isLocalFresh(_ date: Date?, now: Date) -> Bool {
    guard let date else { return false }
    let elapsed = now.timeIntervalSince(date)
    return elapsed <= localWindow
  }

  private static func isCandidateLocalFresh(
    _ candidate: AppUsageFocusCandidate?,
    isAppForeground: Bool,
    now: Date
  ) -> Bool {
    guard let candidate, candidate.isLocalHost else { return false }
    if isAppForeground && candidate.isWorkbenchSelection { return true }
    if candidate.isLiveSession { return true }
    return isLocalFresh(candidate.activityAt, now: now)
  }
}

/// Which of an agent's model-specific quota windows a model draws on, for the window the island
/// shows beside the model it follows. The windows and their scopes come from the Sarto daemon.
public enum UsageModelScope {
  private static let fillerTokens: Set<String> = [
    "claude", "anthropic", "model", "models", "only", "weekly", "session",
  ]
  private static let efforts: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max", "none"]

  /// A model name as the matching reads it: lowercased, without a `[1m]` context tag, a trailing
  /// `/high` effort or a leading `provider/`.
  static func canonical(_ raw: String) -> String {
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
      name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
    }
    if let slash = name.lastIndex(of: "/"), efforts.contains(String(name[name.index(after: slash)...])) {
      name = String(name[..<slash])
    }
    if let slash = name.lastIndex(of: "/") {
      name = String(name[name.index(after: slash)...])
    }
    return name
  }

  /// An Antigravity model of the shared Claude/GPT pool rather than Gemini's own allowance.
  public static func isAntigravityThirdParty(_ model: String) -> Bool {
    let target = canonical(model)
    if ["claude", "gpt", "sonnet", "opus", "haiku", "fable", "mythos"].contains(where: target.contains) {
      return true
    }
    let tokens = target.split { $0 == "-" || $0 == "/" || $0 == "_" || $0 == "." || $0 == " " }
    return tokens.contains { $0 == "o1" || $0 == "o3" || $0 == "o4" }
  }

  /// Whether a Claude Code model counts against a window scoped to `scope` ("Fable", "Opus"),
  /// including short aliases such as `opus` and the `opusplan` mode.
  public static func claudeModel(_ model: String, matches scope: String) -> Bool {
    let rawScope = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !rawScope.isEmpty else { return true }
    let name = canonical(model)
    if name.contains(rawScope) { return true }

    let scopeParts = rawScope.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let distinctive = scopeParts.filter { !fillerTokens.contains($0) }
    let required = distinctive.isEmpty ? scopeParts : distinctive
    guard !required.isEmpty else { return true }

    let expanded = name == "opusplan" ? "claude-opus-sonnet" : name
    let modelParts = Set(expanded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    let modelHasDigits = expanded.contains(where: \.isNumber)
    return required.allSatisfy { token in
      // A bare alias like "opus" carries no version, so a scope's version numbers do not rule it out.
      if !modelHasDigits && token.allSatisfy(\.isNumber) { return true }
      // Numeric version tokens must match a discrete component so a date stamp like "20241022"
      // never matches version "4".
      if token.allSatisfy(\.isNumber) { return modelParts.contains(token) }
      return modelParts.contains(token) || expanded.contains(token)
    }
  }
}

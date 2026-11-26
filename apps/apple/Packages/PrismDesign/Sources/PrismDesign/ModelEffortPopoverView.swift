import SwiftUI

public enum PrismModeLook: String, Sendable, Equatable {
    case asks
    case edits
    case plan
    case auto
    case full

    public var systemImage: String {
        switch self {
        case .asks: return "shield"
        case .edits: return "pencil.line"
        case .plan: return "eye"
        case .auto: return "checkmark.shield"
        case .full: return "exclamationmark.triangle.fill"
        }
    }
}

public enum PrismEffortTier: Sendable, Equatable {
    case normal
    case high
    case max
}

public struct PrismEffortOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?
    public let tier: PrismEffortTier

    public init(
        id: String,
        label: String,
        description: String? = nil,
        tier: PrismEffortTier = .normal
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.tier = tier
    }
}

public struct PrismEffortResolved: Sendable, Equatable {
    public let optionId: String
    public let title: String
    public let levels: [PrismEffortOption]
    public let selectedID: String?

    public init(
        optionId: String,
        title: String,
        levels: [PrismEffortOption],
        selectedID: String?
    ) {
        self.optionId = optionId
        self.title = title
        self.levels = levels
        self.selectedID = selectedID
    }

    public var selectedOption: PrismEffortOption? {
        guard let selectedID else { return nil }
        return levels.first(where: { $0.id == selectedID })
    }
}

/// Resolves thinking effort levels reported by the active model/agent.
/// Resolves only the real `thought_level` choices reported by the active model/agent,
/// filtering out `Default` meta-choices while resolving which real level `Default` stands for.
public enum PrismEffortLevelResolver {
    public struct RawChoice: Sendable, Equatable {
        public let value: String
        public let name: String
        public let description: String?

        public init(value: String, name: String, description: String? = nil) {
            self.value = value
            self.name = name
            self.description = description
        }
    }

    private static let highTierKeys: Set<String> = ["xhigh", "extrahigh", "veryhigh"]
    private static let maxTierKeys: Set<String> = ["max", "maximum", "ultra", "ultrathink", "ultracode"]

    public static func tier(value: String, name: String) -> PrismEffortTier {
        func normalizedKey(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
        }
        let vk = normalizedKey(value)
        let nk = normalizedKey(name)
        if maxTierKeys.contains(vk) || maxTierKeys.contains(nk) { return .max }
        if highTierKeys.contains(vk) || highTierKeys.contains(nk) { return .high }
        return .normal
    }

    private static func isDefaultChoice(_ c: RawChoice) -> Bool {
        let v = c.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v == "default" { return true }
        let n = c.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n == "default" { return true }
        if n.hasPrefix("default") {
            let nextIdx = n.index(n.startIndex, offsetBy: "default".count)
            if nextIdx == n.endIndex { return true }
            let ch = n[nextIdx]
            if !ch.isLetter && !ch.isNumber { return true }
        }
        return false
    }

    private static func stripRepeatedHeading(_ heading: String, from choices: [RawChoice]) -> [RawChoice] {
        let trimmedHeading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHeading.isEmpty, !choices.isEmpty else { return choices }
        let escaped = NSRegularExpression.escapedPattern(for: trimmedHeading)
        guard let regex = try? NSRegularExpression(pattern: "^\(escaped)\\s*:\\s*", options: [.caseInsensitive]) else {
            return choices
        }
        var stripped: [RawChoice] = []
        stripped.reserveCapacity(choices.count)
        for c in choices {
            let ns = c.name as NSString
            let range = NSRange(location: 0, length: ns.length)
            let updated = regex.stringByReplacingMatches(in: c.name, options: [], range: range, withTemplate: "")
            if updated == c.name || updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return choices
            }
            stripped.append(RawChoice(value: c.value, name: updated, description: c.description))
        }
        return stripped
    }

    private static func mentionsWord(_ text: String, word: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word.lowercased())
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: []) else {
            return text.contains(word.lowercased())
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func defaultStandsFor(fallback: RawChoice?, levels: [RawChoice]) -> RawChoice? {
        guard let fallback else { return nil }
        let said = "\(fallback.name) \(fallback.description ?? "")".lowercased()
        let longestFirst = levels.sorted { $0.name.count > $1.name.count }
        return longestFirst.first { mentionsWord(said, word: $0.name) }
    }

    private static func providerDefault(modelValue: String?, levels: [RawChoice]) -> RawChoice? {
        guard let model = modelValue?.lowercased(), !model.isEmpty else { return nil }
        let target: String?
        if model.contains("claude-opus-5-5") || model.contains("claude-haiku-5-5") {
            target = "medium"
        } else if model.contains("claude-") {
            target = "high"
        } else {
            target = nil
        }
        guard let target else { return nil }
        return levels.first { $0.value.lowercased() == target }
    }

    public static func resolve(
        optionId: String,
        optionName: String,
        choices: [RawChoice],
        currentValue: String?,
        modelValue: String? = nil
    ) -> PrismEffortResolved? {
        guard !choices.isEmpty else { return nil }
        let nonDefault = choices.filter { !isDefaultChoice($0) }
        // If every single choice was somehow named "Default", fall back to keeping them rather than hiding.
        let cleanedRaw = stripRepeatedHeading(optionName, from: nonDefault.isEmpty ? choices : nonDefault)
        guard !cleanedRaw.isEmpty else { return nil }

        let fallback = choices.first(where: isDefaultChoice)
        let isDirectLevel = currentValue.map { cur in cleanedRaw.contains(where: { $0.value == cur }) } ?? false
        let shown: String?
        if isDirectLevel {
            shown = currentValue
        } else if let matchedDefault = defaultStandsFor(fallback: fallback, levels: cleanedRaw) {
            shown = matchedDefault.value
        } else if let provider = providerDefault(modelValue: modelValue, levels: cleanedRaw) {
            shown = provider.value
        } else {
            shown = cleanedRaw[(cleanedRaw.count - 1) / 2].value
        }

        let options = cleanedRaw.map { c in
            PrismEffortOption(
                id: c.value,
                label: c.name,
                description: c.description,
                tier: tier(value: c.value, name: c.name)
            )
        }
        return PrismEffortResolved(
            optionId: optionId,
            title: optionName,
            levels: options,
            selectedID: shown
        )
    }
}

/// Where a model menu shows a model: in its main list, with a number key, or under More models.
public enum PrismModelTier: Sendable, Equatable {
    case main
    case more
}

public struct PrismModelOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let brandColor: Color
    public let tag: String
    public let isOlder: Bool
    /// The list the menu shows it in; nil leaves it to the older rule (non-older first, else the first four).
    public let tier: PrismModelTier?
    /// The provider a row of More models and of a search is listed under, when the agent has several.
    public let group: String?
    /// Whether the user pinned it to the top of the agent's model menu.
    public let isPinned: Bool

    public init(
        id: String,
        name: String,
        subtitle: String,
        brandColor: Color,
        tag: String,
        isOlder: Bool = false,
        tier: PrismModelTier? = nil,
        group: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.brandColor = brandColor
        self.tag = tag
        self.isOlder = isOlder
        self.tier = tier
        self.group = group
        self.isPinned = isPinned
    }
}

/// A run of model rows: the main list, a provider's models under More models, or search results.
public struct PrismModelSection: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case main
        case more
        case results
    }

    public let id: String
    public let kind: Kind
    /// The provider heading over the rows, if any.
    public let heading: String?
    public let models: [PrismModelOption]

    public init(id: String, kind: Kind, heading: String?, models: [PrismModelOption]) {
        self.id = id
        self.kind = kind
        self.heading = heading
        self.models = models
    }
}

/// How the model menus lay their rows out, shared by the popovers and the number-key shortcut so
/// both agree on which model a key picks.
public enum PrismModelMenuLayout {
    /// The main list's first models each take a number key.
    public static let numberedCount = 4

    /// The main list and More models: by each option's tier when the caller sets one, else the
    /// non-older models first, else the first four.
    public static func split(_ models: [PrismModelOption]) -> (main: [PrismModelOption], more: [PrismModelOption]) {
        if models.contains(where: { $0.tier != nil }) {
            return (models.filter { $0.tier != .more }, models.filter { $0.tier == .more })
        }
        if models.contains(where: \.isOlder) {
            return (models.filter { !$0.isOlder }, models.filter(\.isOlder))
        }
        return (Array(models.prefix(numberedCount)), Array(models.dropFirst(numberedCount)))
    }

    /// The models the number keys 1 to 4 pick, in order.
    public static func numbered(_ models: [PrismModelOption]) -> [PrismModelOption] {
        Array(split(models).main.prefix(numberedCount))
    }

    /// Whether every word of `query` is in the model's name, id, line or provider, ignoring case.
    public static func matches(_ model: PrismModelOption, query: String) -> Bool {
        let hay = [model.group ?? "", model.name, model.id, model.subtitle].joined(separator: " ").lowercased()
        return query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .allSatisfy { hay.contains($0) }
    }

    /// The sections a menu lists: the matches of a search by provider; else the main list, then
    /// the chosen model when More models holds it and is closed, or all of More models by provider.
    public static func sections(
        _ models: [PrismModelOption],
        selectedID: String?,
        query: String,
        expanded: Bool
    ) -> [PrismModelSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return grouped(models.filter { matches($0, query: trimmed) }, kind: .results)
        }
        let (main, more) = split(models)
        if expanded {
            return [PrismModelSection(id: "main", kind: .main, heading: nil, models: main)]
                + grouped(more, kind: .more)
        }
        let extra = more.first { $0.id == selectedID }
        return [PrismModelSection(id: "main", kind: .main, heading: nil, models: main + (extra.map { [$0] } ?? []))]
    }

    /// Rows by provider, in the order each provider first appears; one section without a heading
    /// when no row names a provider.
    static func grouped(_ models: [PrismModelOption], kind: PrismModelSection.Kind) -> [PrismModelSection] {
        guard !models.isEmpty else { return [] }
        var order: [String] = []
        var byGroup: [String: [PrismModelOption]] = [:]
        for model in models {
            let key = model.group ?? ""
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(model)
        }
        return order.map { key in
            PrismModelSection(
                id: "\(kind.rawValue)-\(key)",
                kind: kind,
                heading: key.isEmpty ? nil : key,
                models: byGroup[key] ?? []
            )
        }
    }
}

public struct PrismModeOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let look: PrismModeLook

    public init(
        id: String,
        name: String,
        description: String = "",
        look: PrismModeLook = .asks
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.look = look
    }
}

public struct PrismBoolToggleOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let isOn: Bool
    public let isDisabled: Bool
    public let isFast: Bool
    public let isUltracode: Bool
    public let indicator: Bool
    /// For a switch with no value of its own, whom it follows and what that gives, such as
    /// "Follows Claude Code · on"; its row shows this line in place of the description.
    public let followsLine: String?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        isOn: Bool,
        isDisabled: Bool = false,
        isFast: Bool = false,
        isUltracode: Bool = false,
        indicator: Bool = false,
        followsLine: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isOn = isOn
        self.isDisabled = isDisabled
        self.isFast = isFast
        self.isUltracode = isUltracode
        self.indicator = indicator
        self.followsLine = followsLine
    }
}

/// The one short tag an agent's row ends with: what stops it from starting a session now, or
/// would soon. `title` is the whole sentence, shown on hover; nil where the tag says all.
public struct PrismAgentTag: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case muted
        case attention
        case danger
    }

    public let text: String
    public let tone: Tone
    public let title: String?

    public init(text: String, tone: Tone, title: String? = nil) {
        self.text = text
        self.tone = tone
        self.title = title
    }
}

public struct PrismAgentSwitchOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let brandColor: Color
    public let isCurrent: Bool
    public let isAvailable: Bool
    public let statusText: String
    public let version: String?
    public let accountSummary: String?
    public let quotaLeftPercent: Int?
    /// What stops the agent, at the end of its row; nil when nothing does.
    public let tag: PrismAgentTag?
    /// Why the agent cannot run, in a sentence, for the options pane.
    public let problemText: String?
    /// The button that fixes it, such as "Install…"; nil when nothing here can.
    public let fixTitle: String?

    public init(
        id: String,
        name: String,
        brandColor: Color,
        isCurrent: Bool,
        isAvailable: Bool = true,
        statusText: String = "ready",
        version: String? = nil,
        accountSummary: String? = nil,
        quotaLeftPercent: Int? = nil,
        tag: PrismAgentTag? = nil,
        problemText: String? = nil,
        fixTitle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.brandColor = brandColor
        self.isCurrent = isCurrent
        self.isAvailable = isAvailable
        self.statusText = statusText
        self.version = version
        self.accountSummary = accountSummary
        self.quotaLeftPercent = quotaLeftPercent
        self.tag = tag
        self.problemText = problemText
        self.fixTitle = fixTitle
    }
}

public struct PrismAgentMenuSection: Identifiable, Sendable, Equatable {
    public var id: String { agent.id }
    public let agent: PrismAgentSwitchOption
    public let models: [PrismModelOption]
    public let selectedModelID: String?
    public let pinnedModelIDs: [String]
    public let canManagePinnedModels: Bool
    public let modes: [PrismModeOption]
    public let selectedModeID: String?
    public let effortTitle: String?
    public let effortLevels: [PrismEffortOption]
    public let selectedEffortID: String?
    public let toggles: [PrismBoolToggleOption]

    public init(
        agent: PrismAgentSwitchOption,
        models: [PrismModelOption],
        selectedModelID: String?,
        pinnedModelIDs: [String] = [],
        canManagePinnedModels: Bool = false,
        modes: [PrismModeOption],
        selectedModeID: String?,
        effortTitle: String? = nil,
        effortLevels: [PrismEffortOption] = [],
        selectedEffortID: String? = nil,
        toggles: [PrismBoolToggleOption]
    ) {
        self.agent = agent
        self.models = models
        self.selectedModelID = selectedModelID
        self.pinnedModelIDs = pinnedModelIDs
        self.canManagePinnedModels = canManagePinnedModels
        self.modes = modes
        self.selectedModeID = selectedModeID
        self.effortTitle = effortTitle
        self.effortLevels = effortLevels
        self.selectedEffortID = selectedEffortID
        self.toggles = toggles
    }
}

// MARK: - Pure SwiftUI 120Hz Segmented Effort Picker (Zero Metal, Zero Layout Jump)

/// Smooth, zero-Metal segmented control displaying the exact thinking effort levels reported
/// by the active model.
public struct PrismEffortSegmentedControl: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let title: String
    public let levels: [PrismEffortOption]
    public let selectedID: String?
    public let showShortcutHint: Bool
    public let onSelect: (String) -> Void

    @State private var hoveredID: String? = nil

    public init(
        title: String,
        levels: [PrismEffortOption],
        selectedID: String?,
        showShortcutHint: Bool = true,
        onSelect: @escaping (String) -> Void
    ) {
        self.title = title
        self.levels = levels
        self.selectedID = selectedID
        self.showShortcutHint = showShortcutHint
        self.onSelect = onSelect
    }

    public var body: some View {
        let dense = levels.count >= 5
        let glideAnim: Animation? = PrismSpringSpec.indicator.animation(tier: motionTier, reduceMotion: reduceMotion)
        let hoverAnim: Animation? = PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)
        let selectedIndex = levels.firstIndex(where: { $0.id == selectedID })
        let selectedTier = selectedIndex.map { levels[$0].tier } ?? .normal
        let spacing: CGFloat = 2

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showShortcutHint {
                    Text(l10n.tr("composer.effortHint"))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                }
            }

            // Equal-width slots backed by a single gliding pill so switching levels never shifts
            // segment boundaries or card width, and tier colors morph smoothly mid-flight.
            HStack(spacing: spacing) {
                ForEach(levels) { level in
                    let isSelected = level.id == selectedID
                    let isHovered = hoveredID == level.id && !isSelected

                    Button {
                        guard level.id != selectedID else { return }
                        onSelect(level.id)
                    } label: {
                        Color.clear
                            .frame(height: 26)
                            .overlay {
                                Text(level.label)
                                    .font(.system(size: dense ? 10.5 : 11.5, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(textColor(for: level, isSelected: isSelected, isHovered: isHovered))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                                    .padding(.horizontal, dense ? 3 : 5)
                            }
                            .background {
                                RoundedRectangle(cornerRadius: tokens.rXS + 1, style: .continuous)
                                    .fill(tokens.hoverWash.opacity(isHovered ? 0.72 : 0))
                                    .animation(hoverAnim, value: isHovered)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(level.description ?? level.label)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .onHover { inside in
                        hoveredID = inside ? level.id : (hoveredID == level.id ? nil : hoveredID)
                    }
                }
            }
            .background {
                if let selectedIndex, !levels.isEmpty {
                    GeometryReader { geo in
                        let count = CGFloat(levels.count)
                        let slotWidth = max(0, (geo.size.width - spacing * max(0, count - 1)) / count)
                        let xOffset = CGFloat(selectedIndex) * (slotWidth + spacing)

                        unifiedActivePill(for: selectedTier)
                            .frame(width: slotWidth, height: geo.size.height)
                            .offset(x: xOffset)
                            .animation(glideAnim, value: selectedID)
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM + 2, style: .continuous)
                    .fill(tokens.surface2.opacity(tokens.palette.isDark ? 0.78 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM + 2, style: .continuous)
                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
            )
            .animation(glideAnim, value: selectedID)
        }
    }

    private func textColor(for level: PrismEffortOption, isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            switch level.tier {
            case .max:
                return tokens.palette.isDark ? Color(hex: 0xDFCFFF) : Color(hex: 0x5B21B6)
            case .high:
                return tokens.palette.isDark ? Color(hex: 0xCFE2FF) : Color(hex: 0x1D4ED8)
            case .normal:
                return tokens.foreground
            }
        }
        return isHovered ? tokens.foreground : tokens.mutedForeground
    }

    private func unifiedActivePill(for tier: PrismEffortTier) -> some View {
        let radius = tokens.rXS + 2
        let isDark = tokens.palette.isDark

        let fillStart: Color
        let fillEnd: Color
        let strokeColor: Color
        let shadowColor: Color
        let shadowRadius: CGFloat

        switch tier {
        case .max:
            fillStart = tokens.prismIris.opacity(isDark ? 0.30 : 0.17)
            fillEnd = tokens.prismCobalt.opacity(isDark ? 0.22 : 0.12)
            strokeColor = tokens.prismIris.opacity(isDark ? 0.58 : 0.42)
            shadowColor = tokens.prismIris.opacity(isDark ? 0.26 : 0.14)
            shadowRadius = 4
        case .high:
            fillStart = tokens.prismCobalt.opacity(isDark ? 0.24 : 0.15)
            fillEnd = tokens.prismCobalt.opacity(isDark ? 0.18 : 0.11)
            strokeColor = tokens.prismCobalt.opacity(isDark ? 0.50 : 0.38)
            shadowColor = tokens.prismCobalt.opacity(isDark ? 0.20 : 0.10)
            shadowRadius = 3
        case .normal:
            let base = isDark ? Color.white.opacity(0.11) : tokens.surface1
            fillStart = base
            fillEnd = base
            strokeColor = tokens.borderStrong
            shadowColor = Color.black.opacity(isDark ? 0.28 : 0.08)
            shadowRadius = 2
        }

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [fillStart, fillEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: shadowRadius, y: 1)
    }
}

// MARK: - Model, Real Effort & Dynamic Switches Selector Popover

/// Floating Obsidian Prism Glass Model, Effort & Dynamic Switches Selector Popover.
/// Primary models (with 1-4 badges), collapsible searchable
/// "More models", model-accurate segmented effort picker, dynamic boolean switches (Fast / Ultracode),
/// account/quota/cache footer, and bottom "Switch agent..." trigger.
public struct ModelEffortPopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let headerTitle: String?
    public let models: [PrismModelOption]
    @Binding public var selectedModelID: String
    public let modes: [PrismModeOption]
    public let selectedModeID: String?
    public let onSelectMode: ((String) -> Void)?
    public let effortTitle: String?
    public let effortLevels: [PrismEffortOption]
    public let selectedEffortID: String?
    public let onSelectEffort: ((String) -> Void)?
    public let toggles: [PrismBoolToggleOption]
    public let onToggleOption: ((String, Bool) -> Void)?
    public let accountNote: String?
    public let cacheNote: String?
    public let canSwitchAgent: Bool
    public let switchAgentDisabledHint: String?
    public let useSystemPopoverChrome: Bool
    public let onOpenAgentSwitcher: (() -> Void)?
    public let onModelPicked: (() -> Void)?
    /// Pins a model (true) or unpins it, answering what to tell the user when that failed. Rows
    /// offer a pin only when it is set.
    public let onTogglePin: (@MainActor (String, Bool) async -> String?)?

    @State private var hoveredModelID: String?
    @State private var hoveredPinID: String?
    @State private var searchQuery: String = ""
    @State private var showMoreModels: Bool = false
    @State private var pinError: String?
    @State private var pinsInFlight: Set<String> = []

    public init(
        headerTitle: String? = nil,
        models: [PrismModelOption],
        selectedModelID: Binding<String>,
        modes: [PrismModeOption] = [],
        selectedModeID: String? = nil,
        onSelectMode: ((String) -> Void)? = nil,
        effortTitle: String? = nil,
        effortLevels: [PrismEffortOption] = [],
        selectedEffortID: String? = nil,
        onSelectEffort: ((String) -> Void)? = nil,
        toggles: [PrismBoolToggleOption] = [],
        onToggleOption: ((String, Bool) -> Void)? = nil,
        accountNote: String? = nil,
        cacheNote: String? = nil,
        canSwitchAgent: Bool = true,
        switchAgentDisabledHint: String? = nil,
        useSystemPopoverChrome: Bool = false,
        onOpenAgentSwitcher: (() -> Void)? = nil,
        onModelPicked: (() -> Void)? = nil,
        onTogglePin: (@MainActor (String, Bool) async -> String?)? = nil
    ) {
        self.onTogglePin = onTogglePin
        self.headerTitle = headerTitle
        self.models = models
        self._selectedModelID = selectedModelID
        self.modes = modes
        self.selectedModeID = selectedModeID
        self.onSelectMode = onSelectMode
        self.effortTitle = effortTitle
        self.effortLevels = effortLevels
        self.selectedEffortID = selectedEffortID
        self.onSelectEffort = onSelectEffort
        self.toggles = toggles
        self.onToggleOption = onToggleOption
        self.accountNote = accountNote
        self.cacheNote = cacheNote
        self.canSwitchAgent = canSwitchAgent
        self.switchAgentDisabledHint = switchAgentDisabledHint
        self.useSystemPopoverChrome = useSystemPopoverChrome
        self.onOpenAgentSwitcher = onOpenAgentSwitcher
        self.onModelPicked = onModelPicked
    }

    public var body: some View {
        let moreModels = PrismModelMenuLayout.split(models).more
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sections = PrismModelMenuLayout.sections(
            models,
            selectedID: selectedModelID,
            query: searchQuery,
            expanded: showMoreModels
        )
        let numbered = PrismModelMenuLayout.numbered(models).map(\.id)
        let rowCount = sections.reduce(0) { $0 + $1.models.count }
        let headingCount = sections.filter { $0.heading != nil }.count
        let dividerCount = sections.contains(where: { $0.kind == .more && $0.heading == nil }) ? 1 : 0

        let rowHeight: CGFloat = models.contains(where: { !$0.subtitle.isEmpty }) ? 40.0 : 34.0
        let listHeight: CGFloat = min(
            CGFloat(max(rowCount, 1)) * rowHeight
                + CGFloat(headingCount) * Self.headingHeight
                + CGFloat(dividerCount) * Self.dividerHeight
                + 4.0,
            232.0
        )

        VStack(alignment: .leading, spacing: 10) {
            // Clean single-line header (no nebula/crystal toggle)
            HStack(spacing: 8) {
                Text(headerTitle ?? l10n.tr("popover.agentAndEffort"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                Spacer()
            }

            // Search box when more than 4 models exist
            if models.count > 4 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.placeholder)
                    TextField(l10n.tr("newSession.searchModels"), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.foreground)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.placeholder)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8.5)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(tokens.surface2.opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder(tokens.borderEtched, lineWidth: 1)
                )
            }

            // Models list (deterministic height, zero NSPopover jump)
            if rowCount == 0 {
                Text(l10n.tr("newSession.noMatch"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.placeholder)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sections) { section in
                            sectionHeader(section, isFirst: section.id == sections.first?.id)
                            ForEach(section.models) { model in
                                modelRow(
                                    model: model,
                                    shortcutNumber: section.kind == .main
                                        ? numbered.firstIndex(of: model.id).map { $0 + 1 }
                                        : nil
                                )
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: listHeight)
                .transaction { $0.animation = nil }
            }

            if let pinError {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(pinError)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(tokens.warning)
                .padding(.horizontal, 8.5)
                .accessibilityElement(children: .combine)
            }

            // More models toggle row (when not actively searching)
            if !isSearching && !moreModels.isEmpty {
                Button {
                    showMoreModels.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showMoreModels ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(tokens.mutedForeground)
                        Text(showMoreModels ? l10n.tr("composer.hideMoreModels") : l10n.tr("composer.moreModels", moreModels.count))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                            .fill(tokens.hoverWash.opacity(0.65))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Optional inline Permission Modes (compact callers)
            if !modes.isEmpty, let onSelectMode {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.tr("popover.permissionMode"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)

                    HStack(spacing: 4) {
                        ForEach(modes) { mode in
                            let active = mode.id == selectedModeID
                            Button {
                                onSelectMode(mode.id)
                            } label: {
                                Text(mode.name)
                                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                                    .foregroundStyle(
                                        mode.look == .full
                                            ? tokens.danger
                                            : (active ? tokens.foreground : tokens.mutedForeground)
                                    )
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(
                                            active
                                                ? (mode.look == .full ? tokens.dangerSoft : tokens.primarySoft)
                                                : tokens.surface2.opacity(0.7)
                                        )
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(
                                            active
                                                ? (mode.look == .full ? tokens.danger.opacity(0.5) : tokens.primaryBorder)
                                                : tokens.borderEtched,
                                            lineWidth: 0.75
                                        )
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                }
            }

            // Model-accurate segmented Reasoning Effort control (only shown when model actually supports levels!)
            if !effortLevels.isEmpty, let onSelectEffort {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                PrismEffortSegmentedControl(
                    title: effortTitle?.isEmpty == false ? (effortTitle ?? l10n.tr("effort.title")) : l10n.tr("effort.title"),
                    levels: effortLevels,
                    selectedID: selectedEffortID,
                    showShortcutHint: true,
                    onSelect: onSelectEffort
                )
            }

            // The agent's switches (Fast mode, Ultracode, ...) as rows lined up with the model rows
            if !toggles.isEmpty, let onToggleOption {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                VStack(spacing: 2) {
                    ForEach(toggles) { item in
                        PrismSwitchRow(item: item, onToggle: onToggleOption)
                    }
                }
            }

            // Switch Agent action row (opens two-pane AgentSwitcherPopoverView in place)
            if let onOpenAgentSwitcher {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                Button {
                    onOpenAgentSwitcher()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(canSwitchAgent ? tokens.prismIris : tokens.placeholder)
                            .frame(width: 16)
                        Text(l10n.tr("composer.switchAgentAction"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(canSwitchAgent ? tokens.foreground : tokens.placeholder)
                        Spacer()
                        if !canSwitchAgent, let hint = switchAgentDisabledHint {
                            Text(hint)
                                .font(.system(size: 10))
                                .foregroundStyle(tokens.placeholder)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tokens.placeholder)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .fill(tokens.hoverWash.opacity(canSwitchAgent ? 0.5 : 0.2))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSwitchAgent)
            }

            // Account / Quota / Warm Cache footer
            if (accountNote?.isEmpty == false) || (cacheNote?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 2.5) {
                    if let accountNote, !accountNote.isEmpty {
                        Text(accountNote)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let cacheNote, !cacheNote.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(tokens.warning)
                            Text(cacheNote)
                                .font(.system(size: 10))
                                .foregroundStyle(tokens.warning)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 1)
            }
        }
        .padding(13)
        .frame(width: 356)
        .background(useSystemPopoverChrome ? tokens.surface1 : Color.clear)
        .modifier(OptionalPopoverChrome(useSystemPopoverChrome: useSystemPopoverChrome, cornerRadius: tokens.rLG))
    }

    private static let headingHeight: CGFloat = 22
    private static let dividerHeight: CGFloat = 11
    /// The leading mark's and the trailing check's column, which the switch rows line up with.
    private static let markWidth: CGFloat = 16
    private static let pinWidth: CGFloat = 18
    private static let rowPadding: CGFloat = 8.5

    @ViewBuilder
    private func sectionHeader(_ section: PrismModelSection, isFirst: Bool) -> some View {
        if let heading = section.heading {
            Text(heading.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(tokens.placeholder)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: Self.headingHeight - 2, alignment: .bottomLeading)
                .padding(.horizontal, Self.rowPadding)
                .accessibilityAddTraits(.isHeader)
        } else if section.kind == .more, !isFirst {
            Rectangle()
                .fill(tokens.borderEtched)
                .frame(height: 1)
                .padding(.horizontal, Self.rowPadding)
                .padding(.vertical, 4)
        }
    }

    private func togglePin(_ model: PrismModelOption) {
        guard let onTogglePin, !pinsInFlight.contains(model.id) else { return }
        pinsInFlight.insert(model.id)
        Task {
            let message = await onTogglePin(model.id, !model.isPinned)
            pinsInFlight.remove(model.id)
            pinError = message
            if let message {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    private func pinButton(_ model: PrismModelOption, label: String) -> some View {
        let hovered = hoveredPinID == model.id
        return Button {
            togglePin(model)
        } label: {
            Image(systemName: model.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.isPinned || hovered ? tokens.secondaryForeground : tokens.placeholder)
                .frame(width: Self.pinWidth, height: Self.pinWidth)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovered ? tokens.hoverWash : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pinsInFlight.contains(model.id))
        .help(label)
        // Keyboard focus stays on the rows, and VoiceOver reaches the pin as an action of its row.
        .focusable(false)
        .accessibilityHidden(true)
        .onHover { inside in
            hoveredPinID = inside ? model.id : (hoveredPinID == model.id ? nil : hoveredPinID)
        }
    }

    private func modelRow(model: PrismModelOption, shortcutNumber: Int?) -> some View {
        let active = model.id == selectedModelID
        let hovered = hoveredModelID == model.id
        let canPin = onTogglePin != nil
        let pinShown = canPin && (model.isPinned || hovered)
        let pinLabel = l10n.tr(model.isPinned ? "composer.unpinModel" : "composer.pinModel", model.name)
        return Button {
            selectedModelID = model.id
            onModelPicked?()
        } label: {
            HStack(spacing: 8.5) {
                Circle()
                    .fill(model.brandColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: active ? model.brandColor.opacity(0.65) : .clear, radius: 4)
                    .frame(width: Self.markWidth)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? tokens.foreground : tokens.secondaryForeground)
                        .lineLimit(1)
                    if !model.subtitle.isEmpty {
                        Text(model.subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if !model.tag.isEmpty && model.tag != "MODEL" {
                    Text(model.tag)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(active ? model.brandColor : tokens.mutedForeground)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(active ? model.brandColor.opacity(0.14) : tokens.surface2))
                }

                if canPin {
                    // Room for the pin, which lies over the row so that its click never picks the model.
                    Color.clear.frame(width: Self.pinWidth, height: Self.pinWidth)
                }

                Group {
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(tokens.primary)
                    } else if let num = shortcutNumber {
                        Text("\(num)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .frame(width: 16, height: 16)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(tokens.hoverWash.opacity(0.8))
                            )
                    }
                }
                .frame(width: Self.markWidth)
            }
            .padding(.horizontal, Self.rowPadding)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(active ? tokens.activeWash : (hovered ? tokens.hoverWash : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if canPin {
                pinButton(model, label: pinLabel)
                    .padding(.trailing, Self.rowPadding + Self.markWidth + 8.5)
                    .opacity(pinShown ? 1 : 0)
                    .allowsHitTesting(pinShown)
                    .animation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion), value: pinShown)
            }
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .modifier(ModelPinAccessibility(
            enabled: canPin,
            pinnedValue: model.isPinned ? l10n.tr("composer.pinnedValue") : nil,
            actionLabel: pinLabel,
            action: { togglePin(model) }
        ))
        .onHover { inside in
            hoveredModelID = inside ? model.id : (hoveredModelID == model.id ? nil : hoveredModelID)
        }
    }

}

/// VoiceOver's way to a model row's pin: "Pinned" as the row's value, and pinning or unpinning
/// as an action of the row where the menu can change pins.
private struct ModelPinAccessibility: ViewModifier {
    let enabled: Bool
    let pinnedValue: String?
    let actionLabel: String?
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, let actionLabel, let action {
            content
                .accessibilityValue(pinnedValue ?? "")
                .accessibilityAction(named: Text(actionLabel), action)
        } else if enabled {
            content.accessibilityValue(pinnedValue ?? "")
        } else {
            content
        }
    }
}

/// One of an agent's switches as a row lined up with the model rows: an icon in the marks'
/// column, the name over a line saying why it cannot change now, whom it follows, or what it
/// does, and the switch at the end. The description shows on hover when the line says another thing.
struct PrismSwitchRow: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: PrismBoolToggleOption
    var isAvailable: Bool = true
    let onToggle: (String, Bool) -> Void

    @State private var hovered = false

    var body: some View {
        let locked = item.isDisabled || !isAvailable
        let line = item.isDisabled ? l10n.tr("composer.changesBetweenTurns") : (item.followsLine ?? item.description)
        let tooltip = item.description.flatMap { $0.isEmpty || $0 == line ? nil : $0 }
        let tint = item.isFast ? tokens.warning : (item.isUltracode ? tokens.prismIris : tokens.prismCobalt)

        Button {
            if !locked {
                onToggle(item.id, !item.isOn)
            }
        } label: {
            HStack(spacing: 8.5) {
                Image(systemName: item.isFast ? "bolt.fill" : (item.isUltracode ? "sparkles" : "slider.horizontal.3"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.isOn ? tint : tokens.mutedForeground)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: item.isOn ? .semibold : .medium))
                        .foregroundStyle(locked ? tokens.placeholder : (item.isOn && item.isUltracode ? tint : tokens.foreground))
                        .lineLimit(1)
                    if let line, !line.isEmpty {
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Capsule()
                    .fill(item.isOn ? (item.isFast || item.isUltracode ? tint : tokens.primary) : tokens.surface3)
                    .frame(width: 28, height: 16)
                    .overlay(alignment: item.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .padding(2)
                    }
                    .opacity(locked ? 0.55 : 1)
                    .animation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion), value: item.isOn)
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(hovered && !locked ? tokens.hoverWash : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .modifier(OptionalHelp(text: tooltip))
        .accessibilityAddTraits(item.isOn ? [.isToggle, .isSelected] : .isToggle)
        .onHover { hovered = $0 }
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

// MARK: - Two-Pane Agent & Model Combobox Menu

public struct AgentSwitcherPopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let sections: [PrismAgentMenuSection]
    public let activeAgentID: String?
    public let pendingAgentID: String?
    public let showBackToModelsTitle: String?
    public let useSystemPopoverChrome: Bool
    public let onInspectAgent: (String) -> Void
    public let onChooseAgent: (String) -> Void
    public let onSelectModel: (String, String) -> Void
    public let onSelectMode: (String, String) -> Void
    public let onSelectEffort: (String, String) -> Void
    public let onToggleOption: (String, String, Bool) -> Void
    public let onBackToModels: (() -> Void)?
    public let onFixAgent: ((String) -> Void)?

    @State private var inspectedAgentID: String = ""
    @State private var searchQuery: String = ""
    @State private var showMoreForAgent: Set<String> = []
    @State private var hoveredModelKey: String? = nil

    public init(
        sections: [PrismAgentMenuSection],
        activeAgentID: String?,
        pendingAgentID: String? = nil,
        showBackToModelsTitle: String? = nil,
        useSystemPopoverChrome: Bool = false,
        onInspectAgent: @escaping (String) -> Void,
        onChooseAgent: @escaping (String) -> Void,
        onSelectModel: @escaping (String, String) -> Void,
        onSelectMode: @escaping (String, String) -> Void,
        onSelectEffort: @escaping (String, String) -> Void,
        onToggleOption: @escaping (String, String, Bool) -> Void,
        onBackToModels: (() -> Void)? = nil,
        onFixAgent: ((String) -> Void)? = nil
    ) {
        self.sections = sections
        self.activeAgentID = activeAgentID
        self.pendingAgentID = pendingAgentID
        self.showBackToModelsTitle = showBackToModelsTitle
        self.useSystemPopoverChrome = useSystemPopoverChrome
        self.onInspectAgent = onInspectAgent
        self.onChooseAgent = onChooseAgent
        self.onSelectModel = onSelectModel
        self.onSelectMode = onSelectMode
        self.onSelectEffort = onSelectEffort
        self.onToggleOption = onToggleOption
        self.onBackToModels = onBackToModels
        self.onFixAgent = onFixAgent
    }

    private var resolvedInspectedID: String {
        if !inspectedAgentID.isEmpty, sections.contains(where: { $0.id == inspectedAgentID }) {
            return inspectedAgentID
        }
        return pendingAgentID ?? activeAgentID ?? sections.first?.id ?? ""
    }

    private var filteredSections: [PrismAgentMenuSection] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sections }
        return sections.filter { sec in
            if sec.agent.name.lowercased().contains(q) || sec.agent.id.lowercased().contains(q) {
                return true
            }
            return sec.models.contains { PrismModelMenuLayout.matches($0, query: q) }
        }
    }

    public var body: some View {
        let currentSections = filteredSections
        let readyList = currentSections.filter(\.agent.isAvailable)
        let unavailableList = currentSections.filter { !$0.agent.isAvailable }
        let inspectedSection = currentSections.first(where: { $0.id == resolvedInspectedID })
            ?? currentSections.first

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let backTitle = showBackToModelsTitle, let onBackToModels {
                    Button(action: onBackToModels) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text(backTitle)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tokens.hoverWash))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.placeholder)
                    TextField(l10n.tr("newSession.searchAgentsAndModels"), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(tokens.foreground)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.placeholder)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(tokens.surface2.opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder(tokens.borderEtched, lineWidth: 1)
                )
            }
            .padding(10)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if currentSections.isEmpty {
                Text(l10n.tr("newSession.noMatch"))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.placeholder)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            if !readyList.isEmpty {
                                Text(l10n.tr("newSession.readyAgents"))
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)
                                    .padding(.bottom, 2)

                                ForEach(readyList) { section in
                                    agentRailRow(section: section, isInspected: inspectedSection?.id == section.id)
                                }
                            }

                            if !unavailableList.isEmpty {
                                Text(l10n.tr("newSession.unavailableAgents"))
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                                    .padding(.horizontal, 8)
                                    .padding(.top, readyList.isEmpty ? 4 : 8)
                                    .padding(.bottom, 2)

                                ForEach(unavailableList) { section in
                                    agentRailRow(section: section, isInspected: inspectedSection?.id == section.id)
                                }
                            }
                        }
                        .padding(7)
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: 198)

                    Rectangle().fill(tokens.borderEtched).frame(width: 1)

                    if let sec = inspectedSection {
                        rightOptionsPane(section: sec)
                            .frame(width: 334)
                    }
                }
                .frame(height: 368)
            }
        }
        .frame(width: 533)
        .background(useSystemPopoverChrome ? tokens.surface1 : Color.clear)
        .modifier(OptionalPopoverChrome(useSystemPopoverChrome: useSystemPopoverChrome, cornerRadius: tokens.rLG))
        .onAppear {
            let initial = pendingAgentID ?? activeAgentID ?? sections.first?.id ?? ""
            inspectedAgentID = initial
            if !initial.isEmpty {
                onInspectAgent(initial)
            }
        }
    }

    private func agentRailRow(section: PrismAgentMenuSection, isInspected: Bool) -> some View {
        let agent = section.agent
        let isPicked = (pendingAgentID == agent.id) || (pendingAgentID == nil && activeAgentID == agent.id)
        return Button {
            inspectedAgentID = agent.id
            onInspectAgent(agent.id)
            if agent.isAvailable {
                onChooseAgent(agent.id)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(agent.isAvailable ? agent.brandColor : tokens.placeholder.opacity(0.45))
                    .frame(width: 8, height: 8)
                    .shadow(color: isPicked ? agent.brandColor.opacity(0.6) : .clear, radius: 4)

                HStack(spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: isInspected || isPicked ? .semibold : .medium))
                        .foregroundStyle(agent.isAvailable ? tokens.foreground : tokens.placeholder)
                        .lineLimit(1)
                    if pendingAgentID == agent.id {
                        Text(l10n.tr("composer.switchNextBadge"))
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismIris)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                // Only what stops the agent is written on its row; the sentence shows on hover.
                if let tag = agent.tag {
                    Text(tag.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tagColor(tag.tone))
                        .lineLimit(1)
                        .help(tag.title ?? tag.text)
                }

                if isPicked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(pendingAgentID == agent.id ? tokens.prismIris : tokens.primary)
                }
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(
                        isInspected
                            ? (pendingAgentID == agent.id ? tokens.prismIris.opacity(0.14) : tokens.activeWash)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            agent.tag.map { l10n.tr("agents.tag.rowState", agent.name, $0.title ?? $0.text) } ?? agent.name
        )
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .onHover { inside in
            if inside && inspectedAgentID != agent.id {
                inspectedAgentID = agent.id
                onInspectAgent(agent.id)
            }
        }
    }

    private func paneModelRow(section: PrismAgentMenuSection, model: PrismModelOption) -> some View {
        let active = model.id == section.selectedModelID
        let key = "\(section.id)::\(model.id)"
        let hovered = hoveredModelKey == key
        return Button {
            onSelectModel(section.id, model.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? tokens.foreground : tokens.secondaryForeground)
                        .lineLimit(1)
                    if !model.subtitle.isEmpty {
                        Text(model.subtitle)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tokens.placeholder)
                        .accessibilityHidden(true)
                }
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tokens.primary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(active ? tokens.activeWash : (hovered ? tokens.hoverWash : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!section.agent.isAvailable)
        .accessibilityAddTraits(active ? .isSelected : [])
        .modifier(ModelPinAccessibility(
            enabled: model.isPinned,
            pinnedValue: l10n.tr("composer.pinnedValue"),
            actionLabel: nil,
            action: nil
        ))
        .onHover { inside in
            hoveredModelKey = inside ? key : (hoveredModelKey == key ? nil : hoveredModelKey)
        }
    }

    private func rightOptionsPane(section: PrismAgentMenuSection) -> some View {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isSearchingModels = !q.isEmpty && !section.agent.name.lowercased().contains(q)
        let moreModels = PrismModelMenuLayout.split(section.models).more
        let expandedMore = showMoreForAgent.contains(section.id)
        let modelSections = PrismModelMenuLayout.sections(
            section.models,
            selectedID: section.selectedModelID,
            query: isSearchingModels ? q : "",
            expanded: expandedMore
        )
        let shownCount = modelSections.reduce(0) { $0 + $1.models.count }

        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(section.agent.brandColor)
                        .frame(width: 7, height: 7)
                    Text(l10n.tr("composer.configureTargetOptions", section.agent.name))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                    Spacer()
                }

                if section.agent.problemText != nil || section.agent.fixTitle != nil {
                    agentProblemCard(section.agent)
                }

                if shownCount == 0 {
                    Text(l10n.tr("composer.noModelsReported"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.placeholder)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 2.5) {
                        ForEach(modelSections) { modelSection in
                            if let heading = modelSection.heading {
                                Text(heading.uppercased())
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 5)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(modelSection.models) { model in
                                paneModelRow(section: section, model: model)
                            }
                        }
                    }

                    if !isSearchingModels && !moreModels.isEmpty {
                        Button {
                            if expandedMore {
                                showMoreForAgent.remove(section.id)
                            } else {
                                showMoreForAgent.insert(section.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: expandedMore ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(expandedMore ? l10n.tr("composer.hideMoreModels") : l10n.tr("composer.moreModels", moreModels.count))
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(tokens.secondaryForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(tokens.hoverWash.opacity(0.65)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !section.modes.isEmpty {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.tr("popover.permissionMode"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4.5) {
                                ForEach(section.modes) { mode in
                                    let active = mode.id == section.selectedModeID
                                    Button {
                                        onSelectMode(section.id, mode.id)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: mode.look.systemImage)
                                                .font(.system(size: 9.5, weight: .semibold))
                                            Text(mode.name)
                                                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(
                                            mode.look == .full
                                                ? tokens.danger
                                                : (active ? tokens.foreground : tokens.mutedForeground)
                                        )
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4.5)
                                        .background(
                                            Capsule().fill(
                                                active
                                                    ? (mode.look == .full ? tokens.dangerSoft : tokens.primarySoft)
                                                    : tokens.surface2.opacity(0.75)
                                            )
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(
                                                active
                                                    ? (mode.look == .full ? tokens.danger.opacity(0.5) : tokens.primaryBorder)
                                                    : tokens.borderEtched,
                                                lineWidth: 0.75
                                            )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!section.agent.isAvailable)
                                    .accessibilityAddTraits(active ? .isSelected : [])
                                }
                            }
                        }
                    }
                }

                // Real model-specific effort segments (zero Metal)
                if !section.effortLevels.isEmpty {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)

                    PrismEffortSegmentedControl(
                        title: section.effortTitle?.isEmpty == false
                            ? (section.effortTitle ?? l10n.tr("effort.title"))
                            : l10n.tr("effort.title"),
                        levels: section.effortLevels,
                        selectedID: section.selectedEffortID,
                        showShortcutHint: false,
                        onSelect: { value in
                            onSelectEffort(section.id, value)
                        }
                    )
                    .disabled(!section.agent.isAvailable)
                    .opacity(section.agent.isAvailable ? 1.0 : 0.5)
                }

                if !section.toggles.isEmpty {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)

                    VStack(spacing: 2) {
                        ForEach(section.toggles) { item in
                            PrismSwitchRow(item: item, isAvailable: section.agent.isAvailable) { optionId, on in
                                onToggleOption(section.id, optionId, on)
                            }
                        }
                    }
                }

                if let acct = section.agent.accountSummary, !acct.isEmpty {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                    Text(acct)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.automatic)
    }
}

extension AgentSwitcherPopoverView {
    fileprivate func tagColor(_ tone: PrismAgentTag.Tone) -> Color {
        PrismAgentTagStyle.color(tone, tokens: tokens)
    }

    fileprivate func agentProblemCard(_ agent: PrismAgentSwitchOption) -> some View {
        PrismAgentProblemCard(agent: agent, onFixAgent: onFixAgent)
    }
}

private struct OptionalPopoverChrome: ViewModifier {
    let useSystemPopoverChrome: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if useSystemPopoverChrome {
            content
        } else {
            content.prismSurface(elevation: .popover, cornerRadius: cornerRadius)
        }
    }
}

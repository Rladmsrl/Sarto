import Foundation

// Shared model menu list ordering and folding rules across all agents.

/// One model as the menus read it: from which provider, of which family, at which version.
public struct ModelMenuRead: Sendable, Equatable, Identifiable {
    public var id: String { value }
    public let choice: ConfigChoice
    public let value: String
    /// The name without a `provider/` prefix.
    public let name: String
    /// The agent's group for it, else the part of its name, or its value, before the last `/`.
    public let provider: String
    /// The family within the provider, lower case; a model without a version is one of its own.
    public let family: String
    /// The family's name as a row shows it, such as Opus or DeepSeek Flash.
    public let familyName: String
    public let version: [Int]?
    /// The version as written, such as 5.5, without a leading v.
    public let versionName: String?
    /// Its place in the agent's list.
    public let order: Int
    /// A lower version than the newest of its family, or one the agent marks older.
    public internal(set) var older: Bool
    /// The agent's Default, on a row of its own since it stands for no listed model.
    public let isDefault: Bool
}

/// Models of one provider, in the order the agent first lists each provider.
public struct ModelProviderGroup<Item: Sendable & Equatable>: Sendable, Equatable {
    public let provider: String
    public let items: [Item]
}

/// One family's row in More models: its newest version first, a model without one alone.
public struct ModelFamilyRow: Sendable, Equatable {
    public let key: String
    public let name: String
    public let models: [ModelMenuRead]
    /// Whether its models have versions.
    public let versioned: Bool
}

public struct ModelMenuLists: Sendable, Equatable {
    /// The main list holds this many models, each with a number key, before More models.
    public static let mainCount = 4

    /// Every model the agent lists, but one shown as another, in the agent's order.
    public let all: [ModelMenuRead]
    /// The main list, at most `mainCount`, in the order it shows them.
    public let main: [ModelMenuRead]
    /// The chosen model's row.
    public let chosen: ModelMenuRead?
    /// The chosen model when the main list leaves it out: a row after the main list.
    public let extra: ModelMenuRead?
    /// Every model the main list leaves out, in the agent's order.
    public let more: [ModelMenuRead]
    /// Whether the models come from several providers, which their rows then name.
    public let several: Bool
    /// The model the agent's Default stands for, whose row carries the Default tag.
    public let defaultValue: String?

    /// The main list takes, up to four, the models the user pinned, then from one provider its
    /// current generation (the newest of each family) or from several the agent's recently used
    /// models, then the agent's current models in its order. Pinned models lead in the order
    /// pinned; the rest go known families largest first.
    public init(choices: [ConfigChoice], current: String?, kept: KeptModels = KeptModels()) {
        var reads: [ModelMenuRead] = []
        for choice in choices where (choice.shownAs ?? "").isEmpty {
            reads.append(Self.readModel(choice, order: reads.count))
        }
        Self.markOlder(&reads)
        let all = reads
        var byValue: [String: ModelMenuRead] = [:]
        for read in all { byValue[read.value] = read }
        let several = Set(all.filter { !$0.isDefault }.map(\.provider)).count > 1

        var picked: [ModelMenuRead] = []
        var pickedOrders = Set<Int>()
        func take(_ read: ModelMenuRead?) {
            guard let read, picked.count < Self.mainCount, !pickedOrders.contains(read.order) else { return }
            picked.append(read)
            pickedOrders.insert(read.order)
        }
        var pinned: [ModelMenuRead] = []
        var pinnedOrders = Set<Int>()
        for value in kept.pinned {
            guard let read = byValue[value], pinnedOrders.insert(read.order).inserted else { continue }
            pinned.append(read)
        }
        pinned.forEach(take)
        let currentModels = all.filter { !$0.older }
        if several {
            for value in kept.recent { take(byValue[value]) }
        } else {
            Self.sortByFamily(currentModels.filter { !$0.isDefault }, read: { $0 }).forEach(take)
        }
        currentModels.forEach(take)
        // An agent that marks every model older still gets a main list.
        if picked.isEmpty { all.forEach(take) }

        let main = pinned.filter { pickedOrders.contains($0.order) }
            + Self.sortByFamily(picked.filter { !pinnedOrders.contains($0.order) }, read: { $0 })
        let mainOrders = Set(main.map(\.order))
        let chosenValue = Self.shownValue(choices: choices, current: current)
        let chosen = all.first { $0.value == chosenValue }
        let shownAs = choices.first { !($0.shownAs ?? "").isEmpty && Self.isDefaultChoice($0) }?.shownAs

        self.all = all
        self.main = main
        self.chosen = chosen
        self.extra = chosen.flatMap { mainOrders.contains($0.order) ? nil : $0 }
        self.more = all.filter { !mainOrders.contains($0.order) }
        self.several = several
        self.defaultValue = shownAs.flatMap { byValue[$0] == nil ? nil : $0 }
    }

    /// The value whose row stands for the current model: the one it is shown as, else its own.
    public static func shownValue(choices: [ConfigChoice], current: String?) -> String? {
        choices.first { $0.value == current }?.shownAs ?? current
    }

    /// The model a number key chooses among the main list's first four, for 1 to 4.
    public func numbered(_ key: Int) -> ModelMenuRead? {
        guard key >= 1, key <= Self.mainCount, key <= main.count else { return nil }
        return main[key - 1]
    }

    /// More models in one list, as their families show them: by provider, each family's newest first.
    public var moreInOrder: [ModelMenuRead] {
        Self.familyGroups(more).flatMap { group in group.items.flatMap(\.models) }
    }

    /// The models a search finds, each family's newest first, by provider.
    public func search(_ query: String) -> [ModelProviderGroup<ModelMenuRead>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.familyGroups(all).compactMap { group in
            let items = group.items.flatMap(\.models).filter { Self.matches($0, query: q) }
            return items.isEmpty ? nil : ModelProviderGroup(provider: group.provider, items: items)
        }
    }

    /// The model the agent's Default runs, by its name when listed, for a Default on a row of its own.
    public func defaultUses(_ read: ModelMenuRead) -> String? {
        guard let id = read.choice.modelId else { return nil }
        return all.first { !$0.isDefault && ($0.choice.modelId ?? $0.value) == id }?.name ?? id
    }

    /// Whether every word of `query` is in the model's provider, name or id, ignoring case.
    public static func matches(_ read: ModelMenuRead, query: String) -> Bool {
        let hay = [read.provider, read.choice.name, read.choice.value, read.choice.modelId ?? ""]
            .joined(separator: " ")
            .lowercased()
        return query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .allSatisfy { hay.contains($0) }
    }

    /// Models grouped by provider, in the order the agent first lists each, then into families.
    public static func familyGroups(_ models: [ModelMenuRead]) -> [ModelProviderGroup<ModelFamilyRow>] {
        var providers: [String] = []
        var families: [String: (keys: [String], members: [String: [ModelMenuRead]])] = [:]
        for read in models {
            if families[read.provider] == nil {
                providers.append(read.provider)
                families[read.provider] = ([], [:])
            }
            let key = read.version != nil ? read.family : "\u{0}\(read.value)"
            if families[read.provider]?.members[key] == nil {
                families[read.provider]?.keys.append(key)
                families[read.provider]?.members[key] = []
            }
            families[read.provider]?.members[key]?.append(read)
        }
        return providers.map { provider in
            let entry = families[provider] ?? ([], [:])
            let rows = entry.keys.compactMap { key -> ModelFamilyRow? in
                guard let members = entry.members[key], let first = members.first else { return nil }
                let sorted = members.sorted { a, b in
                    let byVersion = compareVersions(b.version ?? [], a.version ?? [])
                    return byVersion != 0 ? byVersion < 0 : a.order < b.order
                }
                return ModelFamilyRow(key: key, name: first.familyName, models: sorted, versioned: first.version != nil)
            }
            return ModelProviderGroup(provider: provider, items: sortByFamily(rows, read: { $0.models[0] }))
        }
    }

    // MARK: - Reading a model

    static func isDefaultChoice(_ choice: ConfigChoice) -> Bool {
        choice.value.lowercased() == "default" || startsWithWord(choice.name.lowercased(), "default")
    }

    /// Reads one model: its family and version from its name, else from its id.
    static func readModel(_ choice: ConfigChoice, order: Int) -> ModelMenuRead {
        let name = afterLastSlash(choice.name)
        let provider = providerOf(choice)
        let isDefault = isDefaultChoice(choice)
        let (main, qualifier) = splitQualifier(name)
        // A name such as claude-opus-4-1 is an id, whose dashes join its version's numbers.
        let looksLikeId = !main.contains(where: { $0.isWhitespace }) && main.contains("-")
        func make(family: String, familyName: String, version: String?) -> ModelMenuRead {
            ModelMenuRead(
                choice: choice,
                value: choice.value,
                name: name,
                provider: provider,
                family: family,
                familyName: familyName,
                version: version.map(versionOf),
                versionName: version,
                order: order,
                older: false,
                isDefault: isDefault
            )
        }
        if !isDefault, let named = readVersion(main, id: looksLikeId) {
            let familyName = (named.words + [qualifier]).filter { !$0.isEmpty }.joined(separator: " ")
            return make(family: familyName.lowercased(), familyName: familyName, version: named.version)
        }
        let id = choice.modelId ?? choice.value
        if !isDefault, let fromId = readVersion(afterLastSlash(id), id: true) {
            let family = (fromId.words + [qualifier]).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
            return make(family: family, familyName: name, version: fromId.version)
        }
        return make(family: name.lowercased(), familyName: name, version: nil)
    }

    static func providerOf(_ choice: ConfigChoice) -> String {
        if let group = choice.group, !group.isEmpty { return group }
        if let slash = choice.name.lastIndex(of: "/"), slash > choice.name.startIndex {
            return String(choice.name[..<slash])
        }
        if let slash = choice.value.lastIndex(of: "/"), slash > choice.value.startIndex {
            return String(choice.value[..<slash])
        }
        return ""
    }

    private static func afterLastSlash(_ text: String) -> String {
        guard let slash = text.lastIndex(of: "/") else { return text }
        return String(text[text.index(after: slash)...])
    }

    /// Splits off what follows a model's name and qualifies it, as in "GPT-6.2-Sol · Codex" or
    /// "(Thinking)": the first run of spaces followed by `·` or `(`.
    private static func splitQualifier(_ name: String) -> (main: String, qualifier: String) {
        var index = name.startIndex
        while index < name.endIndex {
            guard name[index].isWhitespace else {
                index = name.index(after: index)
                continue
            }
            var end = index
            while end < name.endIndex, name[end].isWhitespace { end = name.index(after: end) }
            if end < name.endIndex, name[end] == "·" || name[end] == "(" {
                let qualifier = name[index...].trimmingCharacters(in: .whitespacesAndNewlines)
                return (String(name[..<index]), qualifier)
            }
            index = end
        }
        return (name, "")
    }

    /// Splits text the way `text.split(/([\s_-]+)/)` does: tokens at even places, separators at odd.
    private static func tokensAndSeparators(_ text: String) -> [String] {
        func isSeparator(_ c: Character) -> Bool { c.isWhitespace || c == "_" || c == "-" }
        var parts: [String] = []
        var current = ""
        var inSeparator = false
        for c in text {
            if isSeparator(c) != inSeparator {
                parts.append(current)
                current = ""
                inSeparator.toggle()
            }
            current.append(c)
        }
        parts.append(current)
        if inSeparator { parts.append("") }
        return parts
    }

    /// The version in `text` and the words around it. In an id, numbers joined by dashes are one
    /// version (`claude-opus-4-8` is 4.8) and a date is dropped.
    static func readVersion(_ text: String, id: Bool = false) -> (words: [String], version: String)? {
        let parts = tokensAndSeparators(text)
        var i = 0
        while i < parts.count {
            defer { i += 2 }
            let token = parts[i]
            let number = numberVersion(token)
            let attached = number == nil ? attachedVersion(token) : nil
            guard number != nil || attached != nil else { continue }
            var version = number ?? attached!.version
            var end = i
            if number != nil, !version.contains(".") {
                while end + 2 < parts.count, parts[end + 1] == "-", isShortNumber(parts[end + 2]) {
                    version += ".\(parts[end + 2])"
                    end += 2
                }
            }
            var words: [String] = stride(from: 0, to: i, by: 2).map { parts[$0] }
            if let attached { words.append(attached.word) }
            words += stride(from: end + 2, to: parts.count, by: 2).map { parts[$0] }
            words = words.filter { !$0.isEmpty && !(id && isDate($0)) }
            return (words, version)
        }
        return nil
    }

    /// `^[vV]?(\d{1,3}(?:\.\d+)*)$`: a version such as 5.5, V4.1 or 6; three digits at most, so a
    /// build such as 1017 is no version.
    private static func numberVersion(_ token: String) -> String? {
        var rest = Substring(token)
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        return isVersion(rest) ? String(rest) : nil
    }

    /// `^([A-Za-z]+)(\d{1,3}(?:\.\d+)*)$`: a version written onto its family's word, as in Qwen3.6 or K2.
    private static func attachedVersion(_ token: String) -> (word: String, version: String)? {
        let word = token.prefix { $0.isASCII && $0.isLetter }
        guard !word.isEmpty else { return nil }
        let rest = token[word.endIndex...]
        return isVersion(rest) ? (String(word), String(rest)) : nil
    }

    private static func isVersion(_ text: Substring) -> Bool {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = components.first, (1...3).contains(first.count) else { return false }
        return components.allSatisfy { !$0.isEmpty && $0.allSatisfy(isASCIIDigit) }
    }

    private static func isShortNumber(_ text: String) -> Bool {
        (1...2).contains(text.count) && text.allSatisfy(isASCIIDigit)
    }

    /// A date in an id, as in claude-haiku-4-5-20251001.
    private static func isDate(_ text: String) -> Bool {
        text.count >= 6 && text.allSatisfy(isASCIIDigit)
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_")
    }

    /// `/^word\b/` on lower-cased text.
    private static func startsWithWord(_ text: String, _ word: String) -> Bool {
        guard text.hasPrefix(word) else { return false }
        let after = text.index(text.startIndex, offsetBy: word.count)
        return after == text.endIndex || !isWordCharacter(text[after])
    }

    /// `/\bword\b/` on lower-cased text.
    private static func containsWord(_ text: String, _ word: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func versionOf(_ name: String) -> [Int] {
        name.split(separator: ".").map { Int($0) ?? Int.max }
    }

    /// Below, at or above zero as version `a` is lower than, the same as or higher than `b`.
    static func compareVersions(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: - Families

    // Families Sarto knows, each vendor's largest first.
    private static let knownFamilies: [(vendor: String, families: [String])] = [
        ("claude", ["fable", "opus", "sonnet", "haiku"]),
        ("openai", ["astra", "sol", "terra", "luna"]),
    ]

    private static func knownFamily(_ read: ModelMenuRead) -> (vendor: String, size: Int)? {
        if read.isDefault { return nil }
        for known in knownFamilies {
            if let size = known.families.firstIndex(where: { containsWord(read.family, $0) }) {
                return (known.vendor, size)
            }
        }
        return nil
    }

    /// Sorts known families ahead, each vendor's together and largest first, the vendors in the
    /// order the agent first lists them; the other models follow in the agent's order.
    static func sortByFamily<T>(_ items: [T], read readOf: (T) -> ModelMenuRead) -> [T] {
        var firstOf: [String: Int] = [:]
        for item in items {
            let read = readOf(item)
            if let known = knownFamily(read) {
                firstOf[known.vendor] = min(firstOf[known.vendor] ?? read.order, read.order)
            }
        }
        let keyed = items.map { item -> (key: [Int], item: T) in
            let read = readOf(item)
            if let known = knownFamily(read) {
                return ([0, firstOf[known.vendor] ?? read.order, known.size, read.order], item)
            }
            return ([1, read.order, 0, 0], item)
        }
        return keyed.sorted { compareVersions($0.key, $1.key) < 0 }.map(\.item)
    }

    /// Marks the models below the newest version of their provider's family as older.
    private static func markOlder(_ reads: inout [ModelMenuRead]) {
        var families: [String: [[Int]]] = [:]
        for read in reads {
            guard let version = read.version else { continue }
            families["\(read.provider)\u{0}\(read.family)", default: []].append(version)
        }
        for index in reads.indices {
            let read = reads[index]
            if read.isDefault { continue }
            let marked = read.choice.older == true
            guard let version = read.version else {
                reads[index].older = marked
                continue
            }
            let members = families["\(read.provider)\u{0}\(read.family)"] ?? []
            let lower = members.contains { compareVersions(version, $0) < 0 }
            // The agent's own mark holds unless the versions show the model is its family's newest.
            reads[index].older = lower || (marked && members.count == 1)
        }
    }
}

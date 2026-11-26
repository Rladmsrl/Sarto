import Foundation

// Agent availability (src/shared/agent-host.ts): why a harness cannot run, how it installs, and
// what each way of installing it brings (`agents.installOffer`). Every type decodes leniently: a
// kind a newer host adds becomes `.unknown` instead of failing the whole agent status.

// MARK: - Why a harness cannot run

/// Matches `HarnessReason`. `needsNode` carries the harness's own minimum and the version found
/// (`unreadable` when `node --version` did not answer); `tooOld` the user's program's.
public enum HarnessReason: Codable, Sendable, Equatable {
    case notInstalled
    case needsNode(minimum: String?, installed: String?, unreadable: Bool)
    case needsNpm
    case needsUv(minimum: String?, installed: String?)
    case tooOld(minimum: String, installed: String?)
    case cannotRun(why: String)
    case noVersion
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .notInstalled: return "not-installed"
        case .needsNode: return "needs-node"
        case .needsNpm: return "needs-npm"
        case .needsUv: return "needs-uv"
        case .tooOld: return "too-old"
        case .cannotRun: return "cannot-run"
        case .noVersion: return "no-version"
        case .unknown(let kind): return kind
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, minimum, installed, unreadable, why
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        func text(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        switch kind {
        case "not-installed":
            self = .notInstalled
        case "needs-node":
            let unreadable = (try? c.decodeIfPresent(Bool.self, forKey: .unreadable)) ?? nil
            self = .needsNode(minimum: text(.minimum), installed: text(.installed), unreadable: unreadable == true)
        case "needs-npm":
            self = .needsNpm
        case "needs-uv":
            self = .needsUv(minimum: text(.minimum), installed: text(.installed))
        case "too-old":
            self = .tooOld(minimum: text(.minimum) ?? "", installed: text(.installed))
        case "cannot-run":
            self = .cannotRun(why: text(.why) ?? "")
        case "no-version":
            self = .noVersion
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .needsNode(let minimum, let installed, let unreadable):
            try c.encode(minimum, forKey: .minimum)
            try c.encode(installed, forKey: .installed)
            if unreadable { try c.encode(true, forKey: .unreadable) }
        case .needsUv(let minimum, let installed):
            try c.encode(minimum, forKey: .minimum)
            try c.encode(installed, forKey: .installed)
        case .tooOld(let minimum, let installed):
            try c.encode(minimum, forKey: .minimum)
            try c.encode(installed, forKey: .installed)
        case .cannotRun(let why):
            try c.encode(why, forKey: .why)
        case .notInstalled, .needsNpm, .noVersion, .unknown:
            break
        }
    }
}

/// Matches `InstalledCliProblem`: why the user's own program cannot run.
public enum InstalledCliProblem: Codable, Sendable, Equatable {
    case unsupported
    case failed(reason: String)
    case tooOld(minimum: String)
    case unknown(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind, reason, minimum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        switch kind {
        case "unsupported":
            self = .unsupported
        case "failed":
            self = .failed(reason: ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil) ?? "")
        case "too-old":
            self = .tooOld(minimum: ((try? c.decodeIfPresent(String.self, forKey: .minimum)) ?? nil) ?? "")
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unsupported:
            try c.encode("unsupported", forKey: .kind)
        case .failed(let reason):
            try c.encode("failed", forKey: .kind)
            try c.encode(reason, forKey: .reason)
        case .tooOld(let minimum):
            try c.encode("too-old", forKey: .kind)
            try c.encode(minimum, forKey: .minimum)
        case .unknown(let kind):
            try c.encode(kind, forKey: .kind)
        }
    }
}

// MARK: - Status fields about installing and running

/// Matches `AgentInstallMethod`: a way Sarto can install a harness's program, in the order it
/// prefers them. `id` is `brew`, `npm`, `script` or `archive`.
public struct AgentInstallMethodInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let command: String
    public let available: Bool

    public init(id: String, label: String, command: String, available: Bool) {
        self.id = id
        self.label = label
        self.command = command
        self.available = available
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, command, available
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.command = ((try? c.decodeIfPresent(String.self, forKey: .command)) ?? nil) ?? ""
        self.label = ((try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil) ?? command
        self.available = ((try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? nil) ?? false
    }
}

/// `AgentStatus.package`: the adapter a start runs; `isCli` for a package that is the agent's CLI
/// itself, `isSdk` for the agent's SDK, which Sarto loads itself and which runs the agent's CLI.
public struct AgentPackageInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let installed: Bool
    public let isCli: Bool
    public let isSdk: Bool

    public init(name: String, version: String, installed: Bool, isCli: Bool = false, isSdk: Bool = false) {
        self.name = name
        self.version = version
        self.installed = installed
        self.isCli = isCli
        self.isSdk = isSdk
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, installed, isCli, isSdk
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        self.version = ((try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil) ?? ""
        self.installed = ((try? c.decodeIfPresent(Bool.self, forKey: .installed)) ?? nil) ?? false
        self.isCli = ((try? c.decodeIfPresent(Bool.self, forKey: .isCli)) ?? nil) ?? false
        self.isSdk = ((try? c.decodeIfPresent(Bool.self, forKey: .isSdk)) ?? nil) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(installed, forKey: .installed)
        if isCli { try c.encode(true, forKey: .isCli) }
        if isSdk { try c.encode(true, forKey: .isSdk) }
    }
}

/// `AgentStatus.release`: Sarto's own install that a start runs, a release archive or a uvx
/// package; `registry` when the ACP Registry lists its updates.
public struct AgentReleaseInfo: Codable, Sendable, Equatable {
    public let version: String
    public let registry: Bool

    public init(version: String, registry: Bool) {
        self.version = version
        self.registry = registry
    }
}

/// `AgentStatus.program`: the harness's program as its page names it; `onPath` when Sarto looks for
/// the user's own on PATH first.
public struct AgentProgramInfo: Codable, Sendable, Equatable {
    public let command: String
    public let onPath: Bool

    public init(command: String, onPath: Bool) {
        self.command = command
        self.onPath = onPath
    }
}

/// Matches `ProviderBalance`.
public struct AgentBalanceInfo: Codable, Sendable, Equatable {
    public let label: String
    public let amount: Double
    public let currency: String

    public init(label: String, amount: Double, currency: String) {
        self.label = label
        self.amount = amount
        self.currency = currency
    }
}

/// The part of `AgentProvider['usage']` availability reads: whether it was read, and its balances.
public struct AgentUsageInfo: Codable, Sendable, Equatable {
    public let state: String
    public let balances: [AgentBalanceInfo]

    public init(state: String, balances: [AgentBalanceInfo] = []) {
        self.state = state
        self.balances = balances
    }

    private enum CodingKeys: String, CodingKey {
        case state, balances
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? "error"
        self.balances = ((try? c.decodeIfPresent([AgentBalanceInfo].self, forKey: .balances)) ?? nil) ?? []
    }
}

/// The part of `AgentProvider` availability reads: an OpenCode provider and its usage.
public struct AgentProviderUsageInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let usage: AgentUsageInfo?

    public init(id: String, name: String, usage: AgentUsageInfo?) {
        self.id = id
        self.name = name
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, usage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? id
        self.usage = (try? c.decodeIfPresent(AgentUsageInfo.self, forKey: .usage)) ?? nil
    }
}

/// The fields of an `AgentStatus` that say whether and how its harness can run and install. It
/// reads them from the status object itself, so `AgentStatusInfo` carries it without nesting on
/// the wire. An older host leaves them out: `reportsReason` is then false and the reason has to
/// be told from the state and `detail`.
public struct AgentAvailabilityInfo: Codable, Sendable, Equatable {
    /// Why it cannot run while `state` is `not-installed`, `node-missing` or `node-outdated`.
    public let reason: HarnessReason?
    /// The host sent `reason`, even as null.
    public let reportsReason: Bool
    /// The vendor installer's effects, shown before installation.
    public let installNotice: String?
    /// A binary agent's ways to install; empty for the others.
    public let installMethods: [AgentInstallMethodInfo]
    public let package: AgentPackageInfo?
    public let release: AgentReleaseInfo?
    public let program: AgentProgramInfo?
    /// The command that removes the user's own program, when its install route has one.
    public let uninstallCommand: String?
    /// A harness's balance at its vendor, read on its own (DeepSeek Harness).
    public let balance: AgentUsageInfo?
    /// The providers a harness signs in to (OpenCode), with their usage.
    public let providers: [AgentProviderUsageInfo]?

    public init(
        reason: HarnessReason? = nil,
        reportsReason: Bool = false,
        installNotice: String? = nil,
        installMethods: [AgentInstallMethodInfo] = [],
        package: AgentPackageInfo? = nil,
        release: AgentReleaseInfo? = nil,
        program: AgentProgramInfo? = nil,
        uninstallCommand: String? = nil,
        balance: AgentUsageInfo? = nil,
        providers: [AgentProviderUsageInfo]? = nil
    ) {
        self.reason = reason
        self.reportsReason = reportsReason || reason != nil
        self.installNotice = installNotice
        self.installMethods = installMethods
        self.package = package
        self.release = release
        self.program = program
        self.uninstallCommand = uninstallCommand
        self.balance = balance
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case reason, installNotice, installMethods, package, release, program, uninstallCommand
        case balance, providers
    }

    /// Never throws: a field that does not decode is left out, so the rest of the status stays.
    public init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        let reportsReason = c.contains(.reason)
        let reason: HarnessReason?
        if reportsReason, (try? c.decodeNil(forKey: .reason)) == false {
            reason = try? c.decode(HarnessReason.self, forKey: .reason)
        } else {
            reason = nil
        }
        self.init(
            reason: reason,
            reportsReason: reportsReason,
            installNotice: (try? c.decodeIfPresent(String.self, forKey: .installNotice)) ?? nil,
            installMethods: Self.lenientArray(c, .installMethods),
            package: (try? c.decodeIfPresent(AgentPackageInfo.self, forKey: .package)) ?? nil,
            release: (try? c.decodeIfPresent(AgentReleaseInfo.self, forKey: .release)) ?? nil,
            program: (try? c.decodeIfPresent(AgentProgramInfo.self, forKey: .program)) ?? nil,
            uninstallCommand: (try? c.decodeIfPresent(String.self, forKey: .uninstallCommand)) ?? nil,
            balance: (try? c.decodeIfPresent(AgentUsageInfo.self, forKey: .balance)) ?? nil,
            providers: c.contains(.providers) ? Self.lenientArray(c, .providers) : nil
        )
    }

    /// Keys the status already has are never written here, so this encodes into the status's own
    /// container beside them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if reportsReason {
            try c.encode(reason, forKey: .reason)
        }
        try c.encodeIfPresent(installNotice, forKey: .installNotice)
        if !installMethods.isEmpty {
            try c.encode(installMethods, forKey: .installMethods)
        }
        try c.encodeIfPresent(package, forKey: .package)
        try c.encodeIfPresent(release, forKey: .release)
        try c.encodeIfPresent(program, forKey: .program)
        try c.encodeIfPresent(uninstallCommand, forKey: .uninstallCommand)
        try c.encodeIfPresent(balance, forKey: .balance)
        try c.encodeIfPresent(providers, forKey: .providers)
    }

    /// The elements that decode, skipping one a newer host shapes differently.
    private static func lenientArray<T: Decodable>(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [T] {
        guard let values = (try? c.decodeIfPresent([JSONValue].self, forKey: key)) ?? nil else { return [] }
        return values.compactMap { try? $0.decode(T.self) }
    }
}

// MARK: - What an install brings (`agents.installOffer`)

/// Matches `InstallSource`: where an install downloads from.
public enum InstallSource: Codable, Sendable, Equatable {
    /// The npm registry the user's npm configuration names; nil when it could not be read.
    case npm(registry: String?)
    /// A release file the ACP Registry lists at its vendor's address.
    case registry(url: String)
    case vendor(url: String)
    case brew
    case pypi
    case unknown(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind, registry, url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        let url = ((try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil) ?? ""
        switch kind {
        case "npm": self = .npm(registry: (try? c.decodeIfPresent(String.self, forKey: .registry)) ?? nil)
        case "registry": self = .registry(url: url)
        case "vendor": self = .vendor(url: url)
        case "brew": self = .brew
        case "pypi": self = .pypi
        default: self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .npm(let registry):
            try c.encode("npm", forKey: .kind)
            try c.encode(registry, forKey: .registry)
        case .registry(let url):
            try c.encode("registry", forKey: .kind)
            try c.encode(url, forKey: .url)
        case .vendor(let url):
            try c.encode("vendor", forKey: .kind)
            try c.encode(url, forKey: .url)
        case .brew: try c.encode("brew", forKey: .kind)
        case .pypi: try c.encode("pypi", forKey: .kind)
        case .unknown(let kind): try c.encode(kind, forKey: .kind)
        }
    }
}

/// Matches `InstallNeed`: something an install needs on the computer, and whether it is there.
/// `kind` is `node`, `npm` or `uv`; only `node` carries `minimum` (the harness's own) and `found`.
public struct InstallNeed: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind }
    public let kind: String
    public let minimum: String?
    public let found: String?
    public let ok: Bool

    public init(kind: String, minimum: String? = nil, found: String? = nil, ok: Bool) {
        self.kind = kind
        self.minimum = minimum
        self.found = found
        self.ok = ok
    }

    private enum CodingKeys: String, CodingKey {
        case kind, minimum, found, ok
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil) ?? ""
        self.minimum = (try? c.decodeIfPresent(String.self, forKey: .minimum)) ?? nil
        self.found = (try? c.decodeIfPresent(String.self, forKey: .found)) ?? nil
        self.ok = ((try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if kind == "node" {
            try c.encode(minimum, forKey: .minimum)
            try c.encode(found, forKey: .found)
        }
        try c.encode(ok, forKey: .ok)
    }
}

/// `InstallDetails.what`: an npm or uvx package or a release archive by name, or a vendor's
/// command, which its route holds.
public enum InstallWhat: Codable, Sendable, Equatable {
    case package(kind: String, name: String)
    case command

    public var name: String? {
        if case .package(_, let name) = self { return name }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? "command"
        if kind != "command", let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil {
            self = .package(kind: kind, name: name)
        } else {
            self = .command
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .package(let kind, let name):
            try c.encode(kind, forKey: .kind)
            try c.encode(name, forKey: .name)
        case .command:
            try c.encode("command", forKey: .kind)
        }
    }
}

/// `InstallDetails.size`: in bytes; `packageOnly` when the package's dependencies are not counted.
public struct InstallSize: Codable, Sendable, Equatable {
    public let bytes: Double
    public let packageOnly: Bool

    public init(bytes: Double, packageOnly: Bool) {
        self.bytes = bytes
        self.packageOnly = packageOnly
    }
}

/// Matches `InstallDetails`: what one way of installing a harness brings.
public struct InstallDetails: Codable, Sendable, Equatable {
    public let what: InstallWhat
    /// Nil where the vendor's route takes its newest.
    public let version: String?
    public let source: InstallSource
    /// Nil where the route does not say, as for uv's cache or WinGet.
    public let folder: String?
    public let size: InstallSize?
    public let needs: [InstallNeed]

    public init(
        what: InstallWhat,
        version: String?,
        source: InstallSource,
        folder: String?,
        size: InstallSize?,
        needs: [InstallNeed]
    ) {
        self.what = what
        self.version = version
        self.source = source
        self.folder = folder
        self.size = size
        self.needs = needs
    }

    private enum CodingKeys: String, CodingKey {
        case what, version, source, folder, size, needs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.what = ((try? c.decodeIfPresent(InstallWhat.self, forKey: .what)) ?? nil) ?? .command
        self.version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        self.source = ((try? c.decodeIfPresent(InstallSource.self, forKey: .source)) ?? nil) ?? .unknown(kind: "")
        self.folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil
        self.size = (try? c.decodeIfPresent(InstallSize.self, forKey: .size)) ?? nil
        self.needs = ((try? c.decodeIfPresent([InstallNeed].self, forKey: .needs)) ?? nil) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(what, forKey: .what)
        try c.encode(version, forKey: .version)
        try c.encode(source, forKey: .source)
        try c.encode(folder, forKey: .folder)
        try c.encode(size, forKey: .size)
        try c.encode(needs, forKey: .needs)
    }
}

/// Matches `InstallRoute`: a way the install window offers to install a harness.
public struct InstallRoute: Codable, Sendable, Equatable, Identifiable {
    /// `copy` is Sarto's own install of the harness's npm or uvx package, which `agents.install`
    /// takes without a method; the others are its methods.
    public let id: String
    /// The command it runs, or the archive's address, quoted for the platform; nil for `copy`.
    public let command: String?
    /// The tool it runs with was found on the agent environment's PATH.
    public let available: Bool
    /// Nothing installs now: uv fetches a uvx package the first time a session starts.
    public let firstStart: Bool
    public let details: InstallDetails

    public static let copyID = "copy"

    public init(id: String, command: String?, available: Bool, firstStart: Bool = false, details: InstallDetails) {
        self.id = id
        self.command = command
        self.available = available
        self.firstStart = firstStart
        self.details = details
    }

    /// The `method` `agents.install` takes for this route; nil for Sarto's own copy.
    public var method: String? {
        id == Self.copyID ? nil : id
    }

    /// Whether the route can be installed now: its tool is there and so is all it needs.
    public var installable: Bool {
        available && !firstStart && details.needs.allSatisfy(\.ok)
    }

    private enum CodingKeys: String, CodingKey {
        case id, command, available, firstStart, details
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.command = (try? c.decodeIfPresent(String.self, forKey: .command)) ?? nil
        self.available = ((try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? nil) ?? false
        self.firstStart = ((try? c.decodeIfPresent(Bool.self, forKey: .firstStart)) ?? nil) ?? false
        self.details = try c.decode(InstallDetails.self, forKey: .details)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(command, forKey: .command)
        try c.encode(available, forKey: .available)
        if firstStart { try c.encode(true, forKey: .firstStart) }
        try c.encode(details, forKey: .details)
    }
}

/// Matches `InstallOffer`: the ways to install a harness, the recommended first.
public struct InstallOffer: Codable, Sendable, Equatable {
    public let routes: [InstallRoute]

    public init(routes: [InstallRoute]) {
        self.routes = routes
    }

    private enum CodingKeys: String, CodingKey {
        case routes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let values = ((try? c.decodeIfPresent([JSONValue].self, forKey: .routes)) ?? nil) ?? []
        self.routes = values.compactMap { try? $0.decode(InstallRoute.self) }
    }

    /// The offer an older host, which has no `agents.installOffer`, implies through the status: its
    /// vendor routes as commands, and Sarto's copy of a package that is not installed yet.
    public init(fallbackFor status: AgentStatusInfo) {
        var routes: [InstallRoute] = []
        if let pkg = status.availability.package, !pkg.installed, !pkg.isSdk {
            routes.append(InstallRoute(
                id: InstallRoute.copyID,
                command: nil,
                available: true,
                details: InstallDetails(
                    what: .package(kind: "npm", name: pkg.name),
                    version: pkg.version.isEmpty ? nil : pkg.version,
                    source: .npm(registry: nil),
                    folder: nil,
                    size: nil,
                    needs: []
                )
            ))
        }
        for method in status.availability.installMethods {
            let source: InstallSource
            switch method.id {
            case "npm": source = .npm(registry: nil)
            case "brew": source = .brew
            default: source = .vendor(url: method.command)
            }
            routes.append(InstallRoute(
                id: method.id,
                command: method.command,
                available: method.available,
                details: InstallDetails(
                    what: method.id == "archive" ? .package(kind: "archive", name: method.label) : .command,
                    version: nil,
                    source: source,
                    folder: nil,
                    size: nil,
                    needs: []
                )
            ))
        }
        self.routes = routes
    }
}

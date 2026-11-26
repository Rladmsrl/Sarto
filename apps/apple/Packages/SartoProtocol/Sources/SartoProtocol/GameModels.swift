import Foundation

// The idle game as the daemon relays it (packages/sarto-wire/src/game.ts). The app only shows what
// the game service computed and sends player commands back through the daemon.

/// The daemon's link to the game service.
public struct GameLinkStatusInfo: Sendable, Equatable {
    /// A game service is configured for this Mac.
    public var available: Bool
    /// The owner turned the game on for this Mac.
    public var optedIn: Bool
    /// Available, turned on and signed in: the game shows and this Mac's facts go to the service.
    public var enabled: Bool
    public var server: String?
    public var connected: Bool
    public var queued: Int
    /// The daemon's own words, for diagnostics; the app shows `lastErrorCode` in its own.
    public var lastError: String?
    /// `needs_tokens`, `unreachable` or `rejected`.
    public var lastErrorCode: String?
    /// The file that records every batch this Mac sent.
    public var uploadLog: String?

    public init(
        available: Bool = false,
        optedIn: Bool = false,
        enabled: Bool,
        server: String?,
        connected: Bool,
        queued: Int,
        lastError: String?,
        lastErrorCode: String? = nil,
        uploadLog: String? = nil
    ) {
        self.available = available
        self.optedIn = optedIn
        self.enabled = enabled
        self.server = server
        self.connected = connected
        self.queued = queued
        self.lastError = lastError
        self.lastErrorCode = lastErrorCode
        self.uploadLog = uploadLog
    }

    init(_ obj: [String: JSONValue]) {
        // A daemon from before the switch sends no `optedIn`; its game stays hidden.
        available = obj["available"]?.boolValue ?? false
        optedIn = obj["optedIn"]?.boolValue ?? false
        enabled = obj["enabled"]?.boolValue ?? false
        server = obj["server"]?.stringValue
        connected = obj["connected"]?.boolValue ?? false
        queued = Int(obj["queued"]?.doubleValue ?? 0)
        lastError = obj["lastError"]?.stringValue
        lastErrorCode = obj["lastErrorCode"]?.stringValue
        uploadLog = obj["uploadLog"]?.stringValue
    }
}

public struct GameCardInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var school: String
    public var tier: Int

    init?(_ obj: [String: JSONValue]) {
        guard let id = obj["id"]?.stringValue, let school = obj["school"]?.stringValue else { return nil }
        self.id = id
        self.school = school
        tier = max(1, Int(obj["tier"]?.doubleValue ?? 1))
    }
}

public struct GameWeaponInfo: Sendable, Equatable, Identifiable {
    public var id: String { harness }
    public var harness: String
    public var minutes: Int
    public var todayMinutes: Int
    public var level: Int
    public var levelMinutes: Int
    public var nextLevelMinutes: Int

    init?(_ obj: [String: JSONValue]) {
        guard let harness = obj["harness"]?.stringValue else { return nil }
        self.harness = harness
        minutes = Int(obj["minutes"]?.doubleValue ?? 0)
        todayMinutes = Int(obj["todayMinutes"]?.doubleValue ?? 0)
        level = Int(obj["level"]?.doubleValue ?? 0)
        levelMinutes = max(1, Int(obj["levelMinutes"]?.doubleValue ?? 30))
        nextLevelMinutes = max(0, Int(obj["nextLevelMinutes"]?.doubleValue ?? 30))
    }
}

public struct GamePerkInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var desc: String
    public var school: String
    public var family: String
    public var rarity: String
    public var curse: GameCurseInfo?

    init?(_ obj: [String: JSONValue]) {
        guard let id = obj["id"]?.stringValue else { return nil }
        self.id = id
        name = obj["name"]?.stringValue ?? id
        desc = obj["desc"]?.stringValue ?? ""
        school = obj["school"]?.stringValue ?? "review"
        family = obj["family"]?.stringValue ?? "package"
        rarity = obj["rarity"]?.stringValue ?? "common"
        curse = obj["curse"]?.objectValue.flatMap(GameCurseInfo.init)
    }
}

public struct GameCurseInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var desc: String

    init?(_ obj: [String: JSONValue]) {
        guard let id = obj["id"]?.stringValue else { return nil }
        self.id = id
        name = obj["name"]?.stringValue ?? id
        desc = obj["desc"]?.stringValue ?? ""
    }
}

public struct GameSetInfo: Sendable, Equatable, Identifiable {
    public var id: String { "\(axis):\(key)" }
    public var key: String
    public var axis: String
    public var name: String
    public var desc: String
    public var count: Int
    public var active: Bool

    init?(_ obj: [String: JSONValue]) {
        guard let key = obj["key"]?.stringValue, let axis = obj["axis"]?.stringValue else { return nil }
        self.key = key
        self.axis = axis
        name = obj["name"]?.stringValue ?? key
        desc = obj["desc"]?.stringValue ?? ""
        count = Int(obj["count"]?.doubleValue ?? 0)
        active = obj["active"]?.boolValue ?? false
    }
}

public struct GameOfferInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var at: Double
    public var options: [GamePerkInfo]
    public var recommended: Int
    public var autoAt: Double

    init?(_ obj: [String: JSONValue]) {
        guard let id = obj["id"]?.stringValue else { return nil }
        self.id = id
        at = obj["at"]?.doubleValue ?? 0
        options = obj["options"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GamePerkInfo.init) } ?? []
        recommended = Int(obj["recommended"]?.doubleValue ?? 0)
        autoAt = obj["autoAt"]?.doubleValue ?? 0
    }
}

public struct GameBossResultInfo: Sendable, Equatable {
    public var won: Bool
    public var power: Int
    public var required: Int
    public var durationMs: Int
    public var bossHp: Int
    public var damageDealt: Int
    public var perfect: Int
    public var advice: [String]

    init(_ obj: [String: JSONValue]) {
        won = obj["won"]?.boolValue ?? false
        power = Int(obj["power"]?.doubleValue ?? 0)
        required = Int(obj["required"]?.doubleValue ?? 0)
        durationMs = Int(obj["durationMs"]?.doubleValue ?? 0)
        bossHp = max(1, Int(obj["bossHp"]?.doubleValue ?? 1))
        damageDealt = Int(obj["damageDealt"]?.doubleValue ?? 0)
        perfect = Int(obj["perfect"]?.doubleValue ?? 0)
        advice = obj["advice"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

public struct GameReportInfo: Sendable, Equatable {
    public var xp: Int
    public var bonusXp: Int
    public var compute: Int
    public var kills: Int
    public var stagesCleared: Int
    public var activeMinutes: Int
    public var inactiveMinutes: Int
    public var offlineMinutes: Int
    public var drops: [String]
    public var picks: [String]

    init(_ obj: [String: JSONValue]) {
        xp = Int(obj["xp"]?.doubleValue ?? 0)
        bonusXp = Int(obj["bonusXp"]?.doubleValue ?? 0)
        compute = Int(obj["compute"]?.doubleValue ?? 0)
        kills = Int(obj["kills"]?.doubleValue ?? 0)
        stagesCleared = Int(obj["stagesCleared"]?.doubleValue ?? 0)
        let mins = obj["minutesByState"]?.objectValue ?? [:]
        activeMinutes = Int(mins["active"]?.doubleValue ?? 0)
        inactiveMinutes = Int(mins["inactive"]?.doubleValue ?? 0)
        offlineMinutes = Int(mins["offline"]?.doubleValue ?? 0)
        drops = obj["drops"]?.arrayValue?.compactMap(\.stringValue) ?? []
        picks = obj["picks"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

public struct GameMarketItemInfo: Sendable, Equatable, Identifiable {
    public var id: Int
    public var kind: String
    public var perk: GamePerkInfo?
    public var price: Int
    public var sold: Bool

    init(_ obj: [String: JSONValue], index: Int) {
        id = index
        kind = obj["kind"]?.stringValue ?? "perk"
        perk = obj["perk"]?.objectValue.flatMap(GamePerkInfo.init)
        price = Int(obj["price"]?.doubleValue ?? 0)
        sold = obj["sold"]?.boolValue ?? false
    }
}

public struct GameRunResultInfo: Sendable, Equatable {
    public var won: Bool
    public var nodesCleared: Int
    public var compute: Int
    public var materials: [String: Int]
    public var card: GameCardInfo?
    public var dailyFactor: Double
    public var curseBonus: Double
    public var memoryChoices: [GamePerkInfo]

    init(_ obj: [String: JSONValue]) {
        won = obj["won"]?.boolValue ?? false
        nodesCleared = Int(obj["nodesCleared"]?.doubleValue ?? 0)
        compute = Int(obj["compute"]?.doubleValue ?? 0)
        var mats: [String: Int] = [:]
        for (k, v) in obj["materials"]?.objectValue ?? [:] {
            mats[k] = Int(v.doubleValue ?? 0)
        }
        materials = mats
        card = obj["card"]?.objectValue.flatMap(GameCardInfo.init)
        dailyFactor = obj["dailyFactor"]?.doubleValue ?? 1
        curseBonus = obj["curseBonus"]?.doubleValue ?? 0
        memoryChoices = obj["memoryChoices"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GamePerkInfo.init) } ?? []
    }
}

public struct GameRunInfo: Sendable, Equatable {
    public var env: Int
    public var envName: String
    public var leg: Int
    public var legs: Int
    public var step: Int
    public var steps: Int
    public var status: String
    public var node: String?
    public var paths: [String]
    public var credits: Int
    public var perks: [GamePerkInfo]
    public var curses: [GameCurseInfo]
    public var sets: [GameSetInfo]
    public var power: Int
    public var rewardOptions: [GamePerkInfo]
    public var skipCredits: Int
    public var market: [GameMarketItemInfo]
    public var espresso: Bool
    public var fightRemaining: Int?
    public var fightTotal: Int?
    public var fightDeadline: Double?
    public var boss: GameTarget?
    public var bossPhase: String?
    public var result: GameRunResultInfo?

    init(_ obj: [String: JSONValue]) {
        env = Int(obj["env"]?.doubleValue ?? 0)
        envName = obj["envName"]?.stringValue ?? "localhost"
        leg = Int(obj["leg"]?.doubleValue ?? 0)
        legs = max(1, Int(obj["legs"]?.doubleValue ?? 3))
        step = Int(obj["step"]?.doubleValue ?? 0)
        steps = max(1, Int(obj["steps"]?.doubleValue ?? 4))
        status = obj["status"]?.stringValue ?? "choosing"
        node = obj["node"]?.stringValue
        paths = obj["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        credits = Int(obj["credits"]?.doubleValue ?? 0)
        perks = obj["perks"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GamePerkInfo.init) } ?? []
        curses = obj["curses"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GameCurseInfo.init) } ?? []
        sets = obj["sets"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GameSetInfo.init) } ?? []
        power = Int(obj["power"]?.doubleValue ?? 0)
        let reward = obj["reward"]?.objectValue
        rewardOptions = reward?["options"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GamePerkInfo.init) } ?? []
        skipCredits = Int(reward?["skipCredits"]?.doubleValue ?? 20)
        market = (obj["market"]?.arrayValue ?? []).enumerated().compactMap { idx, val in
            val.objectValue.map { GameMarketItemInfo($0, index: idx) }
        }
        espresso = obj["espresso"]?.boolValue ?? false
        if let f = obj["fight"]?.objectValue {
            fightRemaining = Int(f["remaining"]?.doubleValue ?? 0)
            fightTotal = max(1, Int(f["total"]?.doubleValue ?? 1))
            fightDeadline = f["deadline"]?.doubleValue
        } else {
            fightRemaining = nil
            fightTotal = nil
            fightDeadline = nil
        }
        if let b = obj["boss"]?.objectValue {
            boss = GameTarget(b, name: b["name"]?.stringValue ?? "429-colossus")
            bossPhase = b["phase"]?.stringValue
        } else {
            boss = nil
            bossPhase = nil
        }
        result = obj["result"]?.objectValue.map(GameRunResultInfo.init)
    }
}

public struct GameHackathonInfo: Sendable, Equatable {
    public struct EnvEntry: Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String
        public var unlocked: Bool
    }
    public var envs: [EnvEntry]
    public var runsToday: Int
    public var fullRuns: Int
    public var memory: GamePerkInfo?
    public var run: GameRunInfo?

    init(_ obj: [String: JSONValue]) {
        envs = (obj["envs"]?.arrayValue ?? []).enumerated().compactMap { idx, item in
            guard let o = item.objectValue, let name = o["name"]?.stringValue else { return nil }
            return EnvEntry(id: idx, name: name, unlocked: o["unlocked"]?.boolValue ?? false)
        }
        runsToday = Int(obj["runsToday"]?.doubleValue ?? 0)
        fullRuns = max(1, Int(obj["fullRuns"]?.doubleValue ?? 3))
        memory = obj["memory"]?.objectValue.flatMap(GamePerkInfo.init)
        run = obj["run"]?.objectValue.map(GameRunInfo.init)
    }
}

/// A reading of the game clock. Every frame carries a new one, so it takes no part in equality:
/// two states that differ only in it are the same state.
@propertyWrapper
public struct GameClockReading: Sendable, Equatable {
    public var wrappedValue: Double

    public init(wrappedValue: Double) {
        self.wrappedValue = wrappedValue
    }

    public static func == (_: Self, _: Self) -> Bool { true }
}

/// The game state the app draws and acts upon.
public struct GameStateInfo: Sendable, Equatable {
    public var revision: Int
    @GameClockReading public var serverNow: Double = 0
    public var heroName: String
    public var version: String
    public var level: Int
    public var xp: Int
    public var xpNext: Int
    public var compute: Int
    /// `active`, `inactive` or `offline`.
    public var accountState: String
    public var online: Bool
    public var basePower: Int
    public var proficiencyBonus: Double
    public var cardsBonus: Double
    public var synergyBonus: Double
    public var synergyMode: String
    public var totalPower: Int
    public var power: Int
    public var mainWeapon: String?
    public var slotCount: Int
    public var slots: [GameCardInfo?]
    public var cards: [GameCardInfo]
    public var materials: [String: Int]
    public var weapons: [GameWeaponInfo]
    public var chapter: Int
    public var stage: Int
    public var kills: Int
    public var killsNeeded: Int
    public var stageRequired: Int
    public var stuck: Bool
    public var bossReady: Bool
    public var bossDefeated: Bool
    public var perks: [GamePerkInfo]
    public var sets: [GameSetInfo]
    public var offers: [GameOfferInfo]
    public var pendingOffers: Int { offers.count }
    public var perkCount: Int { perks.count }
    public var policyKind: String
    public var policyValue: String?
    public var monster: GameTarget?
    public var boss: GameTarget?
    public var bossPhase: String?
    public var bossEnrageAt: Double?
    public var ult: Int
    public var ultMax: Int
    public var ultManual: Bool
    public var lastBoss: GameBossResultInfo?
    public var hackathon: GameHackathonInfo
    /// A Hackathon run's status, when one is open.
    public var runStatus: String? { hackathon.run?.status }
    /// Active target inside a Hackathon fight, so joining mid-fight still draws it.
    public var runTarget: GameTarget?
    public var todoRewardsToday: Int
    public var todoCap: Int
    public var craftRandomCost: Int
    public var craftTargetedCost: Int
    public var titles: [String]
    public var pendingReport: GameReportInfo

    init?(_ obj: [String: JSONValue]) {
        guard let hero = obj["hero"]?.objectValue else { return nil }
        revision = Int(obj["revision"]?.doubleValue ?? 0)
        serverNow = obj["serverNow"]?.doubleValue ?? 0
        heroName = hero["name"]?.stringValue ?? "Vibe Coder"
        version = hero["version"]?.stringValue ?? "v0.1"
        level = Int(hero["level"]?.doubleValue ?? 1)
        xp = Int(hero["xp"]?.doubleValue ?? 0)
        xpNext = max(1, Int(hero["xpNext"]?.doubleValue ?? 1))
        compute = Int(hero["compute"]?.doubleValue ?? 0)
        let acc = obj["account"]?.objectValue ?? [:]
        accountState = acc["state"]?.stringValue ?? "offline"
        online = acc["online"]?.boolValue ?? false

        let p = obj["power"]?.objectValue ?? [:]
        basePower = Int(p["base"]?.doubleValue ?? 100)
        proficiencyBonus = p["proficiency"]?.doubleValue ?? 0
        cardsBonus = p["cards"]?.doubleValue ?? 0
        synergyBonus = p["variety"]?.doubleValue ?? 0
        synergyMode = p["synergyMode"]?.stringValue ?? "none"
        totalPower = Int(p["total"]?.doubleValue ?? 100)
        power = Int(p["effective"]?.doubleValue ?? 0)

        mainWeapon = obj["main"]?.stringValue
        slotCount = max(1, Int(obj["slotCount"]?.doubleValue ?? 1))
        slots = (obj["slots"]?.arrayValue ?? []).map { $0.objectValue.flatMap(GameCardInfo.init) }
        cards = obj["cards"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GameCardInfo.init) } ?? []
        var mats: [String: Int] = [:]
        for (k, v) in obj["materials"]?.objectValue ?? [:] {
            mats[k] = Int(v.doubleValue ?? 0)
        }
        materials = mats
        weapons = obj["weapons"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GameWeaponInfo.init) } ?? []

        let stageObj = obj["stage"]?.objectValue ?? [:]
        chapter = Int(stageObj["chapter"]?.doubleValue ?? 1)
        stage = Int(stageObj["stage"]?.doubleValue ?? 1)
        kills = Int(stageObj["kills"]?.doubleValue ?? 0)
        killsNeeded = max(1, Int(stageObj["killsNeeded"]?.doubleValue ?? 20))
        stageRequired = Int(stageObj["required"]?.doubleValue ?? 100)
        stuck = stageObj["stuck"]?.boolValue ?? false
        bossReady = stageObj["bossReady"]?.boolValue ?? false
        bossDefeated = stageObj["bossDefeated"]?.boolValue ?? false

        perks = obj["perks"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GamePerkInfo.init) } ?? []
        sets = obj["sets"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GameSetInfo.init) } ?? []
        offers = obj["offers"]?.arrayValue?.compactMap { $0.objectValue.flatMap(GameOfferInfo.init) } ?? []
        let pol = obj["policy"]?.objectValue ?? [:]
        policyKind = pol["kind"]?.stringValue ?? "recommended"
        policyValue = pol["value"]?.stringValue

        let battle = obj["battle"]?.objectValue ?? [:]
        monster = battle["monster"]?.objectValue.map { GameTarget($0) }
        if let b = battle["boss"]?.objectValue {
            boss = GameTarget(b, name: "merge-conflict-hydra")
            bossPhase = b["phase"]?.stringValue
            bossEnrageAt = b["enrageAt"]?.doubleValue
        } else {
            boss = nil
            bossPhase = nil
            bossEnrageAt = nil
        }
        ult = Int(battle["ult"]?.doubleValue ?? 0)
        ultMax = max(1, Int(battle["ultMax"]?.doubleValue ?? 20))
        ultManual = battle["ultManual"]?.boolValue ?? false
        lastBoss = obj["lastBoss"]?.objectValue.map(GameBossResultInfo.init)

        hackathon = GameHackathonInfo(obj["hackathon"]?.objectValue ?? [:])
        if let run = hackathon.run {
            if let rb = run.boss {
                runTarget = rb
            } else if let rem = run.fightRemaining, let tot = run.fightTotal, run.status == "fighting" {
                let elite = run.node == "elite"
                runTarget = GameTarget(name: elite ? "flaky-test" : "null-pointer", hp: max(1, rem), maxHp: max(1, tot), elite: elite)
            } else {
                runTarget = nil
            }
        } else {
            runTarget = nil
        }

        let today = obj["today"]?.objectValue ?? [:]
        todoRewardsToday = Int(today["todoRewards"]?.doubleValue ?? 0)
        todoCap = max(1, Int(today["todoCap"]?.doubleValue ?? 20))
        let craft = obj["craftCost"]?.objectValue ?? [:]
        craftRandomCost = Int(craft["random"]?.doubleValue ?? 120)
        craftTargetedCost = Int(craft["targeted"]?.doubleValue ?? 180)
        titles = obj["titles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        pendingReport = GameReportInfo(obj["pendingReport"]?.objectValue ?? [:])
    }
}

public struct GameTarget: Sendable, Equatable {
    public var name: String
    public var hp: Int
    public var maxHp: Int
    public var elite: Bool

    public init(name: String, hp: Int, maxHp: Int, elite: Bool) {
        self.name = name
        self.hp = hp
        self.maxHp = max(1, maxHp)
        self.elite = elite
    }

    init(_ obj: [String: JSONValue], name: String? = nil) {
        self.name = obj["name"]?.stringValue ?? name ?? ""
        hp = Int(obj["hp"]?.doubleValue ?? 0)
        maxHp = max(1, Int(obj["maxHp"]?.doubleValue ?? 1))
        elite = obj["elite"]?.boolValue ?? (name != nil)
    }
}

/// One thing that happened in a battle, at its game time.
public struct GameBattleEvent: Sendable, Equatable {
    public var at: Double
    public var kind: String
    public var damage: Int?
    public var crit: Bool
    public var perfect: Bool
    public var hp: Int?
    public var maxHp: Int?
    public var monster: String?
    public var elite: Bool
    /// `main` or `run` (a Hackathon run).
    public var lane: String
    public var ult: Int?
    public var text: String?
    public var bossResult: GameBossResultInfo?

    init?(_ value: JSONValue) {
        guard let obj = value.objectValue, let kind = obj["kind"]?.stringValue,
              let at = obj["at"]?.doubleValue else { return nil }
        self.at = at
        self.kind = kind
        damage = obj["damage"]?.doubleValue.map { Int($0) }
        crit = obj["crit"]?.boolValue ?? false
        perfect = obj["perfect"]?.boolValue ?? false
        hp = obj["hp"]?.doubleValue.map { Int($0) }
        maxHp = obj["maxHp"]?.doubleValue.map { Int($0) }
        monster = obj["monster"]?.stringValue
        elite = obj["elite"]?.boolValue ?? false
        lane = obj["lane"]?.stringValue ?? "main"
        ult = obj["ult"]?.doubleValue.map { Int($0) }
        text = obj["text"]?.stringValue
        bossResult = obj["result"]?.objectValue.map(GameBossResultInfo.init)
    }
}

public struct GameCommandOutcome: Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var state: GameStateInfo?
    public var report: GameReportInfo?

    public init(_ value: JSONValue) {
        let obj = value.objectValue ?? [:]
        ok = obj["ok"]?.boolValue ?? false
        error = obj["error"]?.stringValue
        state = obj["state"]?.objectValue.flatMap(GameStateInfo.init)
        report = obj["report"]?.objectValue.map(GameReportInfo.init)
    }
}

public enum GameFrame: Sendable, Equatable {
    case state(GameStateInfo)
    case battle([GameBattleEvent])
    case notice(key: String, text: String)
    case other(type: String)
}

extension HostEvent {
    static func gameEvent(type: String, _ obj: [String: JSONValue]) -> HostEvent {
        if type == "game.status" {
            return .gameStatus(GameLinkStatusInfo(obj["status"]?.objectValue ?? [:]))
        }
        guard let frame = obj["frame"]?.objectValue, let frameType = frame["type"]?.stringValue else {
            return .unknown(type: type)
        }
        switch frameType {
        case "state", "hello":
            if let state = frame["state"]?.objectValue.flatMap(GameStateInfo.init) {
                return .gameFrame(.state(state))
            }
        case "battle":
            let events = frame["events"]?.arrayValue?.compactMap(GameBattleEvent.init) ?? []
            return .gameFrame(.battle(events))
        case "notice":
            return .gameFrame(.notice(
                key: frame["key"]?.stringValue ?? "",
                text: frame["text"]?.stringValue ?? ""
            ))
        default:
            break
        }
        return .gameFrame(.other(type: frameType))
    }

    /// Decodes the answer to `game.subscribe`.
    public static func gameSubscription(_ value: JSONValue) -> (GameLinkStatusInfo, GameStateInfo?) {
        let obj = value.objectValue ?? [:]
        let status = GameLinkStatusInfo(obj["status"]?.objectValue ?? [:])
        let state = obj["state"]?.objectValue.flatMap(GameStateInfo.init)
        return (status, state)
    }
}

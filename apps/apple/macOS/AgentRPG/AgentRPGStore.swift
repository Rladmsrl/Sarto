import AppKit
import Foundation
import Observation
import SartoProtocol

/// Local-only idle RPG engine and JSON store for Sarto agents.
///
/// - Starts every agent cleanly at Lv.1 and accumulates real XP, 8-stat mastery, gear drops,
///   achievements, and Sarto Commander bond from the work facts hosts send (`work.facts`) while
///   Arcade mode is on.
/// - Persists asynchronously off the main thread to `~/Library/Application Support/Sarto/agent-rpg-v1.json`.
@MainActor
@Observable
final class AgentRPGStore {
    private(set) var commander = SartoCommanderProfile()
    private(set) var profiles: [String: AgentRPGProfile] = [:]
    var showDamageNumbers: Bool = true {
        didSet {
            if showDamageNumbers != oldValue {
                scheduleSave()
            }
        }
    }

    /// Ephemeral visual timers (not persisted to disk).
    private(set) var commanderBuffUntilByAgent: [String: Date] = [:]
    private(set) var lastLevelUpAtByAgent: [String: Date] = [:]
    private(set) var lastLootBannerByAgent: [String: (textZH: String, textEN: String, colorHex: UInt32, at: Date)] = [:]

    /// Running sessions across the hosts, as the island last counted them.
    private var runningSessions = 0
    /// The facts applied lately, so one delivered twice counts once.
    private var seenFactIDs: Set<String> = []
    private var seenFactOrder: [String] = []
    private static let rememberedFacts = 512
    @ObservationIgnored private var factsBeforeLoad: [(
        facts: [WorkFact],
        identity: (String) -> (name: String, harness: String)?,
        now: Date
    )] = []
    private var hasLoadedFromDisk = false
    nonisolated(unsafe) private var pendingSaveTask: Task<Void, Never>?
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?
    private var rngState: UInt64 = UInt64(Date().timeIntervalSinceReferenceDate * 1000) ^ 0xA5E7_8B1C_5A27_0001

    static let forgeCost = 100
    static let reforgeCost = 60

    init() {
        loadFromDiskAsync()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSaveSyncOnTerminate()
            }
        }
    }

    deinit {
        pendingSaveTask?.cancel()
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    nonisolated static func storageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sarto", isDirectory: true).appendingPathComponent("agent-rpg-v1.json")
    }

    // MARK: - Profile Accessors & Battle Loadout

    func profile(for agent: IslandAgentIdentity) -> AgentRPGProfile {
        if let existing = profiles[agent.id] {
            return existing
        }
        return AgentRPGProfile(agentId: agent.id, displayName: agent.name, harness: agent.harness)
    }

    func ensureProfile(agentId: String, displayName: String, harness: String) -> AgentRPGProfile {
        if var existing = profiles[agentId] {
            if existing.displayName != displayName || existing.harness != harness {
                existing.displayName = displayName
                existing.harness = harness
                profiles[agentId] = existing
            }
            return existing
        }
        let created = AgentRPGProfile(agentId: agentId, displayName: displayName, harness: harness)
        profiles[agentId] = created
        return created
    }

    func stats(for agentId: String) -> AgentRPGStats {
        let prof = profiles[agentId] ?? AgentRPGProfile(agentId: agentId, displayName: agentId, harness: agentId)
        return prof.computeStats(commander: commander)
    }

    func isCommanderBuffActive(for agentId: String, now: Date = Date()) -> Bool {
        guard let until = commanderBuffUntilByAgent[agentId] else { return false }
        return until > now
    }

    func didRecentlyLevelUp(_ agentId: String, now: Date = Date()) -> Bool {
        guard let at = lastLevelUpAtByAgent[agentId] else { return false }
        return now.timeIntervalSince(at) < 6.0
    }

    func loadout(for agent: IslandAgentIdentity, enabled: Bool, now: Date = Date()) -> AgentBattleLoadout {
        guard enabled else { return .disabled }
        let prof = profile(for: agent)
        let computed = prof.computeStats(commander: commander)
        let skills = Set(AgentSkillKind.allCases.filter {
            $0.isUnlocked(agentLevel: prof.level, bondLevel: prof.bondLevel)
        })
        return AgentBattleLoadout(
            enabled: true,
            showDamageNumbers: showDamageNumbers,
            level: prof.level,
            bondLevel: prof.bondLevel,
            weapon: prof.activeWeapon,
            headgear: prof.activeHeadgear,
            aura: prof.activeAura,
            finisher: prof.activeFinisher,
            stats: computed,
            unlockedSkills: skills,
            commanderBuffActive: isCommanderBuffActive(for: agent.id, now: now),
            justLeveledUp: didRecentlyLevelUp(agent.id, now: now)
        )
    }

    // MARK: - Work Facts (Real Work -> XP, Mastery, Loot, Achievements)

    /// Applies the facts a host tells of its own sessions' work (`work.facts`). Each host tells
    /// only of the sessions it runs, so work seen from several hosts' windows is counted once.
    func apply(
        _ facts: [WorkFact],
        identity: @escaping (String) -> (name: String, harness: String)?,
        now: Date = Date()
    ) {
        // Facts that come before the save is read wait for it, or the save would overwrite them.
        guard hasLoadedFromDisk else {
            if factsBeforeLoad.count < Self.rememberedFacts {
                factsBeforeLoad.append((facts, identity, now))
            }
            return
        }
        var applied = false
        for fact in facts where remember(fact.id) {
            if case .unknown = fact.kind { continue }
            let who = identity(fact.agentId)
            var prof = ensureProfile(
                agentId: fact.agentId,
                displayName: who?.name ?? fact.agentId,
                harness: who?.harness ?? fact.agentId
            )
            apply(fact, to: &prof, now: now)
            _ = evaluateAchievements(on: &prof, concurrentSessions: runningSessions, now: now)
            profiles[prof.agentId] = prof
            applied = true
        }
        if applied {
            scheduleSave()
        }
    }

    /// The running sessions the island counts across the hosts, for the concurrency records.
    func noteConcurrency(running: Int) {
        runningSessions = running
        guard running > commander.maxConcurrentSessions else { return }
        commander.maxConcurrentSessions = running
        scheduleSave()
    }

    /// The selected session's live output speed and prompt cache hit rate, for its agent's records.
    func recordTelemetry(agentId: String, tps: Double?, cacheHit: Double?, now: Date = Date()) {
        guard hasLoadedFromDisk, var prof = profiles[agentId] else { return }
        var improved = false
        if let tps, tps > prof.peakTPS {
            prof.peakTPS = tps
            improved = true
        }
        if let cacheHit {
            prof.recentCacheHit = cacheHit
            if cacheHit > prof.bestCacheHit {
                prof.bestCacheHit = cacheHit
                improved = true
            }
        }
        if improved {
            _ = evaluateAchievements(on: &prof, concurrentSessions: runningSessions, now: now)
        }
        guard prof != profiles[agentId] else { return }
        profiles[agentId] = prof
        if improved {
            scheduleSave()
        }
    }

    /// False for a fact already applied.
    private func remember(_ id: String) -> Bool {
        guard seenFactIDs.insert(id).inserted else { return false }
        seenFactOrder.append(id)
        if seenFactOrder.count > Self.rememberedFacts {
            seenFactIDs.remove(seenFactOrder.removeFirst())
        }
        return true
    }

    private func apply(_ fact: WorkFact, to prof: inout AgentRPGProfile, now: Date) {
        let nowSec = now.timeIntervalSince1970
        let statsBefore = prof.computeStats(commander: commander)

        switch fact.kind {
        case .active(let seconds, let work, let child):
            guard seconds > 0 else { return }
            prof.activeSeconds += Double(seconds)
            switch work {
            case .think: prof.thinkTicks += seconds
            case .scan: prof.scanTicks += seconds
            case .command: prof.commandTicks += seconds
            case .edit: prof.editTicks += seconds
            }
            if child {
                prof.subagentAssists += seconds
            }
            let xp = Int((Double(seconds) * 2.0 * statsBefore.xpBonusMultiplier * prof.cacheBonusMultiplier).rounded())
            let lvGain = prof.addXP(max(1, xp))
            if lvGain > 0 {
                recordLevelUp(profile: &prof, gained: lvGain, now: now)
            }
            // The rates of the one-second ticks this replaced: one bond and one commander XP a second.
            _ = prof.addBondXP(seconds)
            _ = commander.addXP(max(seconds, xp / 4))

        case .permissionGranted:
            prof.approvalsGranted += 1
            commander.totalApprovals += 1
            commanderBuffUntilByAgent[prof.agentId] = now.addingTimeInterval(8.5)
            let gainXP = Int((60.0 * statsBefore.xpBonusMultiplier).rounded())
            let lvGain = prof.addXP(gainXP)
            _ = prof.addBondXP(18)
            _ = commander.addXP(20)
            prof.pushEvent(
                icon: "bolt.shield.fill",
                accentHex: 0xFBBF24,
                zh: "指挥官授权鼓舞！+\(gainXP) XP · 8秒全员狂暴",
                en: "Commander Buff! +\(gainXP) XP · 8s overdrive",
                now: nowSec
            )
            if lvGain > 0 {
                recordLevelUp(profile: &prof, gained: lvGain, now: now)
            }
            unlockAchievement(.commandersDecree, on: &prof, now: now)

        case .todoCompleted(let cleared):
            guard cleared > 0 else { return }
            prof.todosCleared += cleared
            commander.totalTodosCommanded += cleared
            prof.combo += cleared
            if prof.combo > prof.bestCombo { prof.bestCombo = prof.combo }

            let mult = prof.comboMultiplier * prof.cacheBonusMultiplier * statsBefore.xpBonusMultiplier
            let xpReward = Int((Double(120 * cleared) * mult).rounded())
            let dustReward = Int((Double(18 * cleared) * statsBefore.stardustBonusMultiplier).rounded())
            prof.stardust += dustReward
            let lvGain = prof.addXP(xpReward)
            _ = prof.addBondXP(12 * cleared)
            _ = commander.addXP(max(10, xpReward / 4))

            prof.pushEvent(
                icon: "target",
                accentHex: 0x34D399,
                zh: "击破 Todo ×\(cleared) · +\(xpReward) XP · +\(dustReward) ✦",
                en: "Cleared Todo ×\(cleared) · +\(xpReward) XP · +\(dustReward) ✦",
                now: nowSec
            )
            if lvGain > 0 {
                recordLevelUp(profile: &prof, gained: lvGain, now: now)
            }

            // Night Owl: a step cleared between 01:00 and 05:00 where the work ran.
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: fact.at / 1000))
            if hour >= 1 && hour < 5 {
                unlockAchievement(.nightOwl, on: &prof, now: now)
            }

            // Loot roll on Todo kill (35% base + LUK scaling)
            let dropChance = min(0.75, 0.35 + Double(statsBefore.luk) * 0.004)
            if nextUnit() < dropChance {
                let gear = rollGear(level: prof.level, luk: statsBefore.luk, guaranteedMinRarity: nil, now: nowSec)
                grantLoot(gear, to: &prof, now: now)
            }

        case .planCompleted(let steps):
            let stepsCount = max(1, steps)
            prof.plansCleared += 1
            commander.totalPlansCommanded += 1
            let mult = prof.comboMultiplier * prof.cacheBonusMultiplier * statsBefore.xpBonusMultiplier
            let bossXP = Int((Double(350 + 50 * stepsCount) * mult).rounded())
            let bossDust = Int((Double(55 + 10 * stepsCount) * statsBefore.stardustBonusMultiplier).rounded())
            prof.stardust += bossDust
            let lvGain = prof.addXP(bossXP)
            _ = prof.addBondXP(30)
            _ = commander.addXP(max(40, bossXP / 4))

            prof.pushEvent(
                icon: "crown.fill",
                accentHex: 0xFBBF24,
                zh: "计划全清！Boss 奖励 +\(bossXP) XP · +\(bossDust) ✦",
                en: "Plan Cleared! Boss +\(bossXP) XP · +\(bossDust) ✦",
                now: nowSec
            )
            if lvGain > 0 {
                recordLevelUp(profile: &prof, gained: lvGain, now: now)
            }

            // Guaranteed Uncommon+ Boss gear drop!
            let bossGear = rollGear(level: prof.level, luk: statsBefore.luk + 12, guaranteedMinRarity: .uncommon, now: nowSec)
            grantLoot(bossGear, to: &prof, now: now)

        case .turnEnded(let ok):
            guard ok else {
                prof.combo = 0
                return
            }
            prof.turnsCompleted += 1
            prof.combo += 1
            if prof.combo > prof.bestCombo { prof.bestCombo = prof.combo }
            let mult = prof.comboMultiplier * prof.cacheBonusMultiplier * statsBefore.xpBonusMultiplier
            let turnXP = Int((45.0 * mult).rounded())
            let dust = Int((8.0 * statsBefore.stardustBonusMultiplier).rounded())
            prof.stardust += dust
            let lvGain = prof.addXP(turnXP)
            _ = prof.addBondXP(8)
            _ = commander.addXP(max(8, turnXP / 4))
            if lvGain > 0 {
                recordLevelUp(profile: &prof, gained: lvGain, now: now)
            }

        case .unknown:
            break
        }
    }

    /// Accumulates cosmetic battlefield damage counters (batched from Canvas without triggering view rebuilds).
    func recordCombatDamage(agentId: String, damage: Int, isCrit: Bool) {
        guard var prof = profiles[agentId] else { return }
        prof.totalDamageDealt += Int64(damage)
        if isCrit { prof.totalCrits += 1 }
        profiles[agentId] = prof
    }

    // MARK: - Interactive Character Card Actions (Transmog, Gear, Forge, Reforge)

    func selectWeapon(_ weapon: AgentWeaponKind?, for agentId: String) {
        guard var prof = profiles[agentId] else { return }
        if let weapon, prof.level < weapon.unlockLevel { return }
        prof.selectedWeapon = weapon
        profiles[agentId] = prof
        scheduleSave()
    }

    func selectHeadgear(_ headgear: AgentHeadgear?, for agentId: String) {
        guard var prof = profiles[agentId] else { return }
        if let headgear, prof.level < headgear.unlockLevel { return }
        prof.selectedHeadgear = headgear
        profiles[agentId] = prof
        scheduleSave()
    }

    func selectAura(_ aura: AgentAura?, for agentId: String) {
        guard var prof = profiles[agentId] else { return }
        if let aura, prof.level < aura.unlockLevel { return }
        prof.selectedAura = aura
        profiles[agentId] = prof
        scheduleSave()
    }

    func selectFinisher(_ finisher: AgentFinisherFX?, for agentId: String) {
        guard var prof = profiles[agentId] else { return }
        if let finisher, prof.level < finisher.unlockLevel { return }
        prof.selectedFinisher = finisher
        profiles[agentId] = prof
        scheduleSave()
    }

    func equipGear(itemId: String, for agentId: String) {
        guard var prof = profiles[agentId],
              let idx = prof.backpack.firstIndex(where: { $0.id == itemId })
        else { return }
        let item = prof.backpack.remove(at: idx)
        if let previous = prof.equipped[item.slot.rawValue] {
            prof.backpack.insert(previous, at: 0)
        }
        prof.equipped[item.slot.rawValue] = item
        profiles[agentId] = prof
        scheduleSave()
    }

    func unequipGear(slot: AgentGearSlot, for agentId: String) {
        guard var prof = profiles[agentId],
              let item = prof.equipped.removeValue(forKey: slot.rawValue)
        else { return }
        prof.backpack.insert(item, at: 0)
        profiles[agentId] = prof
        scheduleSave()
    }

    func dismantleGear(itemId: String, for agentId: String) {
        guard var prof = profiles[agentId],
              let idx = prof.backpack.firstIndex(where: { $0.id == itemId })
        else { return }
        let removed = prof.backpack.remove(at: idx)
        prof.stardust += removed.rarity.dismantleStardust
        profiles[agentId] = prof
        scheduleSave()
    }

    @discardableResult
    func dismantleLowTierGear(maxRarity: AgentGearRarity = .uncommon, for agentId: String) -> Int {
        guard var prof = profiles[agentId] else { return 0 }
        var dust = 0
        var kept: [AgentGearItem] = []
        for item in prof.backpack {
            if item.rarity <= maxRarity {
                dust += item.rarity.dismantleStardust
            } else {
                kept.append(item)
            }
        }
        guard dust > 0 else { return 0 }
        prof.backpack = kept
        prof.stardust += dust
        profiles[agentId] = prof
        scheduleSave()
        return dust
    }

    @discardableResult
    func forgeGear(for agentId: String) -> AgentGearItem? {
        guard var prof = profiles[agentId], prof.stardust >= Self.forgeCost else { return nil }
        prof.stardust -= Self.forgeCost
        prof.totalForges += 1
        prof.forgePityCount += 1

        let stats = prof.computeStats(commander: commander)
        let guaranteed: AgentGearRarity?
        if prof.totalForges % 15 == 0 {
            guaranteed = .epic
            prof.forgePityCount = 0
        } else if prof.forgePityCount >= 5 {
            guaranteed = .rare
            prof.forgePityCount = 0
        } else {
            guaranteed = nil
        }

        let now = Date()
        let forged = rollGear(level: prof.level, luk: stats.luk + 10, guaranteedMinRarity: guaranteed, now: now.timeIntervalSince1970)
        if forged.rarity >= .rare {
            prof.forgePityCount = 0
        }
        grantLoot(forged, to: &prof, now: now)
        _ = evaluateAchievements(on: &prof, concurrentSessions: commander.maxConcurrentSessions, now: now)
        profiles[agentId] = prof
        scheduleSave()
        return forged
    }

    @discardableResult
    func reforgeEquipped(slot: AgentGearSlot, for agentId: String) -> AgentGearItem? {
        guard var prof = profiles[agentId],
              prof.stardust >= Self.reforgeCost,
              var current = prof.equipped[slot.rawValue]
        else { return nil }
        prof.stardust -= Self.reforgeCost
        current.affixes = rollAffixes(rarity: current.rarity, itemLevel: max(current.itemLevel, prof.level))
        prof.equipped[slot.rawValue] = current
        prof.pushEvent(
            icon: "hammer.fill",
            accentHex: current.rarity.colorHex,
            zh: "重铸「\(current.nameZH)」词条成功",
            en: "Reforged \"\(current.nameEN)\" affixes",
            now: Date().timeIntervalSince1970
        )
        profiles[agentId] = prof
        scheduleSave()
        return current
    }

    // MARK: - Helpers: Level Up, Loot Generation & Achievements

    private func recordLevelUp(profile: inout AgentRPGProfile, gained: Int, now: Date) {
        lastLevelUpAtByAgent[profile.agentId] = now
        let dustBonus = gained * 35
        profile.stardust += dustBonus
        profile.pushEvent(
            icon: "arrow.up.circle.fill",
            accentHex: 0x34D399,
            zh: "升级至 Lv.\(profile.level)「\(profile.rankTier.title(zh: true))」· +\(dustBonus) ✦",
            en: "Leveled up to Lv.\(profile.level) (\(profile.rankTier.title(zh: false))) · +\(dustBonus) ✦",
            now: now.timeIntervalSince1970
        )
    }

    private func grantLoot(_ item: AgentGearItem, to profile: inout AgentRPGProfile, now: Date) {
        // Auto-equip if that slot is currently empty so the player feels immediate power gain!
        if profile.equipped[item.slot.rawValue] == nil {
            profile.equipped[item.slot.rawValue] = item
        } else {
            profile.backpack.insert(item, at: 0)
            if profile.backpack.count > 40 {
                // Auto-dismantle the lowest-rarity tail item into stardust.
                if let weakestIdx = profile.backpack.indices.min(by: {
                    let a = profile.backpack[$0]
                    let b = profile.backpack[$1]
                    if a.rarity != b.rarity { return a.rarity < b.rarity }
                    return a.gearScore < b.gearScore
                }) {
                    let scrap = profile.backpack.remove(at: weakestIdx)
                    profile.stardust += scrap.rarity.dismantleStardust
                }
            }
        }

        profile.pushEvent(
            icon: item.slot.symbolName,
            accentHex: item.rarity.colorHex,
            zh: "获得[\(item.rarity.name(zh: true))] \(item.nameZH) (GS \(item.gearScore))",
            en: "Looted [\(item.rarity.name(zh: false))] \(item.nameEN) (GS \(item.gearScore))",
            now: now.timeIntervalSince1970
        )
        lastLootBannerByAgent[profile.agentId] = (
            textZH: "[\(item.rarity.name(zh: true))] \(item.nameZH)",
            textEN: "[\(item.rarity.name(zh: false))] \(item.nameEN)",
            colorHex: item.rarity.colorHex,
            at: now
        )
        if item.rarity >= .epic {
            unlockAchievement(.treasureHunter, on: &profile, now: now)
        }
    }

    private func unlockAchievement(_ kind: AgentAchievementKind, on profile: inout AgentRPGProfile, now: Date) {
        guard profile.unlockedAchievements[kind.rawValue] == nil else { return }
        profile.unlockedAchievements[kind.rawValue] = now.timeIntervalSince1970
        profile.stardust += kind.rewardStardust
        let lvGain = profile.addXP(kind.rewardXP)
        profile.pushEvent(
            icon: kind.iconName,
            accentHex: 0xFBBF24,
            zh: "解锁成就「\(kind.title(zh: true))」· +\(kind.rewardXP) XP · +\(kind.rewardStardust) ✦",
            en: "Achievement \"\(kind.title(zh: false))\" · +\(kind.rewardXP) XP · +\(kind.rewardStardust) ✦",
            now: now.timeIntervalSince1970
        )
        if lvGain > 0 {
            recordLevelUp(profile: &profile, gained: lvGain, now: now)
        }
    }

    private func evaluateAchievements(
        on profile: inout AgentRPGProfile,
        concurrentSessions: Int,
        now: Date
    ) -> Bool {
        let before = profile.unlockedAchievements.count

        if profile.todosCleared >= 1 { unlockAchievement(.firstTodo, on: &profile, now: now) }
        if profile.todosCleared >= 10 { unlockAchievement(.todoHunter10, on: &profile, now: now) }
        if profile.todosCleared >= 50 { unlockAchievement(.todoSlayer50, on: &profile, now: now) }
        if profile.todosCleared >= 200 { unlockAchievement(.todoLegend200, on: &profile, now: now) }

        if profile.plansCleared >= 1 { unlockAchievement(.firstPlanClear, on: &profile, now: now) }
        if profile.plansCleared >= 10 { unlockAchievement(.bossBuster10, on: &profile, now: now) }

        if profile.bestCombo >= 5 { unlockAchievement(.combo5, on: &profile, now: now) }
        if profile.bestCombo >= 15 { unlockAchievement(.combo15, on: &profile, now: now) }
        if profile.bestCombo >= 30 { unlockAchievement(.combo30, on: &profile, now: now) }

        if profile.peakTPS >= 80 { unlockAchievement(.speedDemon80, on: &profile, now: now) }
        if profile.peakTPS >= 140 { unlockAchievement(.hyperVelocity140, on: &profile, now: now) }

        if profile.bestCacheHit >= 85 { unlockAchievement(.cacheWizard85, on: &profile, now: now) }
        if profile.bestCacheHit >= 95 { unlockAchievement(.perfectRecall95, on: &profile, now: now) }

        if profile.bondLevel >= 5 { unlockAchievement(.trustedPartner5, on: &profile, now: now) }
        if profile.bondLevel >= 15 { unlockAchievement(.soulbound15, on: &profile, now: now) }

        if concurrentSessions >= 3 { unlockAchievement(.multiThread3, on: &profile, now: now) }

        if profile.level >= 5 { unlockAchievement(.risingStar5, on: &profile, now: now) }
        if profile.level >= 15 { unlockAchievement(.veteran15, on: &profile, now: now) }
        if profile.level >= 30 { unlockAchievement(.blademaster30, on: &profile, now: now) }

        return profile.unlockedAchievements.count > before
    }

    private func rollGear(
        level: Int,
        luk: Int,
        guaranteedMinRarity: AgentGearRarity?,
        now: Double
    ) -> AgentGearItem {
        let slots = AgentGearSlot.allCases
        let slot = slots[Int(nextUnit() * Double(slots.count)) % slots.count]

        let luckBoost = min(0.28, Double(luk) * 0.0022)
        let r = nextUnit()
        var rarity: AgentGearRarity
        if r < 0.015 + luckBoost * 0.14 {
            rarity = .prismatic
        } else if r < 0.065 + luckBoost * 0.35 {
            rarity = .legendary
        } else if r < 0.18 + luckBoost * 0.65 {
            rarity = .epic
        } else if r < 0.42 + luckBoost * 0.85 {
            rarity = .rare
        } else if r < 0.72 {
            rarity = .uncommon
        } else {
            rarity = .common
        }
        if let guaranteedMinRarity, rarity < guaranteedMinRarity {
            rarity = guaranteedMinRarity
        }

        let prefixesZH = ["量子", "零拷贝", "棱镜", "热重载", "异步", "星轨", "编译", "矢量", "奇点", "递归"]
        let prefixesEN = ["Quantum", "Zero-Copy", "Prism", "Hot-Reload", "Async", "Orbital", "Compiler", "Vector", "Singularity", "Recursive"]
        let pIdx = Int(nextUnit() * Double(prefixesZH.count)) % prefixesZH.count

        let nounsZH: [String]
        let nounsEN: [String]
        switch slot {
        case .weaponCore:
            nounsZH = ["脉冲晶核", "光束催化器", "高频振荡核", "超频发射芯"]
            nounsEN = ["Pulse Core", "Beam Catalyst", "Flux Oscillator", "Overclock Emitter"]
        case .chipModule:
            nounsZH = ["缓存加速芯片", "并发算力模组", "语法预测单元", "神经矩阵芯片"]
            nounsEN = ["Cache Accelerator", "Concurrency Chip", "Syntax Predictor", "Neural Matrix"]
        case .prismCharm:
            nounsZH = ["光谱护符", "星尘吊坠", "羁绊棱晶", "时间折叠徽章"]
            nounsEN = ["Spectrum Charm", "Stardust Pendant", "Bond Prism", "Chrono Crest"]
        }
        let nIdx = Int(nextUnit() * Double(nounsZH.count)) % nounsZH.count

        let itemLevel = max(1, level)
        let affixes = rollAffixes(rarity: rarity, itemLevel: itemLevel)

        return AgentGearItem(
            id: UUID().uuidString,
            slot: slot,
            rarity: rarity,
            itemLevel: itemLevel,
            nameZH: "\(prefixesZH[pIdx])\(nounsZH[nIdx])",
            nameEN: "\(prefixesEN[pIdx]) \(nounsEN[nIdx])",
            affixes: affixes,
            droppedAt: now
        )
    }

    private func rollAffixes(rarity: AgentGearRarity, itemLevel: Int) -> [AgentGearAffix] {
        var pool = AgentGearAffixKind.allCases
        var picked: [AgentGearAffix] = []
        let mult = rarity.powerMultiplier
        let lvScale = 1.0 + Double(itemLevel - 1) * 0.08

        for _ in 0..<rarity.affixCount {
            guard !pool.isEmpty else { break }
            let idx = Int(nextUnit() * Double(pool.count)) % pool.count
            let kind = pool.remove(at: idx)
            let jitter = 0.85 + nextUnit() * 0.35
            let val: Double
            switch kind {
            case .atkFlat: val = (6.0 * mult * lvScale * jitter).rounded()
            case .penFlat: val = (4.0 * mult * lvScale * jitter).rounded()
            case .spdPct: val = (4.0 * mult * jitter).rounded()
            case .critRatePct: val = ((1.8 * mult * jitter) * 10).rounded() / 10.0
            case .critDmgPct: val = (8.0 * mult * jitter).rounded()
            case .synPct: val = (5.0 * mult * jitter).rounded()
            case .xpGainPct: val = (4.5 * mult * jitter).rounded()
            case .stardustPct: val = (6.0 * mult * jitter).rounded()
            }
            picked.append(AgentGearAffix(kind: kind, value: max(1, val)))
        }
        return picked
    }

    private func nextUnit() -> Double {
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        let shifted = (rngState >> 11) & 0x1FFFFF_FFFFFFFF
        return Double(shifted) / Double(0x200000_00000000)
    }

    // MARK: - Async Non-Blocking Disk Persistence

    private func loadFromDiskAsync() {
        let url = Self.storageURL()
        Task.detached(priority: .userInitiated) {
            let decoded: AgentRPGSaveFile? = {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(AgentRPGSaveFile.self, from: data)
            }()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let decoded {
                    self.showDamageNumbers = decoded.showDamageNumbers
                    if decoded.commander.totalXP > self.commander.totalXP {
                        self.commander = decoded.commander
                    }
                    for (id, saved) in decoded.profiles {
                        if let live = self.profiles[id], live.totalXP > saved.totalXP {
                            continue
                        }
                        self.profiles[id] = saved
                    }
                }
                self.hasLoadedFromDisk = true
                // What came while the save was read applies on top of it.
                if self.runningSessions > self.commander.maxConcurrentSessions {
                    self.commander.maxConcurrentSessions = self.runningSessions
                    self.scheduleSave()
                }
                let waiting = self.factsBeforeLoad
                self.factsBeforeLoad = []
                for batch in waiting {
                    self.apply(batch.facts, identity: batch.identity, now: batch.now)
                }
            }
        }
    }

    private func scheduleSave() {
        guard hasLoadedFromDisk else { return }
        pendingSaveTask?.cancel()
        let snapshot = AgentRPGSaveFile(
            schemaVersion: 1,
            showDamageNumbers: showDamageNumbers,
            commander: commander,
            profiles: profiles
        )
        let url = Self.storageURL()
        pendingSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            Self.writeSnapshot(snapshot, to: url)
        }
    }

    private func flushSaveSyncOnTerminate() {
        guard hasLoadedFromDisk else { return }
        pendingSaveTask?.cancel()
        let snapshot = AgentRPGSaveFile(
            schemaVersion: 1,
            showDamageNumbers: showDamageNumbers,
            commander: commander,
            profiles: profiles
        )
        Self.writeSnapshot(snapshot, to: Self.storageURL())
    }

    private nonisolated static func writeSnapshot(_ snapshot: AgentRPGSaveFile, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

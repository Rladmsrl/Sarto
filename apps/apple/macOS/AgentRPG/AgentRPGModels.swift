import Foundation
import PrismDesign
import SwiftUI

// MARK: - Progression Curves & Rank Tiers

enum AgentRankTier: String, Codable, CaseIterable, Sendable {
    case apprentice
    case ranger
    case knight
    case blademaster
    case archmage
    case lord
    case weaver
    case forgemaster

    static func forLevel(_ level: Int) -> AgentRankTier {
        switch level {
        case ..<10: return .apprentice
        case 10..<20: return .ranger
        case 20..<30: return .knight
        case 30..<40: return .blademaster
        case 40..<55: return .archmage
        case 55..<70: return .lord
        case 70..<85: return .weaver
        default: return .forgemaster
        }
    }

    func title(zh: Bool) -> String {
        switch self {
        case .apprentice: return zh ? "脚本学徒" : "Script Apprentice"
        case .ranger: return zh ? "终端游侠" : "Terminal Ranger"
        case .knight: return zh ? "语法骑士" : "Syntax Knight"
        case .blademaster: return zh ? "编译剑圣" : "Compiler Blademaster"
        case .archmage: return zh ? "架构大魔导" : "Archmage of Systems"
        case .lord: return zh ? "并发领主" : "Concurrency Lord"
        case .weaver: return zh ? "量子织梦者" : "Quantum Weaver"
        case .forgemaster: return zh ? "奇点神匠" : "Singularity Forgemaster"
        }
    }

    var accentHex: UInt32 {
        switch self {
        case .apprentice: return 0x94A3B8
        case .ranger: return 0x34D399
        case .knight: return 0x38BDF8
        case .blademaster: return 0x60A5FA
        case .archmage: return 0xA78BFA
        case .lord: return 0xF472B6
        case .weaver: return 0xFBBF24
        case .forgemaster: return 0xFB7185
        }
    }

    var accentColor: Color { Color(hex: accentHex) }
}

// MARK: - Weapons (Visually Alters Battlefield Projectiles & Turrets)

enum AgentWeaponKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case pulseBlaster
    case twinRepeater
    case prismScatter
    case arcStaff
    case bitDrones
    case orbitalBeam
    case quantumSplitter
    case singularityCannon

    var id: String { rawValue }

    var unlockLevel: Int {
        switch self {
        case .pulseBlaster: return 1
        case .twinRepeater: return 4
        case .prismScatter: return 8
        case .arcStaff: return 14
        case .bitDrones: return 20
        case .orbitalBeam: return 28
        case .quantumSplitter: return 38
        case .singularityCannon: return 50
        }
    }

    func name(zh: Bool) -> String {
        switch self {
        case .pulseBlaster: return zh ? "像素脉冲枪" : "Pulse Blaster"
        case .twinRepeater: return zh ? "双联突击炮" : "Twin Repeater"
        case .prismScatter: return zh ? "棱镜霰弹器" : "Prism Scatter"
        case .arcStaff: return zh ? "弧光闪电杖" : "Arc Staff"
        case .bitDrones: return zh ? "浮游双炮" : "Bit Drones"
        case .orbitalBeam: return zh ? "轨道光束炮" : "Orbital Beam"
        case .quantumSplitter: return zh ? "量子分裂弹" : "Quantum Splitter"
        case .singularityCannon: return zh ? "奇点黑洞炮" : "Singularity Cannon"
        }
    }

    func bonusSummary(zh: Bool) -> String {
        switch self {
        case .pulseBlaster: return zh ? "平衡单发弹道" : "Balanced single bolt"
        case .twinRepeater: return zh ? "双发齐射 · SPD +8%" : "Twin bolts · SPD +8%"
        case .prismScatter: return zh ? "3向散射 · CRIT +6%" : "3-way spread · CRIT +6%"
        case .arcStaff: return zh ? "锯齿电弧直击 · CDMG +15%" : "Chain bolt · CDMG +15%"
        case .bitDrones: return zh ? "双浮游炮伴飞 · ATK +12%" : "2 orbital bits · ATK +12%"
        case .orbitalBeam: return zh ? "贯穿粗激光 · PEN +20%" : "Piercing beam · PEN +20%"
        case .quantumSplitter: return zh ? "命中分裂回击 · CRIT +10%" : "4x split homing · CRIT +10%"
        case .singularityCannon: return zh ? "黑洞漩涡引爆 · 全攻 +22%" : "Vortex nova · ATK +22%"
        }
    }

    var accentHex: UInt32 {
        switch self {
        case .pulseBlaster: return 0x60A5FA
        case .twinRepeater: return 0x38BDF8
        case .prismScatter: return 0x34D399
        case .arcStaff: return 0x67E8F9
        case .bitDrones: return 0xA78BFA
        case .orbitalBeam: return 0xFBBF24
        case .quantumSplitter: return 0xF472B6
        case .singularityCannon: return 0xFB7185
        }
    }

    static func highestUnlocked(forLevel level: Int) -> AgentWeaponKind {
        Self.allCases.last(where: { level >= $0.unlockLevel }) ?? .pulseBlaster
    }
}

// MARK: - Cosmetics (Headgear, Auras, Finisher FX)

enum AgentHeadgear: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case headband
    case visor
    case headset
    case halo
    case crown

    var id: String { rawValue }

    var unlockLevel: Int {
        switch self {
        case .none: return 1
        case .headband: return 2
        case .visor: return 7
        case .headset: return 15
        case .halo: return 24
        case .crown: return 36
        }
    }

    func name(zh: Bool) -> String {
        switch self {
        case .none: return zh ? "默认原装" : "Default"
        case .headband: return zh ? "像素头带" : "Pixel Band"
        case .visor: return zh ? "赛博护目镜" : "Cyber Visor"
        case .headset: return zh ? "霓虹耳机" : "Neon Headset"
        case .halo: return zh ? "悬浮光环" : "Floating Halo"
        case .crown: return zh ? "像素王冠" : "Pixel Crown"
        }
    }

    static func highestUnlocked(forLevel level: Int) -> AgentHeadgear {
        Self.allCases.last(where: { level >= $0.unlockLevel }) ?? .none
    }
}

enum AgentAura: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case cape
    case pixelWings
    case dataOrbs
    case prismOrbit
    case overclockRainbow

    var id: String { rawValue }

    var unlockLevel: Int {
        switch self {
        case .none: return 1
        case .cape: return 5
        case .pixelWings: return 12
        case .dataOrbs: return 20
        case .prismOrbit: return 30
        case .overclockRainbow: return 45
        }
    }

    func name(zh: Bool) -> String {
        switch self {
        case .none: return zh ? "无背饰" : "None"
        case .cape: return zh ? "微光斗篷" : "Glimmer Cape"
        case .pixelWings: return zh ? "像素双翼" : "Pixel Wings"
        case .dataOrbs: return zh ? "数据环绕" : "Data Orbs"
        case .prismOrbit: return zh ? "棱镜星轨" : "Prism Orbit"
        case .overclockRainbow: return zh ? "彩虹超频" : "Rainbow Overclock"
        }
    }

    static func highestUnlocked(forLevel level: Int) -> AgentAura {
        Self.allCases.last(where: { level >= $0.unlockLevel }) ?? .none
    }
}

enum AgentFinisherFX: String, Codable, CaseIterable, Identifiable, Sendable {
    case emeraldWave
    case pixelFireworks
    case prismSlash
    case glitchShatter

    var id: String { rawValue }

    var unlockLevel: Int {
        switch self {
        case .emeraldWave: return 1
        case .pixelFireworks: return 6
        case .prismSlash: return 16
        case .glitchShatter: return 26
        }
    }

    func name(zh: Bool) -> String {
        switch self {
        case .emeraldWave: return zh ? "翠绿冲击波" : "Emerald Wave"
        case .pixelFireworks: return zh ? "像素烟花雨" : "Pixel Fireworks"
        case .prismSlash: return zh ? "棱镜裂斩" : "Prism Slash"
        case .glitchShatter: return zh ? "故障粉碎" : "Glitch Shatter"
        }
    }

    static func highestUnlocked(forLevel level: Int) -> AgentFinisherFX {
        Self.allCases.last(where: { level >= $0.unlockLevel }) ?? .emeraldWave
    }
}

// MARK: - Auto-Triggered Skills

enum AgentSkillKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case overdriveBarrage
    case shieldBreaker
    case chainArc
    case starfallStrike
    case sartoPrismCombo

    var id: String { rawValue }

    var requiredAgentLevel: Int {
        switch self {
        case .overdriveBarrage: return 3
        case .shieldBreaker: return 6
        case .chainArc: return 12
        case .starfallStrike: return 18
        case .sartoPrismCombo: return 1
        }
    }

    var requiredBondLevel: Int {
        switch self {
        case .sartoPrismCombo: return 3
        default: return 1
        }
    }

    func isUnlocked(agentLevel: Int, bondLevel: Int) -> Bool {
        agentLevel >= requiredAgentLevel && bondLevel >= requiredBondLevel
    }

    func name(zh: Bool) -> String {
        switch self {
        case .overdriveBarrage: return zh ? "过载连射" : "Overdrive Barrage"
        case .shieldBreaker: return zh ? "破盾重击" : "Shield Breaker"
        case .chainArc: return zh ? "链式传导" : "Chain Arc"
        case .starfallStrike: return zh ? "星轨支援" : "Starfall Strike"
        case .sartoPrismCombo: return zh ? "Sarto 棱镜合击" : "Sarto Prism Combo"
        }
    }

    func detail(zh: Bool) -> String {
        switch self {
        case .overdriveBarrage:
            return zh ? "高输出或编辑阶段自动触发 3 秒弹幕狂潮" : "Auto rapid-fire surge during intense output"
        case .shieldBreaker:
            return zh ? "每 14 秒轰出 2.4x 暴击穿甲冲击波" : "Fires a 2.4x guaranteed crit piercing wave every 14s"
        case .chainArc:
            return zh ? "击中当前 Todo 时电弧跃向下条待办预热削盾" : "Arcs cyan lightning onto the next pending Todo row"
        case .starfallStrike:
            return zh ? "每 16 秒召唤 3 颗星轨像素流星轰击目标" : "Calls down 3 pixel meteors from orbit every 16s"
        case .sartoPrismCombo:
            return zh ? "Sarto 满蓄能时双人合体发射彩虹超级光束" : "Dual-core rainbow superbeam when Sarto fully charges"
        }
    }

    func requirementTag(zh: Bool) -> String {
        if requiredBondLevel > 1 {
            return zh ? "羁绊 Lv.\(requiredBondLevel)" : "Bond Lv.\(requiredBondLevel)"
        }
        return "Lv.\(requiredAgentLevel)"
    }
}

// MARK: - Equipment, Rarities & Random Affixes

enum AgentGearSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case weaponCore
    case chipModule
    case prismCharm

    var id: String { rawValue }

    func name(zh: Bool) -> String {
        switch self {
        case .weaponCore: return zh ? "武器核心" : "Weapon Core"
        case .chipModule: return zh ? "芯片模组" : "Chip Module"
        case .prismCharm: return zh ? "棱镜护符" : "Prism Charm"
        }
    }

    var symbolName: String {
        switch self {
        case .weaponCore: return "bolt.horizontal.fill"
        case .chipModule: return "cpu.fill"
        case .prismCharm: return "sparkles"
        }
    }
}

enum AgentGearRarity: String, Codable, CaseIterable, Comparable, Sendable {
    case common
    case uncommon
    case rare
    case epic
    case legendary
    case prismatic

    var tierOrder: Int {
        switch self {
        case .common: return 0
        case .uncommon: return 1
        case .rare: return 2
        case .epic: return 3
        case .legendary: return 4
        case .prismatic: return 5
        }
    }

    static func < (lhs: AgentGearRarity, rhs: AgentGearRarity) -> Bool {
        lhs.tierOrder < rhs.tierOrder
    }

    func name(zh: Bool) -> String {
        switch self {
        case .common: return zh ? "普通" : "Common"
        case .uncommon: return zh ? "精良" : "Uncommon"
        case .rare: return zh ? "稀有" : "Rare"
        case .epic: return zh ? "史诗" : "Epic"
        case .legendary: return zh ? "传说" : "Legendary"
        case .prismatic: return zh ? "棱镜" : "Prismatic"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .common: return 0x94A3B8
        case .uncommon: return 0x34D399
        case .rare: return 0x38BDF8
        case .epic: return 0xA78BFA
        case .legendary: return 0xFBBF24
        case .prismatic: return 0xFB7185
        }
    }

    var color: Color { Color(hex: colorHex) }

    var affixCount: Int {
        switch self {
        case .common: return 1
        case .uncommon: return 1
        case .rare: return 2
        case .epic: return 2
        case .legendary: return 3
        case .prismatic: return 3
        }
    }

    var powerMultiplier: Double {
        switch self {
        case .common: return 1.0
        case .uncommon: return 1.35
        case .rare: return 1.85
        case .epic: return 2.55
        case .legendary: return 3.45
        case .prismatic: return 4.6
        }
    }

    var dismantleStardust: Int {
        switch self {
        case .common: return 18
        case .uncommon: return 36
        case .rare: return 70
        case .epic: return 140
        case .legendary: return 280
        case .prismatic: return 520
        }
    }
}

enum AgentGearAffixKind: String, Codable, CaseIterable, Sendable {
    case atkFlat
    case spdPct
    case critRatePct
    case critDmgPct
    case penFlat
    case synPct
    case xpGainPct
    case stardustPct

    func formatted(value: Double, zh: Bool) -> String {
        let iv = Int(value.rounded())
        switch self {
        case .atkFlat: return zh ? "ATK +\(iv)" : "ATK +\(iv)"
        case .spdPct: return zh ? "攻速 +\(iv)%" : "SPD +\(iv)%"
        case .critRatePct: return zh ? "暴击 +\(String(format: "%.1f", value))%" : "CRIT +\(String(format: "%.1f", value))%"
        case .critDmgPct: return zh ? "暴伤 +\(iv)%" : "CDMG +\(iv)%"
        case .penFlat: return zh ? "破甲 +\(iv)" : "PEN +\(iv)"
        case .synPct: return zh ? "协战 +\(iv)%" : "SYN +\(iv)%"
        case .xpGainPct: return zh ? "经验 +\(iv)%" : "XP +\(iv)%"
        case .stardustPct: return zh ? "星尘 +\(iv)%" : "Dust +\(iv)%"
        }
    }
}

struct AgentGearAffix: Codable, Equatable, Hashable, Sendable {
    let kind: AgentGearAffixKind
    let value: Double
}

struct AgentGearItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let slot: AgentGearSlot
    let rarity: AgentGearRarity
    let itemLevel: Int
    let nameZH: String
    let nameEN: String
    var affixes: [AgentGearAffix]
    let droppedAt: Double

    func displayName(zh: Bool) -> String {
        zh ? nameZH : nameEN
    }

    var gearScore: Int {
        let base = Double(itemLevel) * 14.0 * rarity.powerMultiplier
        let affixScore = affixes.reduce(0.0) { acc, af in
            switch af.kind {
            case .atkFlat, .penFlat: return acc + af.value * 2.2
            case .critRatePct: return acc + af.value * 9.5
            case .critDmgPct: return acc + af.value * 3.1
            case .spdPct, .synPct: return acc + af.value * 4.2
            case .xpGainPct, .stardustPct: return acc + af.value * 2.6
            }
        }
        return max(10, Int((base + affixScore).rounded()))
    }
}

// MARK: - Achievements (22 Milestones)

enum AgentAchievementKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case firstTodo
    case todoHunter10
    case todoSlayer50
    case todoLegend200
    case firstPlanClear
    case bossBuster10
    case combo5
    case combo15
    case combo30
    case speedDemon80
    case hyperVelocity140
    case cacheWizard85
    case perfectRecall95
    case commandersDecree
    case trustedPartner5
    case soulbound15
    case nightOwl
    case multiThread3
    case risingStar5
    case veteran15
    case blademaster30
    case treasureHunter

    var id: String { rawValue }

    var rewardXP: Int {
        switch self {
        case .firstTodo, .commandersDecree: return 120
        case .firstPlanClear, .combo5, .nightOwl, .risingStar5: return 240
        case .todoHunter10, .speedDemon80, .cacheWizard85, .trustedPartner5, .multiThread3, .treasureHunter: return 380
        case .todoSlayer50, .bossBuster10, .combo15, .hyperVelocity140, .perfectRecall95, .veteran15: return 750
        case .todoLegend200, .combo30, .soulbound15, .blademaster30: return 1500
        }
    }

    var rewardStardust: Int {
        switch self {
        case .firstTodo, .commandersDecree: return 50
        case .firstPlanClear, .combo5, .nightOwl, .risingStar5: return 90
        case .todoHunter10, .speedDemon80, .cacheWizard85, .trustedPartner5, .multiThread3, .treasureHunter: return 150
        case .todoSlayer50, .bossBuster10, .combo15, .hyperVelocity140, .perfectRecall95, .veteran15: return 280
        case .todoLegend200, .combo30, .soulbound15, .blademaster30: return 520
        }
    }

    var iconName: String {
        switch self {
        case .firstTodo, .todoHunter10, .todoSlayer50, .todoLegend200: return "target"
        case .firstPlanClear, .bossBuster10: return "crown.fill"
        case .combo5, .combo15, .combo30: return "flame.fill"
        case .speedDemon80, .hyperVelocity140: return "bolt.fill"
        case .cacheWizard85, .perfectRecall95: return "sparkles"
        case .commandersDecree, .trustedPartner5, .soulbound15: return "heart.fill"
        case .nightOwl: return "moon.stars.fill"
        case .multiThread3: return "square.grid.2x2.fill"
        case .risingStar5, .veteran15, .blademaster30: return "star.fill"
        case .treasureHunter: return "diamond.fill"
        }
    }

    func title(zh: Bool) -> String {
        switch self {
        case .firstTodo: return zh ? "第一滴血" : "First Blood"
        case .todoHunter10: return zh ? "清单猎人" : "Todo Hunter"
        case .todoSlayer50: return zh ? "任务收割者" : "Todo Slayer"
        case .todoLegend200: return zh ? "百战清道夫" : "Todo Legend"
        case .firstPlanClear: return zh ? "首通计划" : "Plan Sweeper"
        case .bossBuster10: return zh ? "十连全清" : "Boss Buster"
        case .combo5: return zh ? "连战连捷" : "5x Combo"
        case .combo15: return zh ? "势如破竹" : "15x Unstoppable"
        case .combo30: return zh ? "无双连斩" : "30x Godlike"
        case .speedDemon80: return zh ? "疾风输出" : "Speed Demon"
        case .hyperVelocity140: return zh ? "光速编译" : "Hyper Velocity"
        case .cacheWizard85: return zh ? "缓存魔术师" : "Cache Wizard"
        case .perfectRecall95: return zh ? "完美记忆" : "Perfect Recall"
        case .commandersDecree: return zh ? "指挥官授权" : "Commander's Decree"
        case .trustedPartner5: return zh ? "默契搭档" : "Trusted Partner"
        case .soulbound15: return zh ? "星轨羁绊" : "Soulbound Duo"
        case .nightOwl: return zh ? "深夜守望者" : "Night Owl"
        case .multiThread3: return zh ? "多线指挥官" : "Multi-Thread Ops"
        case .risingStar5: return zh ? "初露锋芒" : "Rising Star"
        case .veteran15: return zh ? "身经百战" : "Battle Veteran"
        case .blademaster30: return zh ? "编译剑圣" : "Blademaster"
        case .treasureHunter: return zh ? "秘宝收藏家" : "Treasure Hunter"
        }
    }

    func requirement(zh: Bool) -> String {
        switch self {
        case .firstTodo: return zh ? "击破第 1 个 Todo" : "Clear your first Todo"
        case .todoHunter10: return zh ? "累计击破 10 个 Todo" : "Clear 10 Todos"
        case .todoSlayer50: return zh ? "累计击破 50 个 Todo" : "Clear 50 Todos"
        case .todoLegend200: return zh ? "累计击破 200 个 Todo" : "Clear 200 Todos"
        case .firstPlanClear: return zh ? "完整清空 1 份执行计划" : "Complete a full Plan"
        case .bossBuster10: return zh ? "完整清空 10 份执行计划" : "Complete 10 full Plans"
        case .combo5: return zh ? "达成 5 连击" : "Reach a 5x combo"
        case .combo15: return zh ? "达成 15 连击" : "Reach a 15x combo"
        case .combo30: return zh ? "达成 30 连击" : "Reach a 30x combo"
        case .speedDemon80: return zh ? "实时输出速度达到 80 tok/s" : "Reach 80 tok/s output speed"
        case .hyperVelocity140: return zh ? "实时输出速度达到 140 tok/s" : "Reach 140 tok/s output speed"
        case .cacheWizard85: return zh ? "Prompt 缓存命中率达到 85%" : "Reach 85% prompt cache hit"
        case .perfectRecall95: return zh ? "Prompt 缓存命中率达到 95%" : "Reach 95% prompt cache hit"
        case .commandersDecree: return zh ? "放行审批触发指挥官鼓舞" : "Trigger Commander Buff via approval"
        case .trustedPartner5: return zh ? "与 Sarto 羁绊达到 Lv.5" : "Reach Sarto Bond Lv.5"
        case .soulbound15: return zh ? "与 Sarto 羁绊达到 Lv.15" : "Reach Sarto Bond Lv.15"
        case .nightOwl: return zh ? "凌晨 1:00–5:00 击破 Todo" : "Clear a Todo between 01:00 and 05:00"
        case .multiThread3: return zh ? "同时指挥 3 个以上会话运行" : "Run 3+ sessions simultaneously"
        case .risingStar5: return zh ? "Agent 升至 Lv.5" : "Reach Agent Lv.5"
        case .veteran15: return zh ? "Agent 升至 Lv.15" : "Reach Agent Lv.15"
        case .blademaster30: return zh ? "Agent 升至 Lv.30" : "Reach Agent Lv.30"
        case .treasureHunter: return zh ? "获得史诗及以上稀有装备" : "Obtain Epic or higher gear"
        }
    }
}

// MARK: - Combat Event Feed

struct AgentRPGEventEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let timestamp: Double
    let icon: String
    let accentHex: UInt32
    let textZH: String
    let textEN: String

    func text(zh: Bool) -> String { zh ? textZH : textEN }
}

// MARK: - Computed 8-Stat Sheet

struct AgentRPGStats: Equatable, Sendable {
    let atk: Int
    let spd: Int
    let critRate: Double     // 0.08 ... 0.80
    let critDamage: Double   // 1.55 ... 4.20
    let pen: Int
    let syn: Int
    let eco: Double          // 0.00 ... 0.42 (cooldown reduction)
    let luk: Int
    let xpBonusMultiplier: Double
    let stardustBonusMultiplier: Double
    let powerScore: Int
    let estimatedDPS: Int

    /// Deterministic lightweight hit damage roll for Canvas damage numbers.
    func rollHitDamage(
        isHeavy: Bool,
        isSkill: Bool,
        commanderBuff: Bool,
        rng: inout UInt64
    ) -> (damage: Int, isCrit: Bool, isSuperCrit: Bool) {
        func nextUnit() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let shifted = (rng >> 11) & 0x1FFFFF_FFFFFFFF
            return Double(shifted) / Double(0x200000_00000000)
        }

        let variance = 0.88 + nextUnit() * 0.24
        var base = Double(atk) * (1.0 + Double(pen) * 0.0055) * variance
        if isHeavy { base *= 1.55 }
        if isSkill { base *= 2.15 }
        if commanderBuff { base *= 1.35 }

        let effectiveCrit = min(0.95, critRate + (commanderBuff ? 0.25 : 0) + (isSkill ? 0.20 : 0))
        let roll = nextUnit()
        let isCrit = roll < effectiveCrit
        let isSuperCrit = isCrit && nextUnit() < min(0.28, Double(luk) * 0.0032 + (commanderBuff ? 0.12 : 0))

        if isSuperCrit {
            base *= critDamage * 1.42
        } else if isCrit {
            base *= critDamage
        }

        return (max(1, Int(base.rounded())), isCrit, isSuperCrit)
    }
}

// MARK: - Sarto Commander & Agent Persistent Profiles

struct SartoCommanderProfile: Codable, Equatable, Sendable {
    var level: Int = 1
    var xp: Int = 0
    var totalXP: Int = 0
    var totalTodosCommanded: Int = 0
    var totalPlansCommanded: Int = 0
    var totalApprovals: Int = 0
    var maxConcurrentSessions: Int = 0

    static func xpRequired(forLevel level: Int) -> Int {
        Int((160.0 * pow(Double(max(1, level)), 1.48) + 80.0 * Double(max(1, level))).rounded())
    }

    var xpToNextLevel: Int {
        Self.xpRequired(forLevel: level)
    }

    var levelProgress: Double {
        let req = Double(max(1, xpToNextLevel))
        return min(1.0, max(0.0, Double(xp) / req))
    }

    mutating func addXP(_ amount: Int) -> Int {
        guard amount > 0 else { return 0 }
        xp += amount
        totalXP += amount
        var gainedLevels = 0
        while level < 99 {
            let need = Self.xpRequired(forLevel: level)
            guard xp >= need else { break }
            xp -= need
            level += 1
            gainedLevels += 1
        }
        return gainedLevels
    }
}

struct AgentRPGProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String { agentId }
    let agentId: String
    var displayName: String
    var harness: String

    // Core progression (fresh Lv.1 start)
    var level: Int = 1
    var xp: Int = 0
    var totalXP: Int = 0
    var bondLevel: Int = 1
    var bondXP: Int = 0
    var stardust: Int = 60
    var forgePityCount: Int = 0
    var totalForges: Int = 0

    // Streaks & combat counters
    var combo: Int = 0
    var bestCombo: Int = 0
    var activeSeconds: Double = 0
    var todosCleared: Int = 0
    var plansCleared: Int = 0
    var turnsCompleted: Int = 0
    var approvalsGranted: Int = 0
    var subagentAssists: Int = 0
    var totalDamageDealt: Int64 = 0
    var totalCrits: Int = 0

    // Real-work mastery accumulators (drive the 8 stats organically)
    var editTicks: Int = 0
    var thinkTicks: Int = 0
    var scanTicks: Int = 0
    var commandTicks: Int = 0
    var peakTPS: Double = 0
    var bestCacheHit: Double = 0
    var recentCacheHit: Double = 0

    // Cosmetics & weapon transmog (nil = automatically use highest unlocked)
    var selectedWeapon: AgentWeaponKind?
    var selectedHeadgear: AgentHeadgear?
    var selectedAura: AgentAura?
    var selectedFinisher: AgentFinisherFX?

    // Equipment & backpack
    var equipped: [String: AgentGearItem] = [:]
    var backpack: [AgentGearItem] = []

    // Achievements & recent log
    var unlockedAchievements: [String: Double] = [:]
    var recentEvents: [AgentRPGEventEntry] = []

    static func xpRequired(forLevel level: Int) -> Int {
        Int((120.0 * pow(Double(max(1, level)), 1.45) + 60.0 * Double(max(1, level))).rounded())
    }

    static func bondXPRequired(forLevel level: Int) -> Int {
        Int((80.0 * pow(Double(max(1, level)), 1.38) + 40.0 * Double(max(1, level))).rounded())
    }

    var xpToNextLevel: Int { Self.xpRequired(forLevel: level) }
    var bondXPToNextLevel: Int { Self.bondXPRequired(forLevel: bondLevel) }

    var levelProgress: Double {
        min(1.0, max(0.0, Double(xp) / Double(max(1, xpToNextLevel))))
    }

    var bondProgress: Double {
        min(1.0, max(0.0, Double(bondXP) / Double(max(1, bondXPToNextLevel))))
    }

    var rankTier: AgentRankTier { AgentRankTier.forLevel(level) }

    var activeWeapon: AgentWeaponKind {
        if let picked = selectedWeapon, level >= picked.unlockLevel {
            return picked
        }
        return AgentWeaponKind.highestUnlocked(forLevel: level)
    }

    var activeHeadgear: AgentHeadgear {
        if let picked = selectedHeadgear, level >= picked.unlockLevel {
            return picked
        }
        return AgentHeadgear.highestUnlocked(forLevel: level)
    }

    var activeAura: AgentAura {
        if let picked = selectedAura, level >= picked.unlockLevel {
            return picked
        }
        return AgentAura.highestUnlocked(forLevel: level)
    }

    var activeFinisher: AgentFinisherFX {
        if let picked = selectedFinisher, level >= picked.unlockLevel {
            return picked
        }
        return AgentFinisherFX.highestUnlocked(forLevel: level)
    }

    var comboMultiplier: Double {
        min(2.5, 1.0 + Double(combo) * 0.10)
    }

    var cacheBonusMultiplier: Double {
        guard recentCacheHit >= 70 else { return 1.0 }
        return 1.0 + min(0.35, (recentCacheHit - 65.0) / 100.0)
    }

    func equippedItem(for slot: AgentGearSlot) -> AgentGearItem? {
        equipped[slot.rawValue]
    }

    func computeStats(commander: SartoCommanderProfile) -> AgentRPGStats {
        var atkFlat = 0.0
        var spdPct = 0.0
        var critRateBonus = 0.0
        var critDmgBonus = 0.0
        var penFlat = 0.0
        var synPct = 0.0
        var xpPct = 0.0
        var dustPct = 0.0
        var totalGearScore = 0

        for item in equipped.values {
            totalGearScore += item.gearScore
            for af in item.affixes {
                switch af.kind {
                case .atkFlat: atkFlat += af.value
                case .spdPct: spdPct += af.value
                case .critRatePct: critRateBonus += af.value / 100.0
                case .critDmgPct: critDmgBonus += af.value / 100.0
                case .penFlat: penFlat += af.value
                case .synPct: synPct += af.value
                case .xpGainPct: xpPct += af.value / 100.0
                case .stardustPct: dustPct += af.value / 100.0
                }
            }
        }

        // Weapon passive bonuses
        var weaponAtkMult = 1.0
        switch activeWeapon {
        case .pulseBlaster: break
        case .twinRepeater: spdPct += 8
        case .prismScatter: critRateBonus += 0.06
        case .arcStaff: critDmgBonus += 0.15
        case .bitDrones: weaponAtkMult = 1.12; synPct += 10
        case .orbitalBeam: penFlat += 20
        case .quantumSplitter: critRateBonus += 0.10; critDmgBonus += 0.18
        case .singularityCannon: weaponAtkMult = 1.22; critRateBonus += 0.06
        }

        // Diminishing-return mastery curves so real work noticeably shapes each Agent's build.
        let editMastery = sqrt(Double(max(0, editTicks))) * 4.8
        let thinkMastery = min(1.25, sqrt(Double(max(0, thinkTicks))) * 0.045)
        let scanMastery = min(0.32, sqrt(Double(max(0, scanTicks))) * 0.015)
        let cmdMastery = sqrt(Double(max(0, commandTicks))) * 3.6
        let tpsMastery = min(65.0, peakTPS * 0.42)
        let commanderAtkMult = 1.0 + Double(commander.level - 1) * 0.02

        let rawAtk = (24.0 + Double(level) * 9.5 + editMastery + Double(todosCleared) * 0.9 + atkFlat)
            * weaponAtkMult * commanderAtkMult
        let atk = max(12, Int(rawAtk.rounded()))

        let rawSpd = (18.0 + Double(level) * 3.2 + tpsMastery + Double(turnsCompleted) * 0.4) * (1.0 + spdPct / 100.0)
        let spd = max(10, Int(rawSpd.rounded()))

        let critRate = min(0.80, 0.10 + Double(level) * 0.0045 + scanMastery + critRateBonus)
        let critDamage = min(4.20, 1.55 + Double(level) * 0.022 + thinkMastery + critDmgBonus)

        let pen = max(4, Int((8.0 + Double(level) * 4.0 + cmdMastery + penFlat).rounded()))

        let rawSyn = (12.0 + Double(bondLevel) * 9.0 + Double(subagentAssists) * 3.5 + Double(commander.level) * 1.5)
            * (1.0 + synPct / 100.0)
        let syn = max(10, Int(rawSyn.rounded()))

        let eco = min(0.42, (bestCacheHit / 100.0) * 0.28 + Double(level) * 0.002)

        let achCount = unlockedAchievements.count
        let luk = max(8, Int((10.0 + Double(level) * 1.8 + Double(plansCleared) * 2.5 + Double(achCount) * 3.0).rounded()))

        let hitsPerSec = 1.6 + min(3.4, Double(spd) / 38.0)
        let avgHit = Double(atk) * (1.0 + Double(pen) * 0.0055) * (1.0 + critRate * (critDamage - 1.0))
        let dps = max(15, Int((avgHit * hitsPerSec).rounded()))

        let power = max(
            100,
            Int((Double(atk) * 3.6 + Double(spd) * 2.8 + critRate * 950.0 + critDamage * 220.0
                + Double(pen) * 3.1 + Double(syn) * 2.4 + eco * 600.0 + Double(luk) * 2.2
                + Double(totalGearScore) * 0.85 + Double(level) * 42.0).rounded())
        )

        return AgentRPGStats(
            atk: atk,
            spd: spd,
            critRate: critRate,
            critDamage: critDamage,
            pen: pen,
            syn: syn,
            eco: eco,
            luk: luk,
            xpBonusMultiplier: 1.0 + xpPct,
            stardustBonusMultiplier: 1.0 + dustPct,
            powerScore: power,
            estimatedDPS: dps
        )
    }

    mutating func addXP(_ amount: Int) -> Int {
        guard amount > 0 else { return 0 }
        xp += amount
        totalXP += amount
        var gained = 0
        while level < 99 {
            let req = Self.xpRequired(forLevel: level)
            guard xp >= req else { break }
            xp -= req
            level += 1
            gained += 1
        }
        return gained
    }

    mutating func addBondXP(_ amount: Int) -> Int {
        guard amount > 0 else { return 0 }
        bondXP += amount
        var gained = 0
        while bondLevel < 20 {
            let req = Self.bondXPRequired(forLevel: bondLevel)
            guard bondXP >= req else { break }
            bondXP -= req
            bondLevel += 1
            gained += 1
        }
        return gained
    }

    mutating func pushEvent(icon: String, accentHex: UInt32, zh: String, en: String, now: Double) {
        let entry = AgentRPGEventEntry(
            id: "\(Int64(now * 1000))-\(recentEvents.count)-\(Int.random(in: 0..<9999))",
            timestamp: now,
            icon: icon,
            accentHex: accentHex,
            textZH: zh,
            textEN: en
        )
        recentEvents.insert(entry, at: 0)
        if recentEvents.count > 25 {
            recentEvents.removeLast(recentEvents.count - 25)
        }
    }
}

struct AgentRPGSaveFile: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var showDamageNumbers: Bool = true
    var commander: SartoCommanderProfile = SartoCommanderProfile()
    var profiles: [String: AgentRPGProfile] = [:]
}

/// Lightweight immutable snapshot passed into Canvas so animations render at 60fps with zero lock/IO.
struct AgentBattleLoadout: Equatable, Sendable {
    let enabled: Bool
    let showDamageNumbers: Bool
    let level: Int
    let bondLevel: Int
    let weapon: AgentWeaponKind
    let headgear: AgentHeadgear
    let aura: AgentAura
    let finisher: AgentFinisherFX
    let stats: AgentRPGStats
    let unlockedSkills: Set<AgentSkillKind>
    let commanderBuffActive: Bool
    let justLeveledUp: Bool

    static let disabled = AgentBattleLoadout(
        enabled: false,
        showDamageNumbers: false,
        level: 1,
        bondLevel: 1,
        weapon: .pulseBlaster,
        headgear: .none,
        aura: .none,
        finisher: .emeraldWave,
        stats: AgentRPGStats(
            atk: 24, spd: 18, critRate: 0.1, critDamage: 1.55,
            pen: 8, syn: 12, eco: 0, luk: 10,
            xpBonusMultiplier: 1, stardustBonusMultiplier: 1,
            powerScore: 100, estimatedDPS: 40
        ),
        unlockedSkills: [],
        commanderBuffActive: false,
        justLeveledUp: false
    )
}

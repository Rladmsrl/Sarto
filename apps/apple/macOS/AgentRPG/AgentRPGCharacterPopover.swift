import PrismDesign
import SwiftUI

// MARK: - Shared Pixel Art Renderer for Cosmetics, Weapons & Preview

/// Pure procedural pixel art helpers shared by `RunningSessionsRail`'s live battlefield and
/// `AgentRPGCharacterPopover`'s animated avatar preview.
enum AgentPixelArtRenderer {
    /// Draws backpieces and ambient pixel auras behind the Agent sprite.
    static func drawAura(
        context: inout GraphicsContext,
        aura: AgentAura,
        center: CGPoint,
        spriteSize: CGFloat,
        elapsed: Double,
        palette: [Color],
        scale: CGFloat = 1.0
    ) {
        guard aura != .none else { return }
        let px = 1.8 * scale
        let brand = palette.first ?? IslandTheme.prismCobalt
        let secondary = palette.count > 1 ? palette[1] : IslandTheme.prismIris

        switch aura {
        case .none:
            break

        case .cape:
            let flutter = CGFloat(sin(elapsed * 7.2)) * 1.4 * scale
            let cols: [(CGFloat, CGFloat, Double)] = [
                (-spriteSize * 0.56, 1.0 * scale, 0.52),
                (-spriteSize * 0.72, 2.2 * scale + flutter * 0.5, 0.36),
                (-spriteSize * 0.88, 3.0 * scale + flutter, 0.22),
            ]
            for (dx, dy, alpha) in cols {
                let r = CGRect(
                    x: center.x + dx,
                    y: center.y - spriteSize * 0.16 + dy,
                    width: px * 1.15,
                    height: spriteSize * 0.54
                )
                context.fill(Path(r), with: .color(brand.opacity(alpha)))
            }

        case .pixelWings:
            let flap = CGFloat(sin(elapsed * 8.4)) * 2.1 * scale
            let wingColor = secondary.opacity(0.82)
            let tipColor = Color.white.opacity(0.72)
            let upperPoints: [(CGFloat, CGFloat)] = [
                (-spriteSize * 0.58, -spriteSize * 0.22 - flap * 0.4),
                (-spriteSize * 0.76, -spriteSize * 0.40 - flap * 0.8),
                (-spriteSize * 0.92, -spriteSize * 0.28 - flap),
                (-spriteSize * 0.74, -spriteSize * 0.08 - flap * 0.4),
            ]
            let lowerPoints: [(CGFloat, CGFloat)] = [
                (-spriteSize * 0.58, spriteSize * 0.18 + flap * 0.3),
                (-spriteSize * 0.76, spriteSize * 0.34 + flap * 0.6),
                (-spriteSize * 0.88, spriteSize * 0.22 + flap * 0.8),
            ]
            for (i, pt) in upperPoints.enumerated() {
                let r = CGRect(x: center.x + pt.0, y: center.y + pt.1, width: px, height: px)
                context.fill(Path(r), with: .color(i == 1 ? tipColor : wingColor))
            }
            for pt in lowerPoints {
                let r = CGRect(x: center.x + pt.0, y: center.y + pt.1, width: px, height: px)
                context.fill(Path(r), with: .color(brand.opacity(0.66)))
            }

        case .dataOrbs:
            let radius = spriteSize * 0.66
            let colors: [Color] = [Color(hex: 0x38BDF8), Color(hex: 0xA78BFA), Color(hex: 0x34D399)]
            for i in 0..<3 {
                let angle = elapsed * 3.1 + Double(i) * (.pi * 2.0 / 3.0)
                let ox = center.x + CGFloat(cos(angle)) * radius
                let oy = center.y + CGFloat(sin(angle)) * radius * 0.68
                let r = CGRect(x: ox - px * 0.5, y: oy - px * 0.5, width: px, height: px)
                context.fill(Path(r), with: .color(colors[i].opacity(0.88)))
            }

        case .prismOrbit:
            let rx = spriteSize * 0.76
            let ry = spriteSize * 0.34
            let steps = 10
            let rainbow: [Color] = [
                Color(hex: 0x38BDF8), Color(hex: 0x818CF8), Color(hex: 0xC084FC),
                Color(hex: 0xF472B6), Color(hex: 0xFBBF24), Color(hex: 0x34D399),
            ]
            for i in 0..<steps {
                let a = elapsed * 2.4 + Double(i) * (.pi * 2.0 / Double(steps))
                let ox = center.x + CGFloat(cos(a)) * rx
                let oy = center.y + CGFloat(sin(a)) * ry
                let depth = 0.35 + 0.55 * (sin(a) * 0.5 + 0.5)
                let r = CGRect(x: ox - px * 0.45, y: oy - px * 0.45, width: px * 0.9, height: px * 0.9)
                context.fill(Path(r), with: .color(rainbow[i % rainbow.count].opacity(depth)))
            }

        case .overclockRainbow:
            let rainbow: [Color] = [
                Color(hex: 0xFB7185), Color(hex: 0xFBBF24), Color(hex: 0x34D399),
                Color(hex: 0x38BDF8), Color(hex: 0xA78BFA),
            ]
            let pulse = 0.62 + 0.14 * CGFloat(sin(elapsed * 6.0))
            let rad = spriteSize * pulse
            for i in 0..<8 {
                let a = elapsed * 2.8 + Double(i) * (.pi / 4.0)
                let ox = center.x + CGFloat(cos(a)) * rad
                let oy = center.y + CGFloat(sin(a)) * rad
                let col = rainbow[(i + Int(elapsed * 6)) % rainbow.count]
                let r = CGRect(x: ox - px * 0.55, y: oy - px * 0.55, width: px * 1.1, height: px * 1.1)
                context.fill(Path(r), with: .color(col.opacity(0.84)))
            }
        }
    }

    /// Draws pixel headgear directly over the Agent sprite.
    static func drawHeadgear(
        context: inout GraphicsContext,
        headgear: AgentHeadgear,
        center: CGPoint,
        spriteSize: CGFloat,
        elapsed: Double,
        scale: CGFloat = 1.0
    ) {
        guard headgear != .none else { return }
        let px = 1.75 * scale
        let topY = center.y - spriteSize * 0.52

        switch headgear {
        case .none:
            break

        case .headband:
            let bandColor = Color(hex: 0xFB7185)
            let band = CGRect(
                x: center.x - spriteSize * 0.46,
                y: topY + spriteSize * 0.14,
                width: spriteSize * 0.92,
                height: px * 1.05
            )
            context.fill(Path(band), with: .color(bandColor))
            let tailWave = CGFloat(sin(elapsed * 9.0)) * 1.2 * scale
            let tail1 = CGRect(x: center.x - spriteSize * 0.62, y: topY + spriteSize * 0.16 + tailWave * 0.4, width: px, height: px)
            let tail2 = CGRect(x: center.x - spriteSize * 0.74, y: topY + spriteSize * 0.24 + tailWave, width: px, height: px)
            context.fill(Path(tail1), with: .color(bandColor.opacity(0.9)))
            context.fill(Path(tail2), with: .color(bandColor.opacity(0.65)))

        case .visor:
            let visor = CGRect(
                x: center.x - spriteSize * 0.34,
                y: center.y - spriteSize * 0.18,
                width: spriteSize * 0.78,
                height: px * 1.35
            )
            context.fill(Path(visor), with: .color(Color(hex: 0x22D3EE).opacity(0.92)))
            let glintX = center.x - spriteSize * 0.20 + CGFloat((sin(elapsed * 4.5) * 0.5 + 0.5)) * spriteSize * 0.44
            let glint = CGRect(x: glintX, y: visor.minY, width: px, height: px * 0.9)
            context.fill(Path(glint), with: .color(.white))

        case .headset:
            let neon = Color(hex: 0xA78BFA)
            let cup = Color(hex: 0x38BDF8)
            let arch = CGRect(x: center.x - spriteSize * 0.42, y: topY - px * 0.4, width: spriteSize * 0.84, height: px * 0.9)
            let leftCup = CGRect(x: center.x - spriteSize * 0.56, y: center.y - spriteSize * 0.18, width: px * 1.1, height: px * 2.4)
            let rightCup = CGRect(x: center.x + spriteSize * 0.44, y: center.y - spriteSize * 0.18, width: px * 1.1, height: px * 2.4)
            context.fill(Path(arch), with: .color(neon))
            context.fill(Path(leftCup), with: .color(cup))
            context.fill(Path(rightCup), with: .color(cup))

        case .halo:
            let bob = CGFloat(sin(elapsed * 4.2)) * 1.1 * scale
            let hy = topY - px * 1.9 + bob
            let gold = Color(hex: 0xFBBF24)
            let ring = CGRect(x: center.x - spriteSize * 0.38, y: hy, width: spriteSize * 0.76, height: px * 1.1)
            context.stroke(Path(ellipseIn: ring), with: .color(gold), lineWidth: 1.3 * scale)
            let gleam = CGRect(x: center.x - px * 0.5, y: hy - px * 0.25, width: px, height: px * 0.7)
            context.fill(Path(gleam), with: .color(.white.opacity(0.85)))

        case .crown:
            let gold = Color(hex: 0xFBBF24)
            let baseY = topY - px * 0.9
            let base = CGRect(x: center.x - spriteSize * 0.36, y: baseY, width: spriteSize * 0.72, height: px * 1.1)
            context.fill(Path(base), with: .color(gold))
            let peaks: [CGFloat] = [-spriteSize * 0.34, -px * 0.5, spriteSize * 0.34 - px]
            for (idx, dx) in peaks.enumerated() {
                let h = idx == 1 ? px * 1.55 : px * 1.15
                let peak = CGRect(x: center.x + dx, y: baseY - h + 0.3, width: px, height: h)
                context.fill(Path(peak), with: .color(gold))
            }
            let gem = CGRect(x: center.x - px * 0.42, y: baseY + px * 0.15, width: px * 0.85, height: px * 0.85)
            context.fill(Path(gem), with: .color(Color(hex: 0xFB7185)))
        }
    }

    /// Draws the 2 autonomous pixel Bit Drones for the `.bitDrones` weapon.
    static func drawBitDrones(
        context: inout GraphicsContext,
        center: CGPoint,
        elapsed: Double,
        scale: CGFloat = 1.0
    ) {
        let px = 1.6 * scale
        let bob = CGFloat(sin(elapsed * 6.4)) * 1.3 * scale
        let topPos = CGPoint(x: center.x + 2.0 * scale, y: center.y - 9.2 * scale + bob)
        let botPos = CGPoint(x: center.x + 2.0 * scale, y: center.y + 9.2 * scale - bob)
        for pos in [topPos, botPos] {
            let body = CGRect(x: pos.x - px * 1.1, y: pos.y - px * 0.65, width: px * 2.2, height: px * 1.3)
            let core = CGRect(x: pos.x + px * 0.6, y: pos.y - px * 0.4, width: px * 0.9, height: px * 0.8)
            context.fill(Path(body), with: .color(Color(hex: 0xA78BFA)))
            context.fill(Path(core), with: .color(.white))
        }
    }
}

// MARK: - Agent RPG Character Sheet Popover

struct AgentRPGCharacterPopover: View {
    @Environment(\.prismL10n) private var l10n
    @Bindable var store: AgentRPGStore
    let agent: IslandAgentIdentity

    private enum Tab: String, CaseIterable, Identifiable {
        case overview
        case style
        case gear
        case achievements

        var id: String { rawValue }
    }

    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeTab: Tab = .overview
    @State private var forgeFeedback: String?

    private var zh: Bool {
        l10n.language.resolvedLocale.identifier.lowercased().hasPrefix("zh")
    }

    private var profile: AgentRPGProfile {
        store.profile(for: agent)
    }

    private var stats: AgentRPGStats {
        profile.computeStats(commander: store.commander)
    }

    var body: some View {
        let prof = profile
        let st = stats
        let tier = prof.rankTier

        VStack(spacing: 0) {
            headerSection(profile: prof, stats: st, tier: tier)

            Rectangle().fill(IslandTheme.line).frame(height: 1)

            // Segmented tab bar
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { tab in
                    let isSel = activeTab == tab
                    Button {
                        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                            activeTab = tab
                        }
                    } label: {
                        Text(tabTitle(tab))
                            .font(.system(size: 11, weight: isSel ? .semibold : .medium))
                            .foregroundStyle(isSel ? IslandTheme.text : IslandTheme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isSel ? Color.white.opacity(0.11) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle().fill(IslandTheme.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch activeTab {
                    case .overview:
                        overviewTab(profile: prof, stats: st)
                    case .style:
                        styleTab(profile: prof)
                    case .gear:
                        gearTab(profile: prof)
                    case .achievements:
                        achievementsTab(profile: prof)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 392, height: 500)
        .background(IslandTheme.surface)
        .environment(\.colorScheme, .dark)
    }

    private func tabTitle(_ tab: Tab) -> String {
        switch tab {
        case .overview: return zh ? "总览与属性" : "Overview"
        case .style: return zh ? "武器与外观" : "Style"
        case .gear: return zh ? "装备锻造" : "Gear"
        case .achievements: return zh ? "成就图鉴" : "Medals"
        }
    }

    // MARK: Header & Live Avatar Preview

    private func headerSection(profile prof: AgentRPGProfile, stats st: AgentRPGStats, tier: AgentRankTier) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                AgentAvatarPreviewCanvas(agent: agent, profile: prof)
                    .frame(width: 58, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tier.accentColor.opacity(0.55), lineWidth: 1.2)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(IslandTheme.text)
                            .lineLimit(1)
                        Text("Lv.\(prof.level)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(tier.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tier.accentColor.opacity(0.18)))
                        Text(tier.title(zh: zh))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(IslandTheme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }

                    // XP bar
                    VStack(alignment: .leading, spacing: 2) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(tier.accentColor)
                                    .frame(width: max(3, geo.size.width * prof.levelProgress))
                            }
                        }
                        .frame(height: 5)

                        HStack(spacing: 8) {
                            Text("XP \(prof.xp) / \(prof.xpToNextLevel)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(IslandTheme.tertiary)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                            Text(zh ? "羁绊 Lv.\(prof.bondLevel)" : "Bond Lv.\(prof.bondLevel)")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(IslandTheme.prismCobalt)
                        }
                    }

                    // Key numeric badges: PWR, DPS, Stardust, Damage Numbers toggle
                    HStack(spacing: 6) {
                        metricPill(label: "PWR", value: "\(st.powerScore)", color: Color(hex: 0xFBBF24))
                        metricPill(label: "DPS", value: "\(st.estimatedDPS)", color: Color(hex: 0x38BDF8))
                        metricPill(label: "✦", value: "\(prof.stardust)", color: Color(hex: 0xC084FC))
                        Spacer(minLength: 0)
                        Button {
                            store.showDamageNumbers.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: store.showDamageNumbers ? "textformat.123" : "eye.slash")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(zh ? (store.showDamageNumbers ? "跳字开" : "跳字关") : (store.showDamageNumbers ? "Nums On" : "Nums Off"))
                                    .font(.system(size: 9.5, weight: .medium))
                            }
                            .foregroundStyle(store.showDamageNumbers ? IslandTheme.success : IslandTheme.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill((store.showDamageNumbers ? IslandTheme.success : Color.white).opacity(0.10))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
    }

    private func metricPill(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color.opacity(0.85))
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(IslandTheme.text)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.12)))
    }

    // MARK: Tab 1 — Overview & 8 Stats + Skills + Combat Log

    private func overviewTab(profile prof: AgentRPGProfile, stats st: AgentRPGStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sarto Commander Aura strip
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandTheme.prismCobalt)
                VStack(alignment: .leading, spacing: 1) {
                    Text(zh ? "Sarto 指挥官 Lv.\(store.commander.level)" : "Sarto Commander Lv.\(store.commander.level)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandTheme.text)
                    Text(zh
                         ? "全员光环：ATK +\((store.commander.level - 1) * 2)% · 当前连击 ×\(prof.combo)（倍率 \(String(format: "%.1fx", prof.comboMultiplier))）"
                         : "Squad Aura: ATK +\((store.commander.level - 1) * 2)% · Combo ×\(prof.combo) (\(String(format: "%.1fx", prof.comboMultiplier)))")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandTheme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(IslandTheme.prismCobalt.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(IslandTheme.prismCobalt.opacity(0.25), lineWidth: 0.8))

            sectionHeader(zh ? "八维实战属性（真实工作自动养成）" : "8-Stat Combat Profile (Real Telemetry)")

            let statRows: [(code: String, name: String, value: String, hint: String, ratio: Double, color: Color)] = [
                ("ATK", zh ? "攻击" : "Attack", "\(st.atk)", zh ? "编辑代码" : "Edits", min(1, Double(st.atk) / 360.0), Color(hex: 0xFB7185)),
                ("SPD", zh ? "攻速" : "Speed", "\(st.spd)", zh ? "输出TPS" : "TPS", min(1, Double(st.spd) / 180.0), Color(hex: 0x38BDF8)),
                ("CRIT", zh ? "暴击" : "Crit", "\(Int((st.critRate * 100).rounded()))%", zh ? "搜索阅读" : "Reads", st.critRate / 0.80, Color(hex: 0xFBBF24)),
                ("CDMG", zh ? "暴伤" : "CritDmg", "\(Int((st.critDamage * 100).rounded()))%", zh ? "深度思考" : "Think", (st.critDamage - 1.0) / 3.2, Color(hex: 0xF97316)),
                ("PEN", zh ? "破甲" : "Pierce", "\(st.pen)", zh ? "命令终端" : "Shell", min(1, Double(st.pen) / 180.0), Color(hex: 0xA78BFA)),
                ("SYN", zh ? "协战" : "Synergy", "\(st.syn)", zh ? "Sarto羁绊" : "Bond", min(1, Double(st.syn) / 220.0), Color(hex: 0x60A5FA)),
                ("ECO", zh ? "灵能CDR" : "CDR", "-\(Int((st.eco * 100).rounded()))%", zh ? "缓存命中" : "Cache", st.eco / 0.42, Color(hex: 0x34D399)),
                ("LUK", zh ? "幸运" : "Luck", "\(st.luk)", zh ? "全清/成就" : "Clears", min(1, Double(st.luk) / 160.0), Color(hex: 0xF472B6)),
            ]

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 7) {
                ForEach(statRows, id: \.code) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(row.code)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(row.color)
                            Text(row.name)
                                .font(.system(size: 10))
                                .foregroundStyle(IslandTheme.secondary)
                            Spacer(minLength: 2)
                            Text(row.value)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(IslandTheme.text)
                                .monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(row.color.opacity(0.85)).frame(width: max(3, geo.size.width * row.ratio))
                            }
                        }
                        .frame(height: 3.5)
                        Text(row.hint)
                            .font(.system(size: 9))
                            .foregroundStyle(IslandTheme.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.035)))
                }
            }

            sectionHeader(zh ? "自动战斗技能" : "Auto Combat Skills")

            VStack(spacing: 6) {
                ForEach(AgentSkillKind.allCases) { skill in
                    let unlocked = skill.isUnlocked(agentLevel: prof.level, bondLevel: prof.bondLevel)
                    HStack(spacing: 8) {
                        Image(systemName: unlocked ? "bolt.circle.fill" : "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(unlocked ? IslandTheme.success : IslandTheme.tertiary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1.5) {
                            HStack(spacing: 6) {
                                Text(skill.name(zh: zh))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(unlocked ? IslandTheme.text : IslandTheme.tertiary)
                                Text(skill.requirementTag(zh: zh))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(unlocked ? IslandTheme.success : IslandTheme.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill((unlocked ? IslandTheme.success : Color.white).opacity(0.10)))
                            }
                            Text(skill.detail(zh: zh))
                                .font(.system(size: 10))
                                .foregroundStyle(unlocked ? IslandTheme.secondary : IslandTheme.tertiary.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(unlocked ? 0.045 : 0.02)))
                }
            }

            sectionHeader(zh ? "实战生涯统计" : "Career Stats")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                careerTile(zh ? "击破 Todo" : "Todos", "\(prof.todosCleared)")
                careerTile(zh ? "全清计划" : "Plans", "\(prof.plansCleared)")
                careerTile(zh ? "最高连击" : "Best Combo", "×\(prof.bestCombo)")
                careerTile(zh ? "峰值速度" : "Peak TPS", prof.peakTPS > 0 ? "\(Int(prof.peakTPS.rounded()))/s" : "-")
                careerTile(zh ? "最佳缓存" : "Best Cache", prof.bestCacheHit > 0 ? "\(Int(prof.bestCacheHit.rounded()))%" : "-")
                careerTile(zh ? "实战工时" : "Combat", formatSeconds(prof.activeSeconds))
            }

            if !prof.recentEvents.isEmpty {
                sectionHeader(zh ? "近期战报" : "Recent Combat Feed")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(prof.recentEvents.prefix(8)) { ev in
                        HStack(spacing: 6) {
                            Image(systemName: ev.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(Color(hex: ev.accentHex))
                                .frame(width: 14)
                            Text(ev.text(zh: zh))
                                .font(.system(size: 10.5))
                                .foregroundStyle(IslandTheme.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.03)))
            }
        }
    }

    // MARK: Tab 2 — Weapons & Cosmetics Transmog

    private func styleTab(profile prof: AgentRPGProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(zh ? "像素武器（实时改变战场弹道）" : "Pixel Weapons (Live Projectiles)")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 7) {
                ForEach(AgentWeaponKind.allCases) { weapon in
                    let unlocked = prof.level >= weapon.unlockLevel
                    let active = prof.activeWeapon == weapon
                    Button {
                        if unlocked {
                            store.selectWeapon(weapon, for: prof.agentId)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Circle().fill(Color(hex: weapon.accentHex)).frame(width: 6, height: 6)
                                Text(weapon.name(zh: zh))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(unlocked ? IslandTheme.text : IslandTheme.tertiary)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if active {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(IslandTheme.success)
                                } else if !unlocked {
                                    Text("Lv.\(weapon.unlockLevel)")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(IslandTheme.tertiary)
                                }
                            }
                            Text(weapon.bonusSummary(zh: zh))
                                .font(.system(size: 9.5))
                                .foregroundStyle(unlocked ? IslandTheme.secondary : IslandTheme.tertiary.opacity(0.75))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Color(hex: weapon.accentHex).opacity(0.14) : Color.white.opacity(unlocked ? 0.04 : 0.018))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(active ? Color(hex: weapon.accentHex).opacity(0.7) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!unlocked)
                }
            }

            sectionHeader(zh ? "头饰装扮" : "Headgear")
            cosmeticChipRow(
                items: AgentHeadgear.allCases.map { ($0.id, $0.name(zh: zh), $0.unlockLevel, prof.activeHeadgear == $0) },
                level: prof.level,
                onSelect: { id in
                    if let pick = AgentHeadgear(rawValue: id) {
                        store.selectHeadgear(pick, for: prof.agentId)
                    }
                }
            )

            sectionHeader(zh ? "背饰与光环" : "Aura & Backpiece")
            cosmeticChipRow(
                items: AgentAura.allCases.map { ($0.id, $0.name(zh: zh), $0.unlockLevel, prof.activeAura == $0) },
                level: prof.level,
                onSelect: { id in
                    if let pick = AgentAura(rawValue: id) {
                        store.selectAura(pick, for: prof.agentId)
                    }
                }
            )

            sectionHeader(zh ? "Todo 终结特效" : "Todo Clear Finisher FX")
            cosmeticChipRow(
                items: AgentFinisherFX.allCases.map { ($0.id, $0.name(zh: zh), $0.unlockLevel, prof.activeFinisher == $0) },
                level: prof.level,
                onSelect: { id in
                    if let pick = AgentFinisherFX(rawValue: id) {
                        store.selectFinisher(pick, for: prof.agentId)
                    }
                }
            )
        }
    }

    private func cosmeticChipRow(
        items: [(id: String, title: String, unlockLevel: Int, active: Bool)],
        level: Int,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(items, id: \.id) { item in
                let unlocked = level >= item.unlockLevel
                Button {
                    if unlocked { onSelect(item.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 10.5, weight: item.active ? .semibold : .medium))
                            .foregroundStyle(item.active ? IslandTheme.text : (unlocked ? IslandTheme.secondary : IslandTheme.tertiary))
                            .lineLimit(1)
                        if !unlocked {
                            Text("L\(item.unlockLevel)")
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(IslandTheme.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(item.active ? IslandTheme.prismCobalt.opacity(0.20) : Color.white.opacity(unlocked ? 0.04 : 0.015))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(item.active ? IslandTheme.prismCobalt.opacity(0.75) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!unlocked)
            }
        }
    }

    // MARK: Tab 3 — Equipment, Stardust Forge & Backpack

    private func gearTab(profile prof: AgentRPGProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stardust Forge bar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zh ? "星尘锻造炉" : "Stardust Forge")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(IslandTheme.text)
                    let untilRare = max(1, 5 - prof.forgePityCount)
                    Text(zh ? "再锻 \(untilRare) 次保底稀有+ · 余额 ✦ \(prof.stardust)" : "Rare+ pity in \(untilRare) · Dust ✦ \(prof.stardust)")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandTheme.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    if let forged = store.forgeGear(for: prof.agentId) {
                        forgeFeedback = zh
                            ? "锻造成功：[\(forged.rarity.name(zh: true))] \(forged.nameZH)"
                            : "Forged: [\(forged.rarity.name(zh: false))] \(forged.nameEN)"
                    }
                } label: {
                    Text(zh ? "✦ \(AgentRPGStore.forgeCost) 锻造" : "✦ \(AgentRPGStore.forgeCost) Forge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(prof.stardust >= AgentRPGStore.forgeCost ? .white : IslandTheme.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                prof.stardust >= AgentRPGStore.forgeCost
                                    ? Color(hex: 0x8B5CF6)
                                    : Color.white.opacity(0.06)
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(prof.stardust < AgentRPGStore.forgeCost)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0x8B5CF6).opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(hex: 0x8B5CF6).opacity(0.28), lineWidth: 0.9))

            if let fb = forgeFeedback {
                Text(fb)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(IslandTheme.success)
            }

            sectionHeader(zh ? "已装备槽位（3 槽）" : "Equipped Slots")
            VStack(spacing: 7) {
                ForEach(AgentGearSlot.allCases) { slot in
                    if let item = prof.equippedItem(for: slot) {
                        gearRowCard(
                            item: item,
                            equipped: true,
                            canReforge: prof.stardust >= AgentRPGStore.reforgeCost,
                            onPrimary: { store.reforgeEquipped(slot: slot, for: prof.agentId) },
                            onSecondary: { store.unequipGear(slot: slot, for: prof.agentId) }
                        )
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: slot.symbolName)
                                .font(.system(size: 11))
                                .foregroundStyle(IslandTheme.tertiary)
                            Text(zh ? "\(slot.name(zh: true)) · 空槽（击破 Todo 或锻造掉落）" : "\(slot.name(zh: false)) · Empty")
                                .font(.system(size: 10.5))
                                .foregroundStyle(IslandTheme.tertiary)
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.025)))
                    }
                }
            }

            HStack {
                sectionHeader(zh ? "战利品背包（\(prof.backpack.count)/40）" : "Backpack (\(prof.backpack.count)/40)")
                Spacer(minLength: 0)
                if prof.backpack.contains(where: { $0.rarity <= .uncommon }) {
                    Button {
                        _ = store.dismantleLowTierGear(maxRarity: .uncommon, for: prof.agentId)
                    } label: {
                        Text(zh ? "一键分解白/绿" : "Scrap Common/Uncommon")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(IslandTheme.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if prof.backpack.isEmpty {
                Text(zh ? "背包暂无多余装备，完成 Todo 或计划后将自动掉落战利品。" : "No spare gear yet. Complete Todos or Plans to earn loot drops.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(IslandTheme.tertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(prof.backpack) { item in
                        gearRowCard(
                            item: item,
                            equipped: false,
                            canReforge: false,
                            onPrimary: { store.equipGear(itemId: item.id, for: prof.agentId) },
                            onSecondary: { store.dismantleGear(itemId: item.id, for: prof.agentId) }
                        )
                    }
                }
            }
        }
    }

    private func gearRowCard(
        item: AgentGearItem,
        equipped: Bool,
        canReforge: Bool,
        onPrimary: @escaping () -> Void,
        onSecondary: @escaping () -> Void
    ) -> some View {
        let rc = item.rarity.color
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: item.slot.symbolName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(rc)
                Text("[\(item.rarity.name(zh: zh))]")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(rc)
                Text(item.displayName(zh: zh))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("GS \(item.gearScore)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(rc)
            }

            HStack(spacing: 5) {
                ForEach(Array(item.affixes.enumerated()), id: \.offset) { _, af in
                    Text(af.kind.formatted(value: af.value, zh: zh))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(IslandTheme.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
                }
                Spacer(minLength: 2)
                if equipped {
                    Button(action: onPrimary) {
                        Text(zh ? "重铸 ✦\(AgentRPGStore.reforgeCost)" : "Roll ✦\(AgentRPGStore.reforgeCost)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(canReforge ? IslandTheme.prismCobalt : IslandTheme.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canReforge)

                    Button(action: onSecondary) {
                        Text(zh ? "卸下" : "Remove")
                            .font(.system(size: 9.5))
                            .foregroundStyle(IslandTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onPrimary) {
                        Text(zh ? "装备" : "Equip")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(IslandTheme.success)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(IslandTheme.success.opacity(0.14)))
                    }
                    .buttonStyle(.plain)

                    Button(action: onSecondary) {
                        Text("+\(item.rarity.dismantleStardust)✦")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xC084FC))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(hex: 0xC084FC).opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rc.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(rc.opacity(0.32), lineWidth: 0.9))
    }

    // MARK: Tab 4 — 22 Achievements Gallery

    private func achievementsTab(profile prof: AgentRPGProfile) -> some View {
        let total = AgentAchievementKind.allCases.count
        let done = prof.unlockedAchievements.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(zh ? "彩蛋成就图鉴" : "Achievement Gallery")
                Spacer()
                Text("\(done) / \(total)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xFBBF24))
            }

            VStack(spacing: 6) {
                ForEach(AgentAchievementKind.allCases) { ach in
                    let unlocked = prof.unlockedAchievements[ach.rawValue] != nil
                    HStack(spacing: 9) {
                        Image(systemName: ach.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(unlocked ? Color(hex: 0xFBBF24) : IslandTheme.tertiary.opacity(0.55))
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill((unlocked ? Color(hex: 0xFBBF24) : Color.white).opacity(unlocked ? 0.16 : 0.04))
                            )
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(ach.title(zh: zh))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(unlocked ? IslandTheme.text : IslandTheme.tertiary)
                            Text(ach.requirement(zh: zh))
                                .font(.system(size: 9.5))
                                .foregroundStyle(unlocked ? IslandTheme.secondary : IslandTheme.tertiary.opacity(0.75))
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("+\(ach.rewardXP) XP")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(unlocked ? IslandTheme.success : IslandTheme.tertiary)
                            Text("+\(ach.rewardStardust) ✦")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(unlocked ? Color(hex: 0xC084FC) : IslandTheme.tertiary)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(unlocked ? 0.05 : 0.018))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(unlocked ? Color(hex: 0xFBBF24).opacity(0.28) : Color.clear, lineWidth: 0.8)
                    )
                }
            }
        }
    }

    // MARK: Small UI Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(IslandTheme.secondary)
            .textCase(nil)
    }

    private func careerTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(IslandTheme.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(IslandTheme.text)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.035)))
    }

    private func formatSeconds(_ secs: Double) -> String {
        let total = max(0, Int(secs))
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h\(mins % 60)m"
    }
}

/// Animated live mini-stage inside the Character Popover showing the Agent with equipped gear/cosmetics.
private struct AgentAvatarPreviewCanvas: View {
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let agent: IslandAgentIdentity
    let profile: AgentRPGProfile

    private func drawAvatar(
        context: inout GraphicsContext,
        size: CGSize,
        t: Double,
        sprite: IslandPixelSprite,
        palette: [Color]
    ) {
        let bob = t == 0 ? 0 : CGFloat(sin(t * 4.2)) * 1.4
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.54 + bob)
        let spriteSize: CGFloat = 24

        AgentPixelArtRenderer.drawAura(
            context: &context,
            aura: profile.activeAura,
            center: center,
            spriteSize: spriteSize,
            elapsed: t,
            palette: palette,
            scale: 1.35
        )

        let n = CGFloat(sprite.gridSize)
        let step = spriteSize / n
        let gap: CGFloat = 0.25
        let ox = center.x - spriteSize * 0.5
        let oy = center.y - spriteSize * 0.5
        for cell in sprite.cells {
            let r = CGRect(
                x: ox + CGFloat(cell.gx) * step,
                y: oy + CGFloat(cell.gy) * step,
                width: max(1.1, step - gap),
                height: max(1.1, step - gap)
            )
            context.fill(Path(r), with: .color(cell.color))
        }

        AgentPixelArtRenderer.drawHeadgear(
            context: &context,
            headgear: profile.activeHeadgear,
            center: center,
            spriteSize: spriteSize,
            elapsed: t,
            scale: 1.35
        )

        if profile.activeWeapon == .bitDrones {
            AgentPixelArtRenderer.drawBitDrones(
                context: &context,
                center: center,
                elapsed: t,
                scale: 1.25
            )
        }
    }

    var body: some View {
        let sprite = IslandPixelSpriteCache.sprite(for: agent)
        let palette = sprite.palette.isEmpty ? [IslandTheme.prismCobalt, IslandTheme.prismIris] : sprite.palette
        let effectiveFPS = (reduceMotion || motionTier == .off)
            ? 0
            : PrismEnergyPolicy.framesPerSecond(
                for: .streaming,
                surface: .widget,
                displayMaxFPS: 30,
                conditions: PrismEnergyMonitor.shared.conditions
            )

        if effectiveFPS <= 0 {
            Canvas { context, size in
                drawAvatar(context: &context, size: size, t: 0, sprite: sprite, palette: palette)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / Double(effectiveFPS))) { timeline in
                Canvas { context, size in
                    drawAvatar(
                        context: &context,
                        size: size,
                        t: timeline.date.timeIntervalSinceReferenceDate,
                        sprite: sprite,
                        palette: palette
                    )
                }
            }
        }
    }
}

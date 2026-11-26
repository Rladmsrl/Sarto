import Foundation
import Observation
import PrismDesign
import SartoProtocol
import SwiftUI

/// The idle game as the daemon relays it. The game service computes every number and every hit;
/// this keeps the latest state, plays battle events 350 ms behind game time to absorb 100-200 ms
/// network RTT and jitter smoothly, and dispatches player commands with immediate busy feedback.
@MainActor
@Observable
final class GameStore {
    private(set) var status: GameLinkStatusInfo?
    private(set) var state: GameStateInfo?
    private(set) var busy = false
    private(set) var lastCommandError: String?
    private(set) var lastClaimedReport: GameReportInfo?
    private(set) var liveUlt: Int = 0

    @ObservationIgnored var onWatchChanged: ((Bool) -> Void)?
    @ObservationIgnored var onSendCommand: ((String, [String: JSONValue]) async -> GameCommandOutcome)?
    @ObservationIgnored var onOpenExpedition: (() -> Void)?

    /// Shown once the daemon reaches a game service for a signed-in account and a state came.
    var visible: Bool { status?.enabled == true && state != nil }

    struct Popup {
        var text: String
        var crit: Bool
        var big: Bool
        var born: Date
    }

    struct Shot {
        var kind: String
        var born: Date
    }

    struct Display {
        var target: GameTarget?
        var popups: [Popup] = []
        var shots: [Shot] = []
        var kills = 0
        var banner: (text: String, born: Date)?
        var lastHit: Date?
    }

    /// Game time minus local time, in ms, from the latest state.
    @ObservationIgnored private var clockOffset: Double = 0
    @ObservationIgnored private var pending: [GameBattleEvent] = []
    @ObservationIgnored private var displays: [String: Display] = [:]
    @ObservationIgnored private var activeSurfaces = 0

    /// 200 ms server tick + 150 ms jitter buffer keeps 100-200 ms cloud links smooth without stutter.
    private static let delayMs: Double = 350
    private static let staleMs: Double = 2500
    private static let popupLife: TimeInterval = 0.85
    private static let shotLife: TimeInterval = 0.22
    private static let maxPending = 400

    func openExpedition() {
        onOpenExpedition?()
    }

    func clearError() {
        lastCommandError = nil
    }

    func dismissClaimedReport() {
        lastClaimedReport = nil
    }

    @discardableResult
    func send(_ type: String, args: [String: JSONValue] = [:]) async -> Bool {
        guard !busy, let onSendCommand else { return false }
        busy = true
        lastCommandError = nil
        let outcome = await onSendCommand(type, args)
        busy = false
        if let next = outcome.state {
            applyState(next)
        }
        if let rep = outcome.report {
            lastClaimedReport = rep
        }
        if !outcome.ok {
            lastCommandError = outcome.error ?? "Command failed"
        }
        return outcome.ok
    }

    func setSurfaceVisible(_ shown: Bool) {
        let wasWatching = activeSurfaces > 0
        activeSurfaces = max(0, activeSurfaces + (shown ? 1 : -1))
        let isWatching = activeSurfaces > 0
        if isWatching != wasWatching {
            if !isWatching { pending.removeAll() }
            onWatchChanged?(isWatching)
        }
    }

    func apply(_ event: HostEvent) {
        switch event {
        case .gameStatus(let next):
            if next != status { status = next }
            if !next.enabled {
                state = nil
                liveUlt = 0
                pending.removeAll()
                displays.removeAll()
            }
        case .gameFrame(.state(let next)):
            applyState(next)
        case .gameFrame(.battle(let events)):
            guard activeSurfaces > 0 else { return }
            pending.append(contentsOf: events)
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        default:
            break
        }
    }

    private func applyState(_ next: GameStateInfo) {
        clockOffset = next.serverNow - Date().timeIntervalSince1970 * 1000
        if next != state { state = next }
        liveUlt = next.ult
        var main = displays["main"] ?? Display()
        if !pending.contains(where: { $0.lane == "main" }) || main.target == nil {
            main.target = next.boss ?? next.monster
        }
        displays["main"] = main
        var run = displays["run"] ?? Display()
        if !pending.contains(where: { $0.lane == "run" }) || run.target == nil {
            run.target = next.runTarget
        }
        displays["run"] = run
    }

    /// The lane to show: a Hackathon fight while one runs, else the mainline.
    var lane: String { state?.runStatus == "fighting" ? "run" : "main" }

    var fightingEliteOrBoss: Bool {
        guard let state else { return false }
        if state.runStatus == "fighting", let run = state.hackathon.run {
            return run.boss != nil || run.node == "elite"
        }
        return state.boss != nil || state.monster?.elite == true
    }

    /// Approximate server game timestamp right now, in ms.
    func estimatedServerNow(at date: Date = Date()) -> Double {
        date.timeIntervalSince1970 * 1000 + clockOffset
    }

    /// Plays the events due by `date` and returns what to draw.
    func frame(at date: Date) -> Display {
        let gameNow = date.timeIntervalSince1970 * 1000 + clockOffset - Self.delayMs
        pending.removeAll { $0.at < gameNow - Self.staleMs }
        pending.sort { $0.at < $1.at }
        var index = 0
        while index < pending.count, pending[index].at <= gameNow {
            play(pending[index], now: date)
            index += 1
        }
        if index > 0 { pending.removeFirst(index) }
        let name = lane
        var display = displays[name] ?? Display()
        display.popups.removeAll { date.timeIntervalSince($0.born) > Self.popupLife }
        display.shots.removeAll { date.timeIntervalSince($0.born) > Self.shotLife }
        if let banner = display.banner, date.timeIntervalSince(banner.born) > 1.8 { display.banner = nil }
        displays[name] = display
        return display
    }

    private func play(_ event: GameBattleEvent, now: Date) {
        var display = displays[event.lane] ?? Display()
        if let ult = event.ult, event.lane == lane {
            liveUlt = ult
        }
        switch event.kind {
        case "spawn", "bossStart":
            display.target = GameTarget(
                name: event.monster ?? "",
                hp: event.hp ?? 1,
                maxHp: max(1, event.maxHp ?? 1),
                elite: event.elite || event.kind == "bossStart"
            )
        case "bossPhase":
            if let phase = event.text {
                display.banner = (phase, now)
            }
        case "hit", "double", "tool", "ult":
            if let hp = event.hp {
                if display.target == nil, let maxHp = event.maxHp {
                    display.target = GameTarget(name: event.monster ?? "", hp: hp, maxHp: maxHp, elite: event.elite)
                } else {
                    display.target?.hp = hp
                }
            }
            display.shots.append(Shot(kind: event.kind, born: now))
            if let damage = event.damage {
                display.popups.append(Popup(
                    text: event.kind == "tool" ? "MCP \(damage)" : "\(damage)",
                    crit: event.crit || event.kind == "ult",
                    big: event.kind == "ult",
                    born: now
                ))
            }
            display.lastHit = now
            if event.kind == "ult" { display.banner = (event.perfect ? "Ship it! ×1.5" : "Ship it!", now) }
        case "miss":
            display.popups.append(Popup(text: "miss", crit: false, big: false, born: now))
        case "kill":
            display.kills += 1
            display.target = nil
        case "stageClear":
            display.banner = ("\(event.text ?? "") ✓", now)
        case "bossEnd", "waveEnd":
            display.target = nil
        default:
            break
        }
        if display.popups.count > 8 { display.popups.removeFirst(display.popups.count - 8) }
        if display.shots.count > 6 { display.shots.removeFirst(display.shots.count - 6) }
        displays[event.lane] = display
    }
}

/// Shared procedural pixel arena renderer. Every Agent weapon has its own silhouette, color and
/// projectile style while keeping identical underlying combat numbers.
enum GameArenaRenderer {
    enum WeaponVisual {
        case katana      // codex: cobalt diff blade
        case runeStaff   // claude-code: amber review staff
        case drone       // antigravity: iris orbital drone
        case lance       // deepseek / opencode: emerald spear
        case blaster     // default / pi / qwen / goose / cline: coral pulse caster
    }

    static func visual(for harness: String?, tokens: PrismTokens) -> (WeaponVisual, Color) {
        switch harness {
        case "claude-code": return (.runeStaff, tokens.prismAmber)
        case "codex": return (.katana, tokens.prismCobalt)
        case "antigravity": return (.drone, tokens.prismIris)
        case "deepseek", "opencode": return (.lance, tokens.success)
        case "pi", "qwen", "goose", "cline": return (.blaster, tokens.prismCoral)
        default: return (.katana, tokens.prismCobalt)
        }
    }

    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        display: GameStore.Display,
        weaponHarness: String?,
        tokens: PrismTokens,
        l10n: PrismL10n,
        now: Date,
        still: Bool,
        compact: Bool
    ) {
        let scale: CGFloat = compact ? 1.0 : 1.45
        let ground = size.height - (compact ? 8 : 14)

        // Subtle ground baseline
        context.fill(
            Path(CGRect(x: 0, y: ground, width: size.width, height: 1)),
            with: .color(tokens.borderEtched)
        )

        let lunge: CGFloat = {
            guard !still, let hit = display.lastHit else { return 0 }
            let t = now.timeIntervalSince(hit)
            return t < 0.15 ? CGFloat(6 * scale * (1 - t / 0.15)) : 0
        }()
        let bob: CGFloat = still ? 0 : CGFloat(sin(now.timeIntervalSinceReferenceDate * 4.5)) * 1.2 * scale

        let heroW = 12 * scale
        let heroH = 18 * scale
        let heroX = (compact ? 16 : 34) + lunge
        let hero = CGRect(x: heroX, y: ground - heroH + bob, width: heroW, height: heroH)
        context.fill(Path(roundedRect: hero, cornerRadius: 2 * scale), with: .color(tokens.prismCobalt))
        context.fill(
            Path(CGRect(x: hero.minX + 3 * scale, y: hero.minY + 4 * scale, width: 6 * scale, height: 3.5 * scale)),
            with: .color(tokens.surface1)
        )

        // Distinct Agent weapon silhouette & idle motion
        let (style, weaponColor) = visual(for: weaponHarness, tokens: tokens)
        drawWeapon(
            context: &context,
            style: style,
            color: weaponColor,
            hero: hero,
            scale: scale,
            now: now,
            still: still
        )

        let targetAnchorX = size.width - (compact ? 42 : 76)
        if let target = display.target {
            let isBoss = target.name == "merge-conflict-hydra" || target.name == "429-colossus"
            let w: CGFloat = (isBoss ? 28 : (target.elite ? 24 : 17)) * scale
            let body = CGRect(x: targetAnchorX - w / 2, y: ground - w, width: w, height: w)
            let mColor = isBoss ? tokens.danger : monsterColor(target.name, tokens: tokens)
            context.fill(Path(roundedRect: body, cornerRadius: 4 * scale), with: .color(mColor))
            context.fill(
                Path(CGRect(x: body.minX + w * 0.2, y: body.minY + w * 0.3, width: w * 0.18, height: w * 0.18)),
                with: .color(tokens.surface1)
            )
            context.fill(
                Path(CGRect(x: body.maxX - w * 0.38, y: body.minY + w * 0.3, width: w * 0.18, height: w * 0.18)),
                with: .color(tokens.surface1)
            )
            if isBoss {
                let headW = w * 0.42
                context.fill(
                    Path(roundedRect: CGRect(x: body.minX - headW * 0.65, y: body.minY - headW * 0.35, width: headW, height: headW), cornerRadius: 3),
                    with: .color(tokens.prismCoral)
                )
                context.fill(
                    Path(roundedRect: CGRect(x: body.maxX - headW * 0.35, y: body.minY - headW * 0.35, width: headW, height: headW), cornerRadius: 3),
                    with: .color(tokens.prismAmber)
                )
            }

            let barW: CGFloat = compact ? 74 : 132
            let bar = CGRect(x: size.width - barW - 12, y: compact ? 5 : 10, width: barW, height: compact ? 3.5 : 5)
            context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(tokens.border))
            let share = max(0, min(1, CGFloat(target.hp) / CGFloat(max(1, target.maxHp))))
            context.fill(
                Path(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * share, height: bar.height), cornerRadius: 2),
                with: .color(tokens.danger)
            )
            let monsterName = l10n.tr("game.monster.\(target.name)")
            context.draw(
                Text(compact ? monsterName : "\(monsterName)  \(target.hp)/\(target.maxHp)")
                    .font(.system(size: compact ? 9 : 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground),
                at: CGPoint(x: bar.minX, y: bar.maxY + (compact ? 9 : 11)),
                anchor: .leading
            )
        }

        // Distinct weapon projectiles
        if !still {
            let startX = hero.maxX + 6 * scale
            let endX = targetAnchorX - 10 * scale
            for shot in display.shots {
                let k = CGFloat(min(1, max(0, now.timeIntervalSince(shot.born) / 0.22)))
                let x = startX + (endX - startX) * k
                let y = ground - (shot.kind == "tool" ? 20 : 12) * scale
                let shotColor: Color = shot.kind == "ult"
                    ? tokens.prismAmber
                    : (shot.kind == "tool" ? tokens.success : weaponColor)
                let sw: CGFloat = (shot.kind == "ult" ? 12 : 6) * scale
                let sh: CGFloat = (shot.kind == "ult" ? 5 : 2.5) * scale
                context.fill(Path(roundedRect: CGRect(x: x, y: y, width: sw, height: sh), cornerRadius: 1.5), with: .color(shotColor))
            }
        }

        for (i, popup) in display.popups.enumerated() {
            let age = now.timeIntervalSince(popup.born)
            let rise = still ? 0 : CGFloat(age) * 20 * scale
            let x = targetAnchorX - 24 * scale + CGFloat((i * 15) % 36)
            var ctx = context
            ctx.opacity = max(0, 1 - age / 0.85)
            ctx.draw(
                Text(popup.text)
                    .font(.system(size: (popup.big ? 13 : popup.crit ? 11.5 : 9.5) * (compact ? 1 : 1.15), weight: .bold, design: .monospaced))
                    .foregroundStyle(popup.crit ? tokens.prismAmber : tokens.foreground),
                at: CGPoint(x: x, y: ground - 24 * scale - rise)
            )
        }

        if let banner = display.banner {
            let localized = l10n.tr("game.phase.\(banner.text)")
            let text = localized.hasPrefix("game.phase.") ? banner.text : localized
            context.draw(
                Text(text)
                    .font(.system(size: compact ? 11 : 13, weight: .bold))
                    .foregroundStyle(tokens.prismAmber),
                at: CGPoint(x: size.width / 2, y: compact ? 12 : 18)
            )
        }

        context.draw(
            Text(l10n.tr("game.strip.kills", "\(display.kills)"))
                .font(.system(size: compact ? 9 : 10, design: .monospaced))
                .foregroundStyle(tokens.mutedForeground),
            at: CGPoint(x: compact ? 8 : 12, y: compact ? 9 : 13),
            anchor: .leading
        )
    }

    private static func drawWeapon(
        context: inout GraphicsContext,
        style: WeaponVisual,
        color: Color,
        hero: CGRect,
        scale: CGFloat,
        now: Date,
        still: Bool
    ) {
        switch style {
        case .katana:
            let blade = CGRect(x: hero.maxX + 1.5 * scale, y: hero.midY - 6 * scale, width: 3 * scale, height: 11 * scale)
            let guardRect = CGRect(x: hero.maxX, y: hero.midY + 2 * scale, width: 6 * scale, height: 2 * scale)
            context.fill(Path(blade), with: .color(color))
            context.fill(Path(guardRect), with: .color(color.opacity(0.8)))
        case .runeStaff:
            let shaft = CGRect(x: hero.maxX + 2 * scale, y: hero.minY - 2 * scale, width: 2 * scale, height: hero.height + 2 * scale)
            let gem = CGRect(x: hero.maxX + 0.5 * scale, y: hero.minY - 5 * scale, width: 5 * scale, height: 5 * scale)
            context.fill(Path(shaft), with: .color(color.opacity(0.75)))
            context.fill(Path(roundedRect: gem, cornerRadius: 2 * scale), with: .color(color))
        case .drone:
            let orbitY = still ? 0 : CGFloat(sin(now.timeIntervalSinceReferenceDate * 6.0)) * 2.5 * scale
            let droneBody = CGRect(x: hero.maxX + 2 * scale, y: hero.minY - 6 * scale + orbitY, width: 7 * scale, height: 5 * scale)
            let wing = CGRect(x: droneBody.minX - 2 * scale, y: droneBody.minY - 1.5 * scale, width: 11 * scale, height: 1.5 * scale)
            context.fill(Path(roundedRect: droneBody, cornerRadius: 2 * scale), with: .color(color))
            context.fill(Path(wing), with: .color(color.opacity(0.7)))
        case .lance:
            let spear = CGRect(x: hero.maxX + 1 * scale, y: hero.midY - 1.5 * scale, width: 11 * scale, height: 2.5 * scale)
            let tip = CGRect(x: spear.maxX, y: spear.minY - 1 * scale, width: 3.5 * scale, height: 4.5 * scale)
            context.fill(Path(spear), with: .color(color.opacity(0.8)))
            context.fill(Path(tip), with: .color(color))
        case .blaster:
            let barrel = CGRect(x: hero.maxX + 1 * scale, y: hero.midY - 2 * scale, width: 7.5 * scale, height: 4 * scale)
            let muzzle = CGRect(x: barrel.maxX, y: barrel.minY + 0.8 * scale, width: 2 * scale, height: 2.4 * scale)
            context.fill(Path(roundedRect: barrel, cornerRadius: 1 * scale), with: .color(color))
            context.fill(Path(muzzle), with: .color(color.opacity(0.75)))
        }
    }

    private static func monsterColor(_ name: String, tokens: PrismTokens) -> Color {
        let palette = [tokens.prismCoral, tokens.prismIris, tokens.prismAmber, tokens.success, tokens.prismCobalt, tokens.danger]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

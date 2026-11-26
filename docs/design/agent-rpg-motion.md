# Agent RPG motion and effects

The old local Agent RPG (per-agent levels, the Sarto commander, stardust, gear, weapons, auto
skills, damage numbers, the character popover and achievements) is gone; the server-driven game in
`apps/apple/macOS/Game` replaces it. This document keeps its motion and effects design, so the new
game can rebuild any of them without the old code.

The full code is in git at commit `1108775`:

| Path                                                       | What it held                                                                   |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `apps/apple/macOS/RunningSessionsRail.swift`               | The rail, the todo battle card, its canvas and simulation, with the RPG layers |
| `apps/apple/macOS/AgentRPG/AgentRPGModels.swift`           | Rank tiers, weapons, cosmetics, skills, gear, stats, the damage roll           |
| `apps/apple/macOS/AgentRPG/AgentRPGStore.swift`            | Progression from work facts, loot, achievements, the save file                 |
| `apps/apple/macOS/AgentRPG/AgentRPGCharacterPopover.swift` | `AgentPixelArtRenderer` (auras, headgear, drones) and the character popover    |

Recover any of them with `git show 1108775:<path>`, for example
`git show 1108775:apps/apple/macOS/RunningSessionsRail.swift`.

## Contents

1. [Layers: what stays and what went](#1-layers-what-stays-and-what-went)
2. [Motion tiers](#2-motion-tiers)
3. [Stage geometry](#3-stage-geometry)
4. [Base todo battle (stays)](#4-base-todo-battle-stays)
5. [RPG layers (removed)](#5-rpg-layers-removed)
6. [Fitting the effects to the new game](#6-fitting-the-effects-to-the-new-game)

## 1. Layers: what stays and what went

The todo battle is the dark card the running rail shows for a session with a plan: a pixel Sarto
and the agent's pixel mark on the left fire at a node beside the active Todo row, and switch
targets as steps complete. It is drawn by `RailTodoBattleCanvas` with the physics in
`RailTodoBattleSimulation`. The RPG drew on top of it through an `AgentBattleLoadout` snapshot,
and only at the `arcade` motion tier.

| Effect                                                 | Layer | Still in `RunningSessionsRail.swift` |
| ------------------------------------------------------ | ----- | ------------------------------------ |
| Squad sprites, recoil, squash, flash, breathe, hop     | Base  | Yes                                  |
| Sarto's bottom-up charge overlay                       | Base  | Yes                                  |
| Squad spring glide between rows, glide trail sparks    | Base  | Yes                                  |
| Agent pulse shots (the `pulseBlaster` look)            | Base  | Yes                                  |
| Sarto buff pulse and arcing support lob, overdrive lob | Base  | Yes                                  |
| Impact sparks, target hit flash, recoil, charge ring   | Base  | Yes                                  |
| Periodic crit shockwave                                | Base  | Yes                                  |
| Todo cleared finisher (the `emeraldWave` look)         | Base  | Yes                                  |
| Speed lines (white)                                    | Base  | Yes                                  |
| Missing pixels on the agent's launch edge              | Base  | Yes                                  |
| Target nodes (done, active, pending), the dashed track | Base  | Yes                                  |
| Waiting amber "!" and the static frame                 | Base  | Yes                                  |
| Weapons other than `pulseBlaster`                      | RPG   | No                                   |
| Rail beams (orbital beam, prism combo superbeam)       | RPG   | No                                   |
| Lightning arcs (arc staff, chain arc)                  | RPG   | No                                   |
| Auto skills                                            | RPG   | No                                   |
| Finisher variants (fireworks, prism slash, glitch)     | RPG   | No                                   |
| Damage number and status popups (`+XP`, `LV UP!`)      | RPG   | No                                   |
| Level-up flash and badge                               | RPG   | No                                   |
| Commander badge, buff (gold speed lines, halo)         | RPG   | No                                   |
| Auras, headgear, bit drones                            | RPG   | No                                   |
| Character popover and its animated sprite              | RPG   | No                                   |
| Rank tier colors                                       | RPG   | No                                   |

## 2. Motion tiers

`IslandMotionStyle` had four tiers; it now has three (`lively`, `calm`, `still`), and a stored
`arcade` reads as `lively`.

| Tier     | Requested fps | RPG layers | Base battle                                                                              |
| -------- | ------------- | ---------- | ---------------------------------------------------------------------------------------- |
| `arcade` | 60            | On         | Full, with the loadout's rate multipliers                                                |
| `lively` | 60            | Off        | Full                                                                                     |
| `calm`   | 30            | Off        | Intensity x0.68, strike rate x0.72, Sarto rate x0.75, 1 spark per impact, no speed lines |
| `still`  | 0             | Off        | The static frame                                                                         |

The requested rate is never the rate drawn. The canvas asks the energy policy and takes the lower:

```swift
let policyFPS = PrismEnergyPolicy.framesPerSecond(
    for: .streaming, surface: .widget, displayMaxFPS: 60,
    conditions: PrismEnergyMonitor.shared.conditions
)
let effectiveFPS = PrismEnergyPolicy.capped(policyFPS, requestedFPS: Int(motion.framesPerSecond.rounded()))
if reduceMotion || motionTier == .off || effectiveFPS <= 0 || paused || waiting {
    staticCanvas(...)
} else {
    TimelineView(.animation(minimumInterval: 1.0 / Double(max(1, effectiveFPS)), paused: paused)) { ... }
}
```

`reduceMotion` there is the system's Reduce Motion or `!model.animatesStrikes` (the `still` tier).
At commit `1108775` the canvas took the stored tier as it was; the rail now passes
`model.effectiveMotion`, the tier after the app's motion tier and Reduce Motion cap it (`off` or
Reduce Motion make it `still`, `subtle` turns `lively` into `calm`). Note that
`PrismEnergyPolicy.capped` reads a requested rate of 0 as no cap, so `still` relies on the
`reduceMotion` branch, not on the rate, to draw its static frame. A session waiting on the user,
or a suspended model, also draws the static frame, so the animated waiting branches in
`drawBattle` never run in practice.

Within `arcade`, the RPG did not lower anything for the energy policy beyond the frame rate; the
tier simply added layers. When degrading the new game, follow the same order: `still` and Reduce
Motion draw one frame, `calm` halves the rate and thins particles, and only the top tier adds
decorative layers.

## 3. Stage geometry

All numbers are points in the canvas, origin top left, y down. The card is 300 pt wide in the
expanded rail.

| Constant                  | Value | Meaning                                            |
| ------------------------- | ----- | -------------------------------------------------- |
| `rowHeight`               | 24    | One Todo row                                       |
| `rowStride`               | 26    | Row height plus 2 pt spacing                       |
| `topInset`, `bottomInset` | 6     | Arena padding                                      |
| `sartoX`                  | 14    | Sarto sprite center                                |
| `agentX`                  | 35    | Agent sprite center                                |
| `targetX`                 | 80    | Todo node center; row text starts at x = 93        |
| `sartoSize`               | 13    | Sarto sprite side                                  |
| `agentSize`               | 15.5  | Agent sprite side                                  |
| `cell`                    | 2     | Pixel grid particles snap to                       |
| Track x                   | 24.5  | `(sartoX + agentX) / 2`, the dashed vertical track |

Row center: `rowCenterY(i) = topInset + i * rowStride + rowHeight / 2`. Arena height:
`topInset + n * rowHeight + (n - 1) * 2 + bottomInset`. The selected card lists every step; any
other card collapses to the active step alone. The canvas draws nothing below 90 x 16 pt.

Every particle is clipped to stay left of the Todo text (x below about `targetX + 8`), so effects
never cover what the user reads. The active row gets a rounded highlight from x = 70 to the right
edge minus 6, corner 6, filled with cobalt (amber while waiting) at 0.11.

Colors below are hex; the island theme names map to: `prismCobalt` 4C8DF6, `prismIris` 9B72CB,
`prismAmber` F2B84B, `success` 50A37B, `warning` F2B84B, `surface` 050507. New code takes colors
from `PrismTokens`, so map these to tokens when porting.

## 4. Base todo battle (stays)

### 4.1 Simulation step

One `RailTodoBattleSimulation` per card, on the main actor, stepped from the canvas closure with
the timeline's timestamp. `dt = min(0.05, now - last)`; the first frame uses 1/60; a non-positive
delta skips the frame. The first step snaps the squad to the target row.

Randomness is a 64-bit LCG, deterministic per card, so the pattern never depends on the system
random source:

```swift
private var rngState: UInt64 = 0x5A27_070D_0C0B
private func nextUnit() -> Double {
    rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
    let shifted = (rngState >> 11) & 0x1FFFFF_FFFFFFFF
    return Double(shifted) / Double(0x200000_00000000)
}
```

Each step: detect changes, glide the squad, fire while aligned, advance projectiles and resolve
impacts, advance particles, decay impulses.

**Changes.** A different step count with no new completion is an expand or collapse: the squad
snaps to the new row, its velocity and hold reset, and in-flight shots and shockwaves clear. A
higher done count, or step ids newly completed, is a clear: the finisher fires at the cleared
row (the previously active id if it is among the newly completed, else the first newly completed,
else the previous id), a 0.20 s hold starts and the target charge resets. A new active id alone
resets the target charge.

### 4.2 Squad glide

After the hold, the squad follows the active row on a damped spring (stiffness 210, damping 22,
about 14.5 rad/s at a damping ratio of 0.76), integrated semi-implicitly:

```swift
let dy = targetY - squadY
let accel = dy * 210 - squadVy * 22
squadVy += accel * CGFloat(dt)
squadY += squadVy * CGFloat(dt)
if abs(dy) < 0.35 && abs(squadVy) < 1.5 { squadY = targetY; squadVy = 0 }
```

While faster than 30 pt/s, each frame has a 35% chance (while fewer than 42 sparks live) of a
trail spark at the track x +/- 6: `vx` uniform in -16...16, `vy = -squadVy * 0.18`, gravity 40,
life 0.18 s, cobalt, 1.6 pt.

### 4.3 Intensity

Intensity (0...1) scales fire rates, shot speed and speed lines:

```swift
let base: Double = {
    if let tps, tps > 0 { return min(1.0, 0.36 + (tps / 80.0) * 0.64) }
    switch phase {
    case "think", "thinking": return 0.34
    case "read", "search", "fetch": return 0.56
    case "edit", "write", "writing": return 0.78
    default: return status == "starting" ? 0.30 : 0.58
    }
}()
return motion == .calm ? base * 0.68 : base
```

`tps` is the live output speed, only for the session the telemetry follows.

### 4.4 Fire rates

The squad fires only when not waiting, a step is active, the hold is over, and it is within
4.5 pt of the target row. Rates are per second and accumulate in carries (the agent's starts at
0.7, Sarto's at 0.4), so the first shot comes soon after alignment.

| Shooter | Phase               | Rate                               | Per frame cap |
| ------- | ------------------- | ---------------------------------- | ------------- |
| Agent   | think               | `1.9 + 1.1 * i`                    | 2             |
| Agent   | read, search, fetch | `3.0 + 1.6 * i`                    | 2             |
| Agent   | anything else       | `3.4 + 2.8 * i`                    | 2             |
| Agent   | `calm` factor       | x0.72                              |               |
| Sarto   | any                 | `(1.1 + 1.0 * i)`, x0.75 in `calm` | 1             |

At most 32 shots live; a shot past the cap is not fired.

### 4.5 Agent strike (pulse blaster)

Firing sets `agentKick = 1`, and blanks one of the sprite's launch-edge cells for 0.13 s (at most
6 at once; the launch edge is the left half of the agent's grid, cycled by the shot counter).

| Phase               | Color                                     | Speed (pt/s)                     | Tail               | Thick                        |
| ------------------- | ----------------------------------------- | -------------------------------- | ------------------ | ---------------------------- |
| think               | alternates iris 9B72CB and cobalt 4C8DF6  | `135 * U(0.92, 1.12)`            | 2                  | always                       |
| read, search, fetch | alternates 5CC8FF and the agent's palette | `(175 + 95 * i) * U(0.92, 1.12)` | 3, 4 when i > 0.65 | every 6th shot when i > 0.55 |
| other               | the agent's palette, cycled               | same                             | same               | same                         |

The palette is up to six distinct saturated or bright colors of the agent's pixel mark (cobalt and
iris when it has none). Shots launch at `agentX + 7.5`, `squadY + U(-3, 3)`, and aim at
`targetX - 5.5`, `targetY + U(-2.2, 2.2)` on a straight line:

```swift
let dx = max(14, destX - fromX)
let flight = dx / max(60, speed)
let vy = (destY - fromY) / max(0.06, flight)
// vx = speed, gravity 0; the shot hits when x >= destX
```

### 4.6 Sarto support

Each Sarto shot sets `sartoKick = 0.85` and cycles the buff colors 5AA2FF, 86C5FF, 9B72CB. Every
third shot, or any shot once Sarto's charge reaches 0.95, is an arcing lob over the agent;
the others are a buff pulse to the agent.

- **Buff pulse**: from `(sartoX + 6, squadY - 1.5)`, `vx` 110, `vy` 12, tail 2, thin, ending at
  `agentX - 6`. On arrival the agent flashes (`agentFlash = max(_, 0.52)`) and Sarto's charge
  rises by 0.18.
- **Support lob**: from `(sartoX + 6, squadY - 4.5)` to `targetX - 5.5` under gravity 210, tail 3.
  The launch velocity solves the parabola for the flight time:

  ```swift
  let dx = max(24, destX - launchX)
  let speed = CGFloat(155 + 60 * intensity)
  let flight = dx / speed
  let gravity: CGFloat = 210
  let vy = ((targetY - launchY) - 0.5 * gravity * CGFloat(flight * flight)) / max(0.08, flight)
  ```

- **Overdrive lob**: the same lob when the charge is 0.95 or more: white, tail 4, thick; it drops
  the charge to 0.12 and flashes Sarto at 0.95.

Sarto's charge also rises by 0.05 on every impact and drops to 0.2 on every clear.

### 4.7 Impact

A strike or lob reaching the target, or an instant hit, resolves as:

```swift
targetHitFlash = max(targetHitFlash, isHeavy ? 1.0 : 0.72)
targetHitRecoil = max(targetHitRecoil, isHeavy ? 1.0 : 0.65)
targetCharge += isHeavy ? 0.16 : 0.085
sartoCharge = min(1.0, sartoCharge + 0.05)
let sparkCount = calmMode ? 1 : (isHeavy ? 3 : 2)   // while fewer than 48 sparks live
// spark: x = hitX - 1, vx U(-78, -22), vy U(-62, 58), gravity 195, life U(0.16, 0.30),
// first white, the rest the shot's color, side 1.9 heavy / 1.65 light
if targetCharge >= 1.0 {
    targetCharge = 0
    // periodic crit shockwave: from agentX + 7 at the hit y, 0.28 s, white with a palette accent
}
```

Heavy means a thick shot or a Sarto lob. Sparks fly back left, away from the text.

### 4.8 Shockwave

A curved front of pixels sweeps from its origin to the node, growing taller as it goes. Used by
the periodic crit (0.28 s, white and a palette accent) and the clear finisher (0.34 s, success
and white).

```swift
let p = CGFloat(wave.age / wave.duration)
let fade = Double(1.0 - p) * 0.95
let arcHalfH: CGFloat = 5.5 + p * 8.0
let arcDepth: CGFloat = arcHalfH * 0.44
let frontX = wave.originX + p * (targetX - wave.originX + 4)
var dy = -arcHalfH
while dy <= arcHalfH {
    let u = dy / max(1, arcHalfH)
    let wx = snap(frontX - arcDepth * u * u, step: 2)
    let wy = snap(wave.y + dy, step: 2)
    if wx >= agentX + 6 && wx <= targetX + 4 && wy > 1 && wy < size.height - 2 {
        let thickness = abs(u) < 0.55 ? 2 : 1
        for layer in 0..<thickness {
            let px = wx - CGFloat(layer) * 2
            let col = layer == 0 ? wave.color : wave.accent
            context.fill(Path(CGRect(x: px, y: wy, width: 1.75, height: 1.75)),
                         with: .color(col.opacity(fade * (layer == 0 ? 1.0 : 0.65))))
        }
    }
    dy += 2
}
```

### 4.9 Shots on screen

A shot is a pixel trail behind its head, along the reverse of its velocity, every pixel snapped to
the 2 pt grid:

```swift
let speedMag = max(1, hypot(shot.vx, shot.vy))
let ux = shot.vx / speedMag, uy = shot.vy / speedMag
for seg in 0..<shot.tailLength {
    let sx = snap(shot.x - ux * CGFloat(seg) * 2, step: 2)
    let sy = snap(shot.y - uy * CGFloat(seg) * 2, step: 2)
    guard sx >= 6, sx <= targetX + 2, sy > 1, sy < size.height - 2 else { continue }
    let a = max(0.2, 1.0 - Double(seg) / Double(shot.tailLength + 1) * 0.78)
    let side: CGFloat = shot.thick ? 2.1 : 1.7
    context.fill(Path(CGRect(x: sx, y: sy, width: side, height: side)), with: .color(shot.color.opacity(a)))
    if shot.thick && seg < 2 {   // a second pixel one cell below the first two
        context.fill(Path(CGRect(x: sx, y: sy + 2, width: side, height: side)), with: .color(shot.color.opacity(a * 0.7)))
    }
}
```

A shot that leaves x 0...`targetX + 18` or y -8...600 without hitting is dropped.

### 4.10 Sparks

Square pixels of their own size, snapped to the 2 pt grid, under gravity, with a quadratic fade:
`alpha = max(0, 1 - (age / life)^2)`. Clipped to x 2...`targetX + 8` and y 1...`height - 2`.

### 4.11 Speed lines

Four faint horizontal dashes run from the agent toward the node, suggesting forward motion.
Drawn only when not waiting, a step is active, and the tier is not `calm`.

- Each line: `x` in 0...1 along the runway, `yOffset` U(-7, 7), `length` U(5, 11) pt,
  `speed` U(0.9, 1.6) runways per second, `alpha` U(0.05, 0.12).
- Advance: `x += speed * dt * (0.6 + 0.8 * intensity)`; past 1.2 it wraps to -0.2 with a new
  `yOffset`.
- Draw: a `length` x 1 rect at `x' = (agentX + 9) + x * (targetX - agentX - 16)` and
  `snap(squadY + yOffset, 2)`, white at `alpha` (gold FBBF24 under the RPG's commander buff).

### 4.12 Sprites

Both sprites are 14 x 14 cell grids (`IslandPixelSpriteCache`): the agent's mark pixelized from
its harness logo, and `appSprite`, Sarto's icon as a dark tile whose dot matrix brightens toward
the lower right. Cells are drawn as rects a little smaller than their step (gap 0.16 when the
step is at least 1.2 pt, else 0.08).

| Sprite | Side | Recoil x      | Squash (x, y)                        | Anchor                                         | Flash                   |
| ------ | ---- | ------------- | ------------------------------------ | ---------------------------------------------- | ----------------------- |
| Sarto  | 13   | `-1.4 * kick` | `1 - 0.10 * kick`, `1 + 0.10 * kick` | `(sartoX + recoil, squadY - 1.5 + hop * 0.85)` | white at `0.60 * flash` |
| Agent  | 15.5 | `-1.8 * kick` | `1 - 0.11 * kick`, `1 + 0.11 * kick` | `(agentX + recoil, squadY + 0.8 + hop)`        | white at `0.58 * flash` |

Sarto sits a little higher and behind, as a spotter; the agent recoils left as it fires right.

- **Breathe**: `squadY += sin(elapsed * 5.2) * 0.8` while not waiting.
- **Hop**: `hopY = -sin(celebrateHop * 2 * pi) * 3.8` while `celebrateHop > 0`. It decays at 3.6/s
  from 1, so a clear dips the squad about 3.8 pt and then lifts it 3.8 pt in about 0.28 s.
- **Missing pixels**: a blanked launch cell draws at 0.26 opacity, as if the pixel left as the
  shot.
- **Sarto charge**: rows fill bottom-up with the agent's palette as the charge rises:

  ```swift
  let chargedFrom = Double(n - 1) - max(0, min(1, sartoCharge)) * Double(n - 2)
  if Double(cell.gy) >= chargedFrom && cell.gy > 0 && cell.gy < n - 1 {
      let rowColor = palette[(n - 1 - cell.gy) % palette.count]
      ctx.fill(Path(rect), with: .color(rowColor.opacity(cell.luminance > 0.4 ? 0.72 : 0.24)))
  }
  ```

Impulses decay linearly per second:

| Value             | Decay | Set by                            |
| ----------------- | ----- | --------------------------------- |
| `sartoKick`       | 8.5   | 0.85 per Sarto shot, 1 on a clear |
| `sartoFlash`      | 6.5   | 0.95 overdrive, 1 on a clear      |
| `agentKick`       | 9.0   | 1 per strike, 1 on a clear        |
| `agentFlash`      | 7.0   | 0.52 per buff pulse, 1 on a clear |
| `targetHitFlash`  | 7.5   | 0.72 light, 1 heavy               |
| `targetHitRecoil` | 11.0  | 0.65 light, 1 heavy               |
| `celebrateHop`    | 3.6   | 1 on a clear                      |
| clear flash       | 2.0   | 1 per cleared step (0.5 s)        |
| missing pixel     | 1.0   | ttl 0.13 s                        |

### 4.13 Target nodes and track

With more than one step, a dashed track runs down x = 24.5: 1.2 x 2 pt dashes every 5 pt, white at
0.08. Each row has a node at `targetX`:

- **Done**: a 10 pt circle filled with success at `0.20 + clearFlash * 0.35`, stroked success at
  1.25 pt, with a check `(-2.4, 0.2) -> (-0.6, 2.0) -> (2.7, -1.8)` stroked 1.45 pt, round caps,
  white while the clear flash is above 0.3. The node scales by `1 + clearFlash * 0.32`, a pop
  that settles over 0.5 s.
- **Active**: center nudged right by `hitRecoil * 1.6`. An 11 pt circle in cobalt (amber while
  waiting) filled at `0.20 + hitFlash * 0.35`, stroked 1.4 pt. While not waiting, the target
  charge draws as a white 0.75 arc of radius 5.5 from 12 o'clock, `360 * charge` degrees, 1.4 pt
  round. The core is `3.4 + 1.2 * hitFlash` pt (3.2 while waiting), white while the hit flash is
  above 0.25, else the ring color.
- **Pending**: a 9 pt ring, white at 0.24, 1.2 pt.

### 4.14 Todo cleared finisher (emerald wave)

```swift
sartoFlash = 1; agentFlash = 1; sartoKick = 1; agentKick = 1
celebrateHop = 1; sartoCharge = 0.2
for id in clearedIDs { clearFlashes[id] = 1 }
// shockwave from agentX + 6 at the cleared row, 0.34 s, success with a white accent
let burstCount = 10                      // pixelFireworks: 18
let burstColors = [success, white, prismAmber, prismCobalt]
for i in 0..<burstCount where sparks.count < 56 {
    let angle = Double(i) / Double(burstCount) * .pi * 2 + nextUnit() * 0.35
    let spd = nextCGFloat(34, 92)        // pixelFireworks: up to 108
    let vx = min(18, CGFloat(cos(angle)) * spd - 22)   // biased left, off the text
    let vy = CGFloat(sin(angle)) * spd - 14            // biased up
    // spark at (targetX - 1, y), gravity 175, life U(0.28, 0.56),
    // color burstColors[i % count], side 2.1 for every third, else 1.8
}
```

### 4.15 Waiting and the static frame

The static frame (still tier, Reduce Motion, energy policy at 0, paused, or waiting) draws the
track, the squad at the active row with Sarto's charge at 0.45 and no motion, the nodes with the
active charge ring at 0.35, and:

- while not waiting with an active step, three 2.2 pt dots in flight at
  `x = agentX + 12 + i * 9`, `y = targetY - 1`, the first cobalt and the rest the agent's first
  palette color, at 0.75;
- while waiting, an amber pixel "!" above the squad at x = 24.5, y = `targetY - 11`: a 2.2 x 5.2 bar
  from `y - 4` and a 2.2 x 2 dot at `y + 2.4`. (The animated path would bob it by
  `sin(elapsed * 4.5) * 1.4`, but a waiting card always draws the static frame.)

### 4.16 Limits

| What                   | Limit |
| ---------------------- | ----- |
| Shots in flight        | 32    |
| Sparks, glide trail    | 42    |
| Sparks, impacts        | 48    |
| Sparks, finisher burst | 56    |
| Missing pixels         | 6     |
| Strikes per frame      | 2     |
| Speed lines            | 4     |

## 5. RPG layers (removed)

### 5.1 The loadout

The store built an immutable `AgentBattleLoadout` per card per render, so the canvas never read the
store while drawing:

```swift
struct AgentBattleLoadout: Equatable, Sendable {
    let enabled: Bool               // arcade tier
    let showDamageNumbers: Bool     // a toggle in the popover, on by default
    let level: Int
    let bondLevel: Int
    let weapon: AgentWeaponKind
    let headgear: AgentHeadgear
    let aura: AgentAura
    let finisher: AgentFinisherFX
    let stats: AgentRPGStats
    let unlockedSkills: Set<AgentSkillKind>
    let commanderBuffActive: Bool   // 8.5 s after the user granted a permission
    let justLeveledUp: Bool         // 6 s after a level-up
}
```

With `enabled`, the base rates changed:

```swift
strikeRate *= 1.0 + min(0.55, Double(max(0, stats.spd - 18)) * 0.0045)
if commanderBuffActive { strikeRate *= 1.35 }
if unlockedSkills.contains(.overdriveBarrage), intensity > 0.62 || (!isThinking && !isScanning) {
    strikeRate *= 1.22
}
let synBonus = 1.0 + min(0.65, Double(stats.syn) * 0.004)   // Sarto's rate
let cdrFactor = max(0.55, 1.0 - stats.eco)                    // skill cooldowns
```

The `calm` factor never applied with the RPG on, since `arcade` was never calm.

### 5.2 Rank tiers

The agent's level picked a tier, whose accent colored the level badge, its progress bar and the
popover's avatar frame.

| Tier          | Levels | Accent | English                 | Chinese    |
| ------------- | ------ | ------ | ----------------------- | ---------- |
| `apprentice`  | 1-9    | 94A3B8 | Script Apprentice       | 脚本学徒   |
| `ranger`      | 10-19  | 34D399 | Terminal Ranger         | 终端游侠   |
| `knight`      | 20-29  | 38BDF8 | Syntax Knight           | 语法骑士   |
| `blademaster` | 30-39  | 60A5FA | Compiler Blademaster    | 编译剑圣   |
| `archmage`    | 40-54  | A78BFA | Archmage of Systems     | 架构大魔导 |
| `lord`        | 55-69  | F472B6 | Concurrency Lord        | 并发领主   |
| `weaver`      | 70-84  | FBBF24 | Quantum Weaver          | 量子织梦者 |
| `forgemaster` | 85+    | FB7185 | Singularity Forgemaster | 奇点神匠   |

Gear rarities used the same ramp: common 94A3B8, uncommon 34D399, rare 38BDF8, epic A78BFA,
legendary FBBF24, prismatic FB7185.

### 5.3 Weapons

The highest weapon the level unlocked was used unless the user picked another in the popover.
Each changed only how the agent's strike looked and landed; the stat bonus is listed for
completeness. Common values: `launchX = agentX + 7.5`, `destX = targetX - 5.5`, `speed` and
`baseColor` as in 4.5.

| Weapon              | Unlock | Accent | Shot                                                                                                                                                                | Stat bonus           |
| ------------------- | ------ | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `pulseBlaster`      | 1      | 60A5FA | The base strike (4.5)                                                                                                                                               | none                 |
| `twinRepeater`      | 4      | 38BDF8 | Two thin shots, tail 3, speed x1.12: from `squadY -/+ 2.8` to `targetY -/+ 1.6`, in 38BDF8 and `baseColor`                                                          | SPD +8%              |
| `prismScatter`      | 8      | 34D399 | Three thin shots, tail 2, speed x1.05, offsets -4.2, 0, 4.2: from `squadY + off * 0.5` to `targetY + off * 0.55`, in 34D399, white, `baseColor`                     | CRIT +6%             |
| `arcStaff`          | 14     | 67E8F9 | An instant lightning arc (5.5) from `(launchX, squadY)` to `(destX + 1, targetY)` in 67E8F9 and an immediate impact, heavy every third                              | CDMG +15%            |
| `bitDrones`         | 20     | A78BFA | The base shot (tail 3, thin) plus a drone shot from `(agentX + 3, squadY -/+ 9)`, alternating, speed x1.18, A78BFA, tail 3; the drones draw beside the agent (5.11) | ATK x1.12, SYN +10%  |
| `orbitalBeam`       | 28     | FBBF24 | Every third: a rail beam (5.4) from `launchX` to `targetX - 3`, 4.2 thick, 0.22 s, FBBF24, with a heavy impact; else a thick shot, tail 4, speed x1.15, FBBF24      | PEN +20              |
| `quantumSplitter`   | 38     | F472B6 | A thick F472B6 shot, tail 4, that splits into three sparks on hit                                                                                                   | CRIT +10%, CDMG +18% |
| `singularityCannon` | 50     | FB7185 | A vortex orb at speed x0.78, FB7185, heavy                                                                                                                          | ATK x1.22, CRIT +6%  |

Splitter sparks on hit (while fewer than 52 live):

```swift
for k in 0..<3 {
    let angle = -2.4 + Double(k) * 0.65
    // spark at (targetX - 1, shot.y), v = (cos(angle) * 74, sin(angle) * 62), gravity 130,
    // life 0.26, 2.0 pt, white for the middle one, else F472B6
}
```

The vortex orb drew instead of a trail: four pixels orbiting its center and a white core.

```swift
let spin = elapsed * 14.0
for i in 0..<4 {
    let a = spin + Double(i) * (.pi * 0.5)
    let ox = snap(shot.x + CGFloat(cos(a)) * 2.6, step: 1)
    let oy = snap(shot.y + CGFloat(sin(a)) * 2.6, step: 1)
    let c: Color = i % 2 == 0 ? shot.color : Color(hex: 0xA78BFA)
    context.fill(Path(CGRect(x: ox, y: oy, width: 1.9, height: 1.9)), with: .color(c.opacity(0.95)))
}
context.fill(Path(CGRect(x: shot.x - 1, y: shot.y - 1, width: 2.2, height: 2.2)), with: .color(.white))
```

### 5.4 Rail beams

A horizontal bar from the launcher to the node that thins and fades quadratically.

```swift
let p = beam.age / beam.duration
let alpha = max(0, 1.0 - p * p)
let halfH = beam.thickness * 0.5 * CGFloat(1.0 - p * 0.35)
let rect = CGRect(x: beam.startX, y: beam.y - halfH,
                  width: max(4, beam.endX - beam.startX), height: max(1.4, halfH * 2))
if beam.prismatic {
    // three equal bands top to bottom: 38BDF8, white, F472B6, each at least 1.1 pt, alpha * 0.92
} else {
    context.fill(Path(rect), with: .color(beam.color.opacity(alpha * 0.65)))
    let core = rect.insetBy(dx: 0, dy: max(0.4, rect.height * 0.28))
    context.fill(Path(core), with: .color(Color.white.opacity(alpha)))
}
```

### 5.5 Lightning arcs

A jagged polyline of five segments, jittered across its main axis, that lasts 0.14 s.

```swift
var pts: [CGPoint] = [start]
for i in 1..<5 {
    let t = CGFloat(i) / 5
    let bx = start.x + (end.x - start.x) * t
    let by = start.y + (end.y - start.y) * t
    let perpX: CGFloat = abs(end.y - start.y) > abs(end.x - start.x) ? nextCGFloat(-4.5, 4.5) : 0
    let perpY: CGFloat = abs(end.x - start.x) >= abs(end.y - start.y) ? nextCGFloat(-4.5, 4.5) : 0
    pts.append(CGPoint(x: bx + perpX, y: by + perpY))
}
pts.append(end)
// draw: alpha = 1 - age / 0.14; stroke color at alpha * 0.9, 1.8 pt, then white at alpha * 0.75, 0.8 pt
```

### 5.6 Auto skills

Skills fired by themselves while the squad was firing (aligned, not waiting). Cooldowns count down
only then, start partly spent, and reset scaled by `cdrFactor` (5.1).

| Skill              | Unlock    | First after | Cooldown  | Effect                                                                                                                                                                                                                            |
| ------------------ | --------- | ----------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `overdriveBarrage` | Lv 3      | always on   | none      | Strike rate x1.22 while intensity > 0.62 or the phase is not think or scan                                                                                                                                                        |
| `shieldBreaker`    | Lv 6      | 7 s         | 14 s      | A shockwave from `agentX + 6`, 0.32 s, FBBF24 with a white accent, and a heavy skill impact at `targetX - 5`                                                                                                                      |
| `chainArc`         | Lv 12     | 3.5 s       | 5.5 s     | With a next row: a lightning arc from the active node down to the next row's node in 38BDF8, and two sparks there: vx U(-48, -16), vy U(-28, 28), gravity 150, life 0.22, 67E8F9, 1.7 pt                                          |
| `starfallStrike`   | Lv 18     | 9 s         | 16 s      | Three meteors from the top (y 2) at `targetX - 24 + m * 8 + U(-2, 2)`, diving to `(targetX - 4, targetY + U(-2, 2))` in `0.22 + m * 0.05` s: thick, tail 4, FBBF24, white, FBBF24; each a skill impact when it reaches its x or y |
| `sartoPrismCombo`  | Bond Lv 3 | on charge   | on charge | Replaces Sarto's shot at charge 0.95: charge to 0.10, both sprites flash 1, hop 0.55, a prismatic rail beam from `sartoX + 4` to `targetX - 3`, 6.2 thick, 0.30 s, and a heavy skill impact in 38BDF8                             |

Skill impacts were never thinned by `calm`, and forced damage numbers (5.8).

### 5.7 Finisher variants

The clear finisher (4.14) took the agent's chosen finisher:

| Finisher         | Unlock | Change                                                                           |
| ---------------- | ------ | -------------------------------------------------------------------------------- |
| `emeraldWave`    | 1      | The base finisher                                                                |
| `pixelFireworks` | 6      | 18 sparks, speed up to 108, colors FB7185, FBBF24, 34D399, 38BDF8, C084FC, white |
| `prismSlash`     | 16     | Shockwave in 38BDF8; an X slash over the node for 0.36 s                         |
| `glitchShatter`  | 26     | A horizontal glitch over the node for 0.34 s                                     |

```swift
let p = fx.age / fx.duration, alpha = max(0, 1.0 - p)
if fx.isGlitch {
    for row in 0..<5 {
        let jitter = CGFloat(((row * 7 + Int(p * 20)) % 5) - 2) * 3.0
        let y = fx.y - 6 + CGFloat(row) * 2.8
        let col: Color = row % 2 == 0 ? Color(hex: 0x22D3EE) : Color(hex: 0xF472B6)
        context.fill(Path(CGRect(x: fx.x - 8 + jitter, y: y, width: 12, height: 1.6)), with: .color(col.opacity(alpha * 0.9)))
    }
} else {
    let span: CGFloat = 6.5 + CGFloat(p) * 5.0
    // s1: (x - span, y - span) -> (x + span, y + span); s2: (x + span, y - span) -> (x - span, y + span)
    // s1 stroked 38BDF8 and s2 F472B6 at alpha, 2.0 pt; then s1 white at alpha * 0.85, 0.9 pt
}
```

### 5.8 Damage numbers

Floating numbers over the hit, left of the text, at most 5 at once (a new one drops the oldest).
Shown for a crit, a skill, or every second hit. Each roll:

```swift
let variance = 0.88 + nextUnit() * 0.24
var base = Double(atk) * (1.0 + Double(pen) * 0.0055) * variance
if isHeavy { base *= 1.55 }
if isSkill { base *= 2.15 }
if commanderBuff { base *= 1.35 }
let effectiveCrit = min(0.95, critRate + (commanderBuff ? 0.25 : 0) + (isSkill ? 0.20 : 0))
let isCrit = nextUnit() < effectiveCrit
let isSuperCrit = isCrit && nextUnit() < min(0.28, Double(luk) * 0.0032 + (commanderBuff ? 0.12 : 0))
if isSuperCrit { base *= critDamage * 1.42 } else if isCrit { base *= critDamage }
damage = max(1, Int(base.rounded()))
```

| Kind              | Text     | Color         | Font               | Life   |
| ----------------- | -------- | ------------- | ------------------ | ------ |
| Super crit, skill | `★N`     | FB7185        | 9.5 pt heavy, mono | 0.68 s |
| Crit              | `N!`     | FBBF24        | 9.5 pt heavy, mono | 0.68 s |
| Hit               | `N`      | white at 0.88 | 8.2 pt bold, mono  | 0.50 s |
| Todo cleared      | `+XP`    | success       | 9.5 pt heavy, mono | 0.68 s |
| Level-up          | `LV UP!` | FBBF24        | 9.5 pt heavy, mono | 0.68 s |

A hit's popup spawns at `(hitX - 10 + U(-8, 4), hitY - 4 + U(-2, 2))`; `+XP` at
`(targetX - 16, y - 5)`. Motion: it fades in over the first 20% of its life, then out linearly,
and rises 11.5 pt over its life; x is clamped to 20...`targetX - 10`, and it hides outside
y 4...`height - 3`.

```swift
let p = pop.age / pop.life
let alpha = p < 0.2 ? (p / 0.2) : max(0, 1.0 - (p - 0.2) / 0.8)
let py = pop.y - CGFloat(p) * 11.5
```

### 5.9 Level-up

For 6 s after a level-up:

- The rail's level badge reads `LV UP!` and turns emerald 34D399 (text, progress fill, background
  and border).
- On the rising edge, the battle spawns a `LV UP!` popup at `(agentX - 4, squadY - 10)` in FBBF24
  and sets the hop to at least 0.85.

The level badge itself, beside the agent's name in the rail: `Lv.N` at 9.5 pt bold mono in the tier
color over a 2 pt progress capsule (track at 0.20 of the color, fill at least 2 pt wide),
padding 6 x 2.5, at least 42 wide, in a rounded rect of corner 6 filled at 0.12 (0.20 hovered)
and stroked 0.8 pt at 0.35 (0.65 hovered). A gold `bolt.fill` (8 pt bold, FBBF24) led it during a
commander buff. Clicking it opened the character popover toward the leading edge.

### 5.10 Commander

**Badge.** In the rail's header, before the collapse button: a capsule with `sparkles` (9 pt
semibold, cobalt) and `Sarto Lv.N` (10 pt semibold mono, secondary), padding 6 x 2.5, filled cobalt
at 0.11, stroked cobalt at 0.24, 0.7 pt. Its help line read "Sarto Commander Lv.N · Squad ATK
+X% · N Todos commanded", where X is `(level - 1) * 2`.

**Buff.** For 8.5 s after the user granted a permission the agent asked for:

- the speed lines turn gold FBBF24;
- a gold halo pulses around the squad;
- the strike rate rises x1.35 and the damage roll as in 5.8.

```swift
let pulse = 0.25 + 0.20 * sin(elapsed * 10.0)
let halo = CGRect(x: sartoX - 8, y: squadY - 10 + hopY * 0.5, width: 38, height: 21)
context.stroke(Path(roundedRect: halo, cornerRadius: 9), with: .color(Color(hex: 0xFBBF24).opacity(pulse)), lineWidth: 1.2)
```

### 5.11 Auras, headgear and bit drones

`AgentPixelArtRenderer` drew these around the agent's sprite center, behind it (auras) or over it
(headgear, drones), at a `scale` of 1 in the rail and 1.35 (drones 1.25) in the popover. `s` is the
sprite side; `px` is the pixel unit (1.8 * scale for auras, 1.75 * scale for headgear).

| Aura               | Unlock | Look                                                                                                                                                                 |
| ------------------ | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cape`             | 5      | Three vertical strips behind the sprite at x -0.56s, -0.72s, -0.88s, alpha 0.52, 0.36, 0.22 of the brand color, height 0.54s, fluttering by `sin(e * 7.2) * 1.4`     |
| `pixelWings`       | 12     | Four upper and three lower pixels behind it, flapping by `sin(e * 8.4) * 2.1`; secondary at 0.82 with a white 0.72 tip, brand at 0.66 below                          |
| `dataOrbs`         | 20     | Three pixels on an ellipse (r 0.66s, flattened 0.68), 3.1 rad/s, in 38BDF8, A78BFA, 34D399 at 0.88                                                                   |
| `prismOrbit`       | 30     | Ten pixels on an ellipse (rx 0.76s, ry 0.34s), 2.4 rad/s, rainbow 38BDF8, 818CF8, C084FC, F472B6, FBBF24, 34D399; alpha `0.35 + 0.55 * (sin(a) / 2 + 0.5)` for depth |
| `overclockRainbow` | 45     | Eight pixels on a circle breathing `0.62 + 0.14 * sin(e * 6)` of s, 2.8 rad/s, colors FB7185, FBBF24, 34D399, 38BDF8, A78BFA stepping six times a second             |

| Headgear   | Unlock | Look                                                                                                          |
| ---------- | ------ | ------------------------------------------------------------------------------------------------------------- |
| `headband` | 2      | A FB7185 band across the brow (0.92s wide), two tail pixels behind waving by `sin(e * 9) * 1.2`               |
| `visor`    | 7      | A 22D3EE bar at 0.92 over the eyes (0.78s wide), a white glint sliding across by `sin(e * 4.5)`               |
| `headset`  | 15     | An A78BFA arch over the head and two 38BDF8 ear cups                                                          |
| `halo`     | 24     | A gold FBBF24 ellipse stroked 1.3 pt above the head, bobbing by `sin(e * 4.2) * 1.1`, with a white 0.85 gleam |
| `crown`    | 36     | A gold band with three peaks (the middle taller) and a FB7185 gem                                             |

The headgear coordinates, which prose would lose:

```swift
let topY = center.y - spriteSize * 0.52
// headband
CGRect(x: center.x - s * 0.46, y: topY + s * 0.14, width: s * 0.92, height: px * 1.05)
let tailWave = CGFloat(sin(elapsed * 9.0)) * 1.2 * scale
CGRect(x: center.x - s * 0.62, y: topY + s * 0.16 + tailWave * 0.4, width: px, height: px) // 0.9
CGRect(x: center.x - s * 0.74, y: topY + s * 0.24 + tailWave, width: px, height: px)       // 0.65
// visor
let visor = CGRect(x: center.x - s * 0.34, y: center.y - s * 0.18, width: s * 0.78, height: px * 1.35)
let glintX = center.x - s * 0.20 + CGFloat(sin(elapsed * 4.5) * 0.5 + 0.5) * s * 0.44
CGRect(x: glintX, y: visor.minY, width: px, height: px * 0.9)
// headset
CGRect(x: center.x - s * 0.42, y: topY - px * 0.4, width: s * 0.84, height: px * 0.9)   // arch
CGRect(x: center.x - s * 0.56, y: center.y - s * 0.18, width: px * 1.1, height: px * 2.4) // cups,
CGRect(x: center.x + s * 0.44, y: center.y - s * 0.18, width: px * 1.1, height: px * 2.4) // both sides
// halo
let hy = topY - px * 1.9 + CGFloat(sin(elapsed * 4.2)) * 1.1 * scale
CGRect(x: center.x - s * 0.38, y: hy, width: s * 0.76, height: px * 1.1)                 // ellipse
CGRect(x: center.x - px * 0.5, y: hy - px * 0.25, width: px, height: px * 0.7)           // gleam
// crown
let baseY = topY - px * 0.9
CGRect(x: center.x - s * 0.36, y: baseY, width: s * 0.72, height: px * 1.1)
for (idx, dx) in [-s * 0.34, -px * 0.5, s * 0.34 - px].enumerated() {
    let h = idx == 1 ? px * 1.55 : px * 1.15
    CGRect(x: center.x + dx, y: baseY - h + 0.3, width: px, height: h)
}
CGRect(x: center.x - px * 0.42, y: baseY + px * 0.15, width: px * 0.85, height: px * 0.85) // gem
```

The aura pixel positions:

```swift
// pixelWings, flap = sin(e * 8.4) * 2.1 * scale; upper (secondary 0.82, index 1 white 0.72):
(-s * 0.58, -s * 0.22 - flap * 0.4), (-s * 0.76, -s * 0.40 - flap * 0.8),
(-s * 0.92, -s * 0.28 - flap), (-s * 0.74, -s * 0.08 - flap * 0.4)
// lower (brand 0.66):
(-s * 0.58, s * 0.18 + flap * 0.3), (-s * 0.76, s * 0.34 + flap * 0.6), (-s * 0.88, s * 0.22 + flap * 0.8)
// cape strips: (dx, dy, alpha), y = center.y - s * 0.16 + dy, width px * 1.15, height s * 0.54
(-s * 0.56, 1.0 * scale, 0.52), (-s * 0.72, 2.2 * scale + flutter * 0.5, 0.36), (-s * 0.88, 3.0 * scale + flutter, 0.22)
```

**Bit drones**, for the `bitDrones` weapon: two small craft above and below the agent, bobbing in
opposition.

```swift
let px = 1.6 * scale
let bob = CGFloat(sin(elapsed * 6.4)) * 1.3 * scale
for pos in [CGPoint(x: center.x + 2 * scale, y: center.y - 9.2 * scale + bob),
            CGPoint(x: center.x + 2 * scale, y: center.y + 9.2 * scale - bob)] {
    context.fill(Path(CGRect(x: pos.x - px * 1.1, y: pos.y - px * 0.65, width: px * 2.2, height: px * 1.3)), with: .color(Color(hex: 0xA78BFA)))
    context.fill(Path(CGRect(x: pos.x + px * 0.6, y: pos.y - px * 0.4, width: px * 0.9, height: px * 0.8)), with: .color(.white))
}
```

### 5.12 Character popover

A 392 x 500 popover on the island's dark surface with a header, a four-tab segmented bar
(overview, style, gear, medals; tabs switch with `PrismSpringSpec.snappy` under the user's motion
tier) and a scrolling body.

The header's **animated sprite**: a 58 x 58 tile (white 0.04 fill, corner 12, stroked 1.2 pt in
the tier color at 0.55) showing the agent's 24 pt sprite with its aura, headgear and drones.

- The sprite bobs by `sin(t * 4.2) * 1.4` at 0.54 of the tile's height; cells are drawn with a
  0.25 gap, at least 1.1 pt.
- Aura and headgear at scale 1.35, drones at 1.25.
- Frame rate: the energy policy's streaming widget rate with `displayMaxFPS` 30; Reduce Motion or
  motion tier `off` draws one frame at t = 0.

Beside it: the name (14 pt bold), a `Lv.N` capsule in the tier color, the tier title, a 5 pt XP
bar, `XP x / y`, `Bond Lv.N`, and metric pills (PWR in FBBF24, DPS in 38BDF8, stardust in C084FC)
with the damage numbers toggle. The overview tab showed eight stat bars (ATK FB7185, SPD 38BDF8,
CRIT FBBF24, CDMG F97316, PEN A78BFA, SYN 60A5FA, ECO 34D399, LUK F472B6), the skills with lock
states, career tiles and the last eight combat feed lines.

### 5.13 What fed the RPG

The store turned the host's work facts into progression; only the parts that changed the effects
matter here:

| Fact                 | Effect on screen                                          |
| -------------------- | --------------------------------------------------------- |
| `work.active`        | XP, and the mastery that raised ATK, SPD, CRIT, CDMG, PEN |
| `permission.granted` | The 8.5 s commander buff                                  |
| `todo.completed`     | XP, stardust, a loot roll                                 |
| `plan.completed`     | Boss XP and a guaranteed uncommon or better drop          |
| `turn.ended`         | Combo, which multiplied XP                                |

Level curves: agent `120 * L^1.45 + 60 * L` XP per level (to 99), bond `80 * L^1.38 + 40 * L`
(to 20), commander `160 * L^1.48 + 80 * L`. Stats grew with level and with the square roots of
seconds spent editing (ATK), thinking (CDMG), scanning (CRIT) and running commands (PEN); see
`AgentRPGProfile.computeStats` at the commit.

## 6. Fitting the effects to the new game

The new game's battle arrives as `BattleEvent`s (`packages/sarto-wire/src/game.ts`), which
`GameStore` plays 350 ms behind game time and `GameArenaRenderer` draws: a hero block with a
harness weapon (`katana`, `runeStaff`, `drone`, `lance`, `blaster`), a monster block with an HP
bar, shots that lerp to the target in 0.22 s, popups that rise 20 pt/s and fade in 0.85 s, and a
banner. The renderer has a `still` flag. Suggested mappings:

| Event                  | Fields used                             | Effect to reuse                                                                                                                                 |
| ---------------------- | --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `spawn`, `waveStart`   | `monster`, `hp`, `elite`                | Squad spring glide to the new target (4.2); speed lines while it fights (4.11)                                                                  |
| `hit`                  | `damage`, `crit`, `hp`                  | Pulse strike with tail (4.5, 4.9), impact sparks, target flash and recoil (4.7); `crit` as a heavy impact and a `N!` popup (5.8)                |
| `double`               | `damage`                                | Twin repeater pair (5.3)                                                                                                                        |
| `tool`                 | `damage`                                | Lightning arc (5.5) for the `runeStaff`, a drone shot (5.3, 5.11) for the `drone`                                                               |
| `ult`                  | `damage`, `perfect`, `ult`              | Prismatic superbeam (5.4) with both sprites flashing and a hop (5.6, `sartoPrismCombo`); `perfect` adds the prism X slash (5.7)                 |
| `ult` charge           | `ult` / `ultMax`                        | Sarto's bottom-up charge overlay (4.12) or the active node's charge ring (4.13)                                                                 |
| `kill`                 | `elite`                                 | The clear finisher (4.14): shockwave, burst, node pop; elites get pixel fireworks (5.7)                                                         |
| `stageClear`           | `text`                                  | Pixel fireworks and the celebrate hop; the banner as a rising emphasis popup (5.8)                                                              |
| `miss`                 |                                         | A dim `miss` popup (exists) and a spark glancing off the node                                                                                   |
| `bossStart`            | `hp`, `maxHp`                           | Shield breaker shockwave (5.6) as the boss enters                                                                                               |
| `bossPhase`            | `text`                                  | Chain arc (5.5) or a glitch shatter (5.7) with the phase banner                                                                                 |
| `bossEnd`              | `result.won`                            | Won: fireworks and the hop; lost: the glitch shatter on the hero                                                                                |
| `offer`, `pick`        |                                         | The `LV UP!` style popup and hop (5.9)                                                                                                          |
| Hero level             | `hero.level`                            | Rank tier colors (5.2) for the level and frame                                                                                                  |
| Account not active     | `account.state` (`inactive`, `offline`) | The static frame (4.15), with the amber pixel "!" over the hero while the agents wait on the user                                               |
| Main weapon by harness | `main`, `weapons`                       | Old weapon looks: `blaster` as pulse blaster, `drone` as bit drones, `lance` as orbital beam, `runeStaff` as arc staff, `katana` as prism slash |

When porting: keep the server the source of every number (the client only plays events); keep the
particle caps and per-frame caps; draw at the rate `PrismEnergyPolicy` allows and the still frame
for the `still` tier and Reduce Motion; take colors from `PrismTokens` instead of the hex values
above; and keep effects clear of any text they sit beside.

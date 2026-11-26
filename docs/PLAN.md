# Feature Plan

Planned product features kept on the roadmap.

## 1. GitHub README Dynamic Profile Card & Commander Card

An opt-in, privacy-preserving shareable card generated from sanitized work facts and idle-game progression, designed to embed in a GitHub Profile README or share directly as an image on social media.

### Goals

- Turn daily multi-agent coding and idle-game progression into a high-craft visual artifact without leaking source code, prompts, repository names, or file paths.
- Provide two visual styles aligned with Sarto's aesthetic:
  - **Pixel RPG style**: retro pixel sprites, agent squad levels, and rank badges matching the idle game.
  - **Prism Optical style**: dark and light optical themes derived from `PrismTokens` (`Obsidian Dark`, `Warm Charcoal`, `Daylight Crystal`, `Warm Alabaster`).
- Support both one-click image export (PNG/SVG for X and social sharing) and an optional live-updating SVG endpoint for GitHub Profile READMEs.

### Card Content (Sanitized Only)

All metrics come strictly from opaque `work-facts` (`src/agent-host/work-facts.ts`), local aggregated diff/turn totals, and server-side game state (`GameStateInfo` / `GameWeaponInfo` in `SartoProtocol`):

- **Commander header**: commander handle (user-chosen display name or anonymous), current rank tier, and active streak / weekly cadence.
- **Primary agent squad**: top harnesses with pixel marks and levels (for example, `Lv.42 Claude Code`, `Lv.36 Codex`, `Lv.28 Gemini CLI`) sourced from `GameWeaponInfo` (`harness`, `level`, `minutes`, `todayMinutes`).
- **Weekly coding stats**: sanitized weekly totals such as diff lines changed (added/removed counts only), completed plan steps, active coding time, and boss/milestone clears.
- **Zero private metadata**: never includes repository names, branch names, file paths, commit messages, prompts, or machine hostnames.

### Export & Sharing Modes

1. **Local Snapshot Export (Offline-first, no account required)**
   - Render directly inside the macOS app via SwiftUI `ImageRenderer` (PNG at 2x/3x) and deterministic local SVG generation.
   - Accessible from the Expedition / Idle Game surface (`apps/apple/macOS/Game/ExpeditionWindowView.swift`) and Settings.
   - One-click **Copy Image**, **Save PNG**, **Save SVG**, and **Copy Markdown Snippet**.
2. **Dynamic GitHub README Badge / Card (Opt-in, signed-in account)**
   - User explicitly enables public card publishing and chooses what fields to display (granularity toggles for squad levels, weekly diff counts, and rank).
   - Daemon/client publishes only the sanitized summary payload (never raw logs or repo identifiers) to Sarto Cloud via `packages/sarto-wire`, which serves a cached SVG URL suitable for `![Sarto Commander Card](...)` in GitHub READMEs.
   - User can rotate or revoke the public card URL at any time.

### Implementation Milestones

- [ ] Define the sanitized card summary schema in `packages/sarto-wire` (and mirrored Swift models in `SartoProtocol`) with explicit allow-listed fields and unit tests verifying no private paths/prompts can enter.
- [ ] Add weekly sanitized diff-count aggregation in `src/agent-host/work-facts.ts` (line counts only, no file names or repo IDs).
- [ ] Build the native card preview and customization sheet in `apps/apple/macOS/Game/` (style switcher: Pixel vs. Prism palettes; field visibility toggles; light/dark preview; `en` + `zh-Hans` localization).
- [ ] Implement local PNG/SVG export and clipboard copy off the main actor.
- [ ] (Phase 2) Add opt-in public SVG publishing + revoke/regenerate controls for live GitHub README embeds.

---

## 2. Dynamic Island Pixel Worker (Opt-In Companion)

An optional pixel companion mode for Sarto's macOS Dynamic Island (`apps/apple/macOS/DynamicIsland`) that puts the active agent's pixel sprite inside the notch while Sarto's main window is hidden or in the background.

### Goals

- Give the notch Dynamic Island clear, glanceable ambient presence when coding agents run in the background without cluttering the screen.
- Turn permission prompts and agent questions into an unmistakable yet calm visual cue.
- Remain strictly opt-in, lightweight, and governed by `PrismEnergyPolicy` and `IslandMotionStyle`.

### Behavior & States

Controlled by an opt-in toggle in **Settings -> Dynamic Island** (default off, synced via existing settings):

- **Visibility rule**: activates in the collapsed notch/island when the toggle is enabled and Sarto's main window is hidden, miniaturized, or inactive in the background while at least one session is active (or idle-resting if desired).
- **Working state (typing / executing / thinking)**:
  - The primary active agent's pixel sprite sits along the notch/island shoulder, animating a subtle typing/working loop (with a tiny pixel keyboard/spark cue matching `RunningSessionsRail` pixel art).
  - Multi-agent sessions highlight the currently focused or highest-priority running agent; hovering or clicking still opens the normal island stack.
- **Needs attention state (permission approval / question / plan review)**:
  - When a session enters `awaiting_permission` or asks a question (`group == "needs_you"` in `IslandRowItem`), the pixel agent leans/peeks out of the notch, waves / taps the edge with an amber indicator, and draws attention to the approval card without stealing focus or activating the app.
- **Finished / failed / idle states**:
  - Brief celebration hop on turn completion (`done`), calm resting pose when idle, and a distinct alert mark on `failed` or rate-limited (`limited`).
- **Non-notch external displays**:
  - Gracefully adapts to the floating top-edge pill geometry provided by `IslandGeometry` (`hasNotch == false`).

### Performance, Motion & Energy Constraints

- Must honor `IslandMotionStyle` (`lively`, `calm`, `still`), system Reduce Motion, and `PrismEnergyPolicy.framesPerSecond(for:surface:displayMaxFPS:conditions:)`:
  - `lively`: full sprite animation capped by `PrismEnergyPolicy`.
  - `calm`: reduced frame rate and minimal particles/props.
  - `still` or Reduce Motion: single static pose per state (working / waving / resting), zero timer wakeups.
- Automatically pauses animation when the island is concealed over another app's fullscreen Space (`concealed == true` in `PrismIslandPanelController`) or when the display sleeps.
- Uses `PrismTokens` / `PrismIslandTokens` colors and `PrismSpringSpec` transitions; no raw colors and no separate render loop outside the island's gated timeline.

### Implementation Milestones

- [ ] Add `pixelWorkerEnabled` setting to `UsageSettingsStore` / `IslandStackOptions` and expose the opt-in toggle in `SettingsClientSectionsView` (`en` and `zh-Hans` strings in `PrismDesign`).
- [ ] Reuse and adapt pixel agent sprites (from `IslandAssets.swift` / `RunningSessionsRail.swift` pixel marks) into a compact sprite state machine (`working`, `peekingNeedsYou`, `celebrating`, `alert`, `resting`).
- [ ] Integrate the pixel worker view into collapsed `IslandViews.swift` layouts for both notched and non-notched `IslandGeometry`, driven by `IslandProjection` and `NSApp.isActive` / window visibility state.
- [ ] Gate all frame updates through `PrismEnergyPolicy`, `IslandMotionStyle`, Reduce Motion, and fullscreen concealment checks.
- [ ] Verify appearance across all four Prism palettes (dark and light), notched MacBook display, external monitor, and Low Power Mode.

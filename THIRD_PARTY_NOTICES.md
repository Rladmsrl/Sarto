# Third-party notices

Sarto is licensed under the GNU Affero General Public License, version 3 ([LICENSE](./LICENSE)),
except where a file or folder says otherwise. It contains or adapts the following works.

## Kettu

- Source: https://github.com/KettuAI/Kettu
- Copyright (C) 2026 Amigoer
- License: GNU AGPL version 3 ([LICENSE](./LICENSE))

Sarto is a modified version of Kettu, changed since November 2026. It keeps Kettu's daemon and
hosts (`src/daemon`, `src/agent-host`, `src/terminal-host`, `src/remote-host`, `src/device-host`),
the shared contracts (`src/shared`), the main process modules the daemon uses (`src/core`, from
Kettu's `src/main`) and the type viewers (`src/renderer/src/viewers`). Sarto changed these files
throughout: they take Sarto's names, run without Electron, and reach Sarto's account, relay, push
and sync services in place of Kettu's. Sarto added its own: the SwiftUI apps in `apps/apple`, the
sync client in `src/daemon/sync` and the protocol package in `packages/sarto-wire`.

This repository's history starts at Sarto's first public commit, so it does not show Kettu's own
history, which is in Kettu's repository.

Sarto leaves out Kettu's Electron renderer and web client, which use affectUI components that are
not licensed for redistribution, and Kettu's additional permission for affectUI
(`LICENSE-EXCEPTION`), which therefore no longer applies.

## Cindy

- Source: https://github.com/makecindy/cindy
- Copyright 2026 XD Inc.
- License: Apache License 2.0 ([LICENSES/Apache-2.0.txt](./LICENSES/Apache-2.0.txt))

The menu bar panel adapts code from Cindy's `apps/desktop/native/menubar/macos-menubar-helper.swift`.
Each adapted file says so at its top:

- `apps/apple/Packages/UsageIslandKit/Sources/MenuBarKit/` (`Components.swift`, `CountUp.swift`,
  `Rings.swift`, `SettingsComponents.swift`, `StatusPanelController.swift`, `Theme.swift`,
  `Tube.swift`)
- `apps/apple/macOS/MenuBar/MenuBarPanelViews.swift`

The conversation timeline rail (`apps/apple/Shared/SessionThreadView.swift`,
`apps/apple/Shared/ThreadTimelineModel.swift`) follows the design of Cindy's `MessageNavRail`.

Cindy's NOTICE file reads:

```text
Cindy
Copyright 2026 XD Inc.

This product includes software developed by XD Inc.

Third-party components distributed with this product retain their own
copyright and license terms. Their attribution notices and SPDX SBOMs are
collected under docs/legal/notices/, not in this file.
```

## Code Island

- Source: https://github.com/wxtsky/CodeIsland
- Copyright (c) 2026 wxtsky
- License: MIT

The Dynamic Island's silhouette (`IslandShape` in `apps/apple/macOS/DynamicIsland/IslandViews.swift`)
adapts Code Island's `NotchPanelShape`. Its license reads:

```text
MIT License

Copyright (c) 2026 wxtsky

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Codex and codex-acp

- Codex: https://github.com/openai/codex, Copyright OpenAI, Apache License 2.0
- codex-acp: https://github.com/agentclientprotocol/codex-acp, Copyright 2025 JetBrains s.r.o.,
  Apache License 2.0
- License text: [LICENSES/Apache-2.0.txt](./LICENSES/Apache-2.0.txt)

`src/agent-host/codex/protocol.ts` adapts the TypeScript types `codex app-server generate-ts`
writes, and `src/agent-host/codex-binary.ts` follows the binary lookup of `@openai/codex`'s
`bin/codex.js`. `src/agent-host/codex/commands.ts` and `src/agent-host/codex/mcp-status.ts` adapt
the answer formats of codex-acp. Each file says so at its top.

## Barlow Condensed

- Copyright 2017 The Barlow Project Authors
- License: SIL Open Font License 1.1
  (`apps/apple/Packages/UsageIslandKit/Sources/MenuBarKit/Fonts/BarlowCondensed-OFL.txt`)

## Sarto's own packages under other licenses

- `packages/sarto-wire`: Apache License 2.0 (see its `LICENSE` and `NOTICE`).

## Obsidian Prism

- Source: https://github.com/RMvdesi/obsidian-prism
- Copyright (C) 2026 RMvdesi
- License: GNU GPL version 3 only ([LICENSES/GPL-3.0.txt](./LICENSES/GPL-3.0.txt)), which
  section 13 of the GNU AGPL version 3 lets Sarto combine with its own code

Sarto's visual language follows Obsidian Prism's. PrismDesign
(`apps/apple/Packages/PrismDesign/Sources/PrismDesign/`) adapts its design values: the four
palettes' colors (`PrismPalette.swift`, from `v2-tokens.css`), the motion tiers and spring
parameters (`PrismMotion.swift`, from `motion-engine.js`) and the aura states (`PrismSurface.swift`,
from `conv-aura.js`). Sarto rewrote them in Swift and changed them; each of these files says so at
its top. The Metal shaders in `PrismMetalSource.swift` are Sarto's own. Obsidian Prism's name is
used only to credit it: Obsidian Prism does not endorse Sarto.

Sarto is an independent project. It is not affiliated with or endorsed by KettuAI, XD Inc.,
RMvdesi, Anthropic, OpenAI or Google.

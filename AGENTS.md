# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a symbolic link to this file, so every agent reads the same rules from one place.

## Project

Sarto is a native SwiftUI app for macOS that runs terminal coding agents. It is in early development; [README.md](./README.md) has the features.

Sarto is only an interface: it implements no agent. Its Node.js daemon drives Claude Code through the Claude Agent SDK, Codex through `codex app-server`, DeepSeek Harness through its SDK interface, Pi through its RPC mode, OpenCode through its own server and Cline through Cline's SDK, the last two with the Agent Client Protocol (ACP) as their fallback, and every other agent over ACP. The Mac app bundles the daemon, starts it and talks to it over local sockets.

Sarto started as a fork of Kettu (AGPL-3.0) and of Cindy's menu bar and remote control code (Apache-2.0); [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) says what came from where. Sarto Cloud (accounts, the relay, push, sync and release downloads, at `https://sarto.1o.ink`) is a separate, closed-source service, which the daemon and the apps reach only through the public protocols in `packages/sarto-wire`.

## Engineering rules

### Performance

- Never block the daemon's or a host's event loop: no synchronous file system, child process or network calls there. Heavy work goes to a worker, as the thread database's and the usage's do (`src/agent-host/threads/worker.ts`, `src/agent-host/usage/worker.ts`).
- Stream agent output to clients as it comes, and page long histories (`sessions.page`) instead of sending them whole.
- Keep the apps' main actor free: file, process and network work runs off it (`Task.detached` or an actor), as `DaemonManager` resolves Node.js.
- Values that change many times a second, such as the output speed, live in small leaf views, so a tick re-renders only what shows it. Cache what scrolling would compute again, as `ThreadTimelineModel` caches diffs, and parse streamed terminal output incrementally, as `WorkspaceController` does.
- Metal and other animated views draw at the rate `PrismEnergyPolicy` allows, which lowers it for still views, Low Power Mode and thermal pressure. Never add a render loop that bypasses it.
- Measure before and after: Instruments for the apps, the Node.js inspector (`sarto run --debug`) for the daemon. An optimization without a measurement is a guess.

### Interface

- Design every state: loading, empty, error, and hover, focus, pressed and disabled.
- Check every screen in a dark and a light palette (Obsidian and Warm are dark, Crystal and Alabaster light), at small and large window sizes.
- Take colors from `PrismTokens` (`@Environment(\.prismTokens)`) and springs from `PrismSpringSpec`; new code adds no raw colors.
- Motion is purposeful and restrained, and always honors the user's motion tier and Reduce Motion; `PrismSpringSpec.animation(tier:reduceMotion:)` returns none for either.
- Every word the apps show is localized in English and Simplified Chinese, through `l10n.tr(_:)` (`@Environment(\.prismL10n)`) with the same keys in PrismDesign's `en.lproj` and `zh-Hans.lproj` `Localizable.strings`. The daemon's own text lives in `src/shared/locales/<locale>/`.
- Respect macOS conventions: `Cmd` shortcuts, Settings in its own window on `Cmd+,`, and the menu bar item that keeps Sarto running when its windows close.
- The type viewers in `src/renderer/src/viewers` take their colors from `src/renderer/src/styles/tokens.css`; `pnpm lint` rejects a color literal outside the tokens.

### Reusing code from other projects

- Check the license first. Code under MIT, BSD, ISC or Apache-2.0 may be adapted: keep its copyright and license notice, and add a one-line comment with the source URL.
- Sarto is licensed under AGPL-3.0-only. GPL-3.0 and AGPL-3.0 code is compatible with it, but ask the maintainer before reusing any. Ask too before reusing LGPL or MPL code, or code without a license.
- `packages/sarto-wire` is Apache-2.0 and imports nothing from the rest of the repository; never bring Kettu's code or any copyleft code into it.
- When a maintained package already does the job, prefer depending on it over copying it, subject to the dependency rules below.

## Tech stack

The app: Swift 6 with complete strict concurrency, SwiftUI with AppKit where SwiftUI falls short, the Observation framework and Metal, on macOS 15. XcodeGen generates `apps/apple/Sarto.xcodeproj` from `apps/apple/project.yml`. Package tests use Swift Testing. There are no third-party Swift packages.

| Target     | What it is                   |
| ---------- | ---------------------------- |
| `SartoMac` | The Mac app, `dev.sarto.mac` |

The Mac app registers the `sarto://` scheme, so the sign-in page's link back to Sarto brings it to the front. The Swift packages in `apps/apple/Packages`:

| Package          | What it holds                                                                                                                      |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `SartoProtocol`  | The host protocol in Swift: Noise, channel framing, the relay, pairing codes, push envelopes, the RPC clients and the thread model |
| `PrismDesign`    | Tokens, palettes, motion, the Metal canvases and the apps' localized text                                                          |
| `UsageIslandKit` | `UsageCore`, which picks the agent the Dynamic Island follows, and `MenuBarKit`, the menu bar's status item and usage panel        |
| `SartoUpdate`    | The updater's parts: the signed source list and update file, signatures, deltas and the bundle swap                                |

The daemon: Node.js 22.13 or later (a package carries Node.js 24), TypeScript 6 in strict mode, pnpm 10, Vite 8, which builds the daemon (`vite.daemon.config.mts`) and the viewers (`vite.viewers.config.mts`), and Vitest. TypeScript stays on 6.0 until typescript-eslint supports 7.

Beyond those: `@agentclientprotocol/sdk` for ACP (protocol v1 through the SDK's `unstable` entrypoint), `@modelcontextprotocol/sdk` for the MCP tools the agent host gives agents, `node-pty` in the terminal host, `ws` for the relay's and the channel's sockets, `@noble/curves`, `@noble/ciphers` and `@noble/hashes` for Noise, `semver` for matching harness versions against the ranges of Sarto's signed harness compatibility manifest, `jsonc-parser` and `@decimalturn/toml-patch` for changing one key of a harness's JSONC or TOML configuration file while keeping the user's comments, `agent-device` and `@expo/serve-sim` in the device host, and i18next for the daemon's text. The viewers are React 19 with Tailwind CSS v4, shadcn/ui on Base UI, Streamdown and Shiki.

Claude Code's `@anthropic-ai/claude-agent-sdk` is never a dependency: the daemon installs it into its data folder on first use and loads it at runtime with `loadClaudeSdk` (`src/agent-host/claude/sdk.ts`), because the SDK's license grants no right to redistribute it. Codex's `@openai/codex` is not one either: Sarto runs the user's own `codex`. The repository holds only its own types for the parts of the SDK it uses, and lint rejects an import of the package.

Cline's `@cline/sdk` is no dependency either: the `cline` package Sarto installs into its data folder brings it, and a process of Sarto's own (`src/agent-host/cline/cline-host.ts`) loads it from there, so the SDK always has its CLI's version. A version it was not checked on, or a start over it that fails, runs `cline --acp` instead.

The agent host's computer use runs Cua Driver's `cua-driver` (MIT), which `pnpm fetch:cua-driver` fetches into `resources/cua-driver/`. The Mac app does not ship it yet.

## Architecture

The top of the tree:

```text
apps/apple/
├── project.yml        XcodeGen's spec for Sarto.xcodeproj
├── macOS/             The Mac app: window, sidebar, composer, Dynamic Island, menu bar, Settings,
│                      updater and the daemon manager, which starts the bundled daemon
├── Shared/            App state, the session thread, and the workbench panes
├── Packages/          SartoProtocol, PrismDesign, UsageIslandKit, SartoUpdate
└── scripts/           package-mac.mjs: packages Sarto.app with the daemon's runtime
src/
├── daemon/            The `sarto` CLI and the daemon: control socket, hosts, pairing, the account,
│                      sync, updates
├── agent-host/        Utility process: agents, sessions, projects, git, usage
├── terminal-host/     Utility process: terminals through node-pty
├── remote-host/       Utility process: paired devices' encrypted connections, the relay and the
│                      connections to other hosts
├── device-host/       Utility process: iOS simulators, Android emulators and devices
├── core/              Node.js modules the daemon and hosts share: settings, keys, the account,
│                      signatures, logs
├── shared/            Shared across processes and clients: the host contracts, the thread model,
│                      the encrypted channel and the host link
└── renderer/src/      The artifact type viewers (viewers/) and the few renderer files they use
packages/sarto-wire/   The relay, push, price and sync protocols, Apache-2.0 (PROTOCOL.md)
native/                macOS helpers for iOS devices: sarto-ios-device, sarto-ios-usb-capture
tools/
├── fake-agent/        Scripted ACP agent for development and tests
├── daemon/            Packages the standalone daemon
├── sarto/             Releases, the install script, signing and the harness manifest
└── harness-checks/    Checks of new harness versions
```

### Security rules

Sarto drives agents that run shell commands, and its daemon takes connections from other devices, so these are not negotiable:

- Whoever can open the daemon's sockets controls the Mac's agents. Keep the control socket `0600` and the keys `0600` in a `0700` folder (`src/daemon/key.ts`).
- Treat every request from a device, a client or the control socket as untrusted, and validate it in the host that serves it (the agent, terminal and device hosts' `validate.ts`, and `src/remote-host/server.ts`). What a device may ask is `src/shared/remote/allow-list.ts`, which the remote host and the agent host both check.
- Devices reach a host only end-to-end encrypted, through Noise_IK; devices are paired through the account. The relay and the push gateway see only ciphertext; never add a plaintext path.
- Devices get no terminal until the owner turns it on (`sarto terminal on`, or Settings on that computer).
- The debug inspectors listen on `127.0.0.1` only, and only for a debug run (`sarto run --debug`, or the run after `sarto restart --debug`).
- Secrets stay out of logs and settings files: what the user enters for MCP servers and the API keys in agents' environments are encrypted with the macOS Keychain, or kept in a `0600` file where it refuses (`src/core/market-keys.ts`), and sync carries them only end-to-end encrypted.
- The daemon and the apps reach Sarto Cloud only through the protocols in `packages/sarto-wire`, and never through the server's own code.
- Updates trust only files signed with the keys in `tools/sarto/update-keys.json`, which `SartoUpdate` compiles in too, and the app checks the new bundle's code signature against its own. The daemon trusts only harness manifests signed with Sarto's harnesses key. Never weaken these checks.

## Commands

| Command                                                                 | What it does                                                        |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `pnpm build`                                                            | Type-check, then build the daemon and the viewers into `out/`       |
| `pnpm build:daemon`                                                     | Build the daemon into `out/daemon/`                                 |
| `pnpm build:viewers`                                                    | Build the type viewers into `out/viewers/`                          |
| `pnpm format:check`                                                     | Check formatting (`pnpm format` fixes it)                           |
| `pnpm lint`                                                             | ESLint, and the color and contrast checks of the viewers' tokens    |
| `pnpm typecheck`                                                        | Type-check the daemon, hosts, viewers, tools and the shared package |
| `pnpm test`                                                             | Run the core tests (`pnpm test:watch` keeps watching)               |
| `pnpm package:mac`                                                      | Package `Sarto.app` with its daemon into `dist/`                    |
| `pnpm fetch:device-helpers`                                             | Put the device host's helpers in `out/helpers/`                     |
| `xcodegen generate --spec apps/apple/project.yml`                       | Regenerate `Sarto.xcodeproj`                                        |
| `xcodebuild -project apps/apple/Sarto.xcodeproj -scheme SartoMac build` | Build the Mac app                                                   |
| `swift test`, in a package's folder under `apps/apple/Packages`         | Run that Swift package's tests                                      |

A development build of SartoMac runs the checkout's `out/daemon/main.cjs` on the user's Node.js. It shares the installed app's data folder, `~/Library/Application Support/Sarto Daemon`, unless `SARTO_DAEMON_DATA` names another, and one copy of the app runs per data folder; [CONTRIBUTING.md](./CONTRIBUTING.md) has the rest. A daemon run from the command line takes a folder of its own the same way: `SARTO_DAEMON_DATA=/tmp/sarto-daemon node out/daemon/main.cjs run`.

## Versioning and packaging

The Mac app, the daemon and Sarto Cloud carry independent semantic versions; see [docs/versioning-and-releases.md](./docs/versioning-and-releases.md) for the full layout and Sarto Cloud routing rules.

- **Version sources**:
  - Mac app base version: `MARKETING_VERSION` in `apps/apple/project.yml`
  - Daemon base version: `version` in root `package.json`
  - Server (Sarto Cloud): versioned independently in its own repository; compatibility uses `packages/sarto-wire` protocol versions and features, never software versions.
- **Build numbers & channels**:
  - Every build stamps a monotonic 12-digit UTC build number (`YYMMDDHHmmss`, e.g. `261125143512`), a channel (`stable`, `beta` or `dev`) and the short git commit (`<sha>` or `<sha>-dirty`) into build outputs without editing checked-in source files.
  - Format: `stable` is strictly `X.Y.Z`; `beta` is `X.Y.Z-beta.<build>`; `dev` is `X.Y.Z-dev.<build>`. Never encode channel or component identity into trailing digits of `X.Y.Z` (it breaks SemVer ordering, `SartoVersion` 9-digit core limits and `node-semver`).
  - **Version monotonicity rule (SemVer)**:
    - Always cut `beta` releases against the **next upcoming** `X.Y.Z` (higher than the latest shipped `stable` tag). Never cut `0.3.1-beta.<build>` after `0.3.1` has already shipped, because SemVer orders `0.3.1-beta.* < 0.3.1` and users on `0.3.1` would never see the beta update.
    - Repeat `beta` releases on the same upcoming `X.Y.Z` do not need to bump `X.Y.Z` (the 12-digit UTC build suffix increases automatically on every run).
    - Every new `stable` release must bump `X.Y.Z` above the previous stable release (`SartoUpdater` compares SemVer, not `CFBundleVersion`). Both `tools/sarto/release.mjs` and `.github/workflows/release-mac.yml` enforce these rules automatically via `checkReleaseVersionOrder` (ignoring only the triggering tag itself on a CI tag push; pass `--allow-older` to `release.mjs` only for explicit local rollback tests), and `apps/apple/scripts/package-mac.mjs` warns when packaging `--channel beta` on a base version `<=` the latest published stable tag.
  - Apple notarization requires pure `X.Y.Z` in `CFBundleShortVersionString`; keep `CFBundleShortVersionString` at `X.Y.Z`, write the 12-digit build number to `CFBundleVersion`, and write the full semantic version, channel and commit to `SartoVersion`, `SartoBuildChannel` and `SartoGitCommit` in `Info.plist`.
  - `SartoUpdater` prefers `SartoVersion` over `CFBundleShortVersionString`. `sarto --version` must print only the semantic version string (consumed by `install.sh` and packaging verification); build, channel, commit and origin (`bundled`, `standalone`, `checkout`) appear in `sarto status`, `DaemonStatus`, startup logs and About/problem reports.
- **Packaging & release commands**:
  - Local daemon build: `pnpm build:daemon` (automatically stamps `dev` channel, 12-digit UTC build and git commit into `out/daemon/`).
  - Local Xcode build: builds `SartoMac` and its `Stamp Dev Build Metadata` post-build script stamps `CFBundleVersion`, `SartoVersion`, `SartoBuildChannel=dev` and `SartoGitCommit` into the built `Info.plist` without dirtying git.
  - Package `Sarto.app`: `node apps/apple/scripts/package-mac.mjs [--version <appVer>] [--daemon-version <daemonVer>] [--channel stable|beta|dev] [--daemon-channel stable|beta|dev] [--build <12-digits>] [--debug] [--clean]` (defaults to `dev` when ad-hoc signed, `stable` when `SARTO_SIGN_IDENTITY` is set; passes `SARTO_PACKAGING=1`; caches DerivedData and the SHA-256-verified Node.js runtime under `.cache/sarto-package/` unless `--clean` is passed).
  - Local self-testing with stable macOS permissions: when installing a local build into `/Applications/Sarto.app` for day-to-day testing, prefer signing with `SARTO_SIGN_IDENTITY="Developer ID Application: ..."` and `--channel dev` (or `--channel beta` to test beta updates) **without notarizing**. That keeps the Designated Requirement stable across rebuilds so Keychain, notifications, Accessibility and Screen Recording grants do not reset, exercises Hardened Runtime, and enables `SartoUpdateMode=install` while avoiding the notarization wait; reserve notarization (`xcrun notarytool`) for `tools/sarto/release.mjs` and `.github/workflows/release-mac.yml`.
  - Build signed release artifacts: `node tools/sarto/release.mjs --target all|app|daemon --channel stable|beta [--app-version <ver>] [--daemon-version <ver>] [--build <12-digits>] --notes notes.md` (`--notes` is optional for `--target daemon`).
  - Publish to Sarto Cloud releases folder: `node tools/sarto/publish-release.mjs <release-dir> <[user@host:]releases-dir>`.
- **Signed channel manifests**:
  - Each channel has its own manifest signed with `<filename>\n<bytes>` under the Ed25519 release key, preventing cross-channel replay: `latest-mac.json` (app stable), `beta-mac.json` (app beta), `latest-daemon.json` (daemon stable), `beta-daemon.json` (daemon beta).
  - Beta channels check both their beta manifest and the corresponding stable manifest and pick the newer SemVer, so beta users automatically graduate onto newer stable releases.

## Definition of done

- `pnpm format:check`, `pnpm lint`, `pnpm typecheck` and `pnpm test` pass. Also run `pnpm build` when you touch config or anything the daemon's build reads.
- For Swift changes, `swift test` passes in each package you touched and the SartoMac scheme builds. After changing `project.yml`, or adding, moving or removing a Swift file, regenerate the project with XcodeGen and commit it.
- Tests cover only the core: the security boundaries (request validation, the device allow-list, command safety, the encrypted channel, pairing, the relay and push, update and manifest signatures, where secrets and sign-ins may go, and what the logs and reports mask), the stored data (the thread database, the settings and the host files), the agent protocols (the Claude Code, Codex and ACP mapping and the thread model) and the wire protocols. The wire protocols' test vectors in `src/shared/remote/*-vectors.json` are checked by the daemon's tests and, byte for byte, by `apps/apple/Packages/SartoProtocol/Tests`; `src/shared/remote/sarto-wire-parity.test.ts` holds `packages/sarto-wire` to the remote host's own implementation. Add or change tests only there, where a bug fix starts with a test that fails. UI, styling, copy, wiring, tooling and feature behavior a user would notice in use get none.
- Releases are built on a Mac with Apple silicon by `tools/sarto/release.mjs`.
- For UI changes, run the app and look at the result in a dark and a light palette before reporting the work as done.

## Conventions

- **Formatting**: Prettier (single quotes, no semicolons, 100 columns) and ESLint own the TypeScript and JavaScript style; do not format against them. Neither reads `apps/apple`. Swift follows the existing files, with four-space indentation.
- **Imports**: use the `@shared/*` alias, and `@renderer/*` in the viewers, instead of deep relative paths.
- **Shared code**: `src/shared` is a workspace package that runtimes other than Node.js run too. It uses only the globals `src/shared/runtime.d.ts` declares, and `pnpm typecheck` checks it against them; its Node.js-only and page-only files are listed in its `tsconfig.json`.
- **Ported code**: the hosts and the daemon run purely under Node.js without Electron. Code ported from Kettu's `src/main` goes into `src/core`, and features from Kettu's interface into the SwiftUI apps.
- **Comments**: English and ASCII only, and only when they say what the code cannot, such as the reason for a workaround or an edge case. No commented-out code.
- **Dependencies**: ask the maintainer before adding any, npm package or Swift package. Libraries Vite bundles go in `devDependencies`; only modules a process loads at runtime instead of from the bundle go in `dependencies`: `node-pty`, `decompress`, which the agent host loads to unpack what it installs, and `agent-device`, which the device host runs as a program, as it runs `@expo/serve-sim` from `optionalDependencies`.
- **Docs**: `README.md` and `README.zh-CN.md` are kept in sync; change both together. The README is for users; setup and commands live in `CONTRIBUTING.md`.
- **Git**: Conventional Commits 1.0.0 in English, with an imperative subject of at most 50 characters and a body that explains why. No tool-generated trailers or attribution lines. Branches are `<type>/<issue>-<slug>` in kebab-case, such as `fix/123-model-menu-close`. A pull request's title follows the same subject rules, because the squash merge makes it the commit on `main`; its description is a sentence or two, `Closes #N` and how it was checked, with no headings.
- **Language**: everything written into the repository is English (code, comments, commits, pull requests), except Chinese product copy and `README.zh-CN.md`.

## Gotchas

- Enter-to-send must ignore Return while the text view holds marked text (`hasMarkedText()`, as `isIMEComposing` in `MacWorkbenchView.swift` checks), or Chinese, Japanese and Korean input sends half-typed text.
- `Sarto.xcodeproj` is generated, yet committed: XcodeGen lists the Swift files of each source folder when it runs, so a new, moved or removed file is missing from the build until the project is regenerated. Change `project.yml`, never `project.pbxproj` by hand; the next generation drops hand edits.
- Swift 6's complete strict concurrency is on for the app targets, so state that crosses actors must be `Sendable`, and `SartoState` and the views stay on the main actor. `UsageIslandKit` still builds in the Swift 5 language mode.
- A running daemon keeps the build it started with: after `pnpm build:daemon`, the Mac app talks to the old daemon until it stops, as when Sarto quits from its menu bar item.
- The daemon turns direct connections off at every start (`src/daemon/daemon.ts`), so devices reach it through the relay only, and `sarto direct` changes settings that have no effect yet.
- The daemon starts its hosts with `SARTO_DISABLE_ARTIFACTS=1` and `SARTO_DISABLE_REPORTS=1` unless the environment says otherwise, and the Mac app sets both. `SARTO_DISABLE_REPORTS` hides only the agents' `report_problem` tool: the problem reports users send themselves (Help → Report a Problem…, `sarto report`) stay on. Artifacts and the agents' report tool are under review; do not turn them on or build on them.
- The daemon ships for macOS, but `tools/daemon/package.mjs` also packages it for Linux, and the hosts keep upstream's Windows handling. Code that spawns processes, resolves executables or compares paths handles each: a minimal `PATH` when launchd or the app starts the daemon, `PATHEXT` and `.cmd` shims on Windows, and paths compared only after `path.resolve` and `fs.realpath.native`, case-insensitively on Windows.
- `runtimeFingerprint` (`tools/sarto/runtime-fingerprint.mjs`) must always be computed on a placeholder build (`SARTO_BUILD_PLACEHOLDER=1`) before `stampBuildInfo` writes the version/build/channel/commit and before `codesign`, so app-only updates keep the same runtime fingerprint and avoid restarting the daemon.

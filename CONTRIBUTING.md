# Contributing to Sarto

Thanks for helping shape Sarto.

## How to contribute

Sarto takes issues from outside, not code: fixes and features are written by the project, and pull requests are opened by collaborators only. The code is under the [AGPL-3.0](./LICENSE), except [`packages/sarto-wire`](./packages/sarto-wire), which is under the Apache-2.0, and a contribution comes under the same terms as the code it changes.

- **Bugs and ideas**: open an issue through the [issue forms](../../issues/new/choose), in any language. A screenshot helps.
- **Security problems**: follow [SECURITY.md](./SECURITY.md); never post them in a public issue.

## Run from source

You need a Mac with Apple silicon on macOS 15 or later, Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node.js 22.13 or later and pnpm 10:

```bash
pnpm install
pnpm build:daemon
open apps/apple/Sarto.xcodeproj
```

Then run the **SartoMac** scheme. A development build runs the daemon from the checkout's `out/daemon/main.cjs`, which it finds by walking up from its sources (`SARTO_DAEMON_BUNDLE` names another), on the first Node.js 22 or later it finds in Homebrew's, Volta's, nvm's, fnm's or mise's folders (`SARTO_NODE_BINARY` names one). Rebuild the daemon after changing its TypeScript: a daemon that is already running keeps the old build until it stops, as when Sarto quits from its menu bar item.

A development build uses the installed app's data folder, `~/Library/Application Support/Sarto Daemon`, unless `SARTO_DAEMON_DATA` in the scheme's environment names another, and one copy of the app runs per data folder. To run a development build beside an installed Sarto, give it a folder of its own, such as `SARTO_DAEMON_DATA=/tmp/sarto-dev`. The two still share the preferences of the `dev.sarto.mac` bundle identifier.

`apps/apple/project.yml` is the source of the Xcode project. `Sarto.xcodeproj` is generated from it with XcodeGen and committed: after changing `project.yml`, or adding, moving or removing a Swift file, run `xcodegen generate --spec apps/apple/project.yml` and commit the regenerated project. `xcodebuild -project apps/apple/Sarto.xcodeproj -scheme SartoMac build` builds the Mac app from the command line.

Each Swift package in `apps/apple/Packages` has its own tests, which `swift test` runs in the package's folder. SartoProtocol's check the Swift client byte for byte against the protocol test vectors in `src/shared/remote` (`noise-vectors.json`, `relay-vectors.json`, `push-vectors.json`), which the daemon's tests check too.

### The daemon on its own

`pnpm build` type-checks, then builds the daemon into `out/daemon/` and the type viewers it serves into `out/viewers/`. Give the daemon a data folder of its own and run it in the foreground, such as `SARTO_DAEMON_DATA=/tmp/sarto-daemon node out/daemon/main.cjs run`. With the same folder, `status` asks the running daemon, `pair` shows a code that adds a device, `devices` lists the paired ones, `terminal` says whether devices may use the terminal, which `terminal on` and `terminal off` change, and `logs` shows the logs; `--help` lists the rest. `service install` sets up a real system service, so never run it on a contributor's computer.

`run --debug` opens the daemon's and its hosts' Node.js inspectors on `127.0.0.1` for that run. `SARTO_CLOUD_URL` points the daemon at another Sarto Cloud, such as one running locally, and `SARTO_RELAY_URL` and `SARTO_PUSH_URL` at another relay or push gateway. Direct connections stay off for now, since `src/daemon/daemon.ts` turns them off at every start, so `direct` shows and changes settings that take effect only once they come back.

`SARTO_FAKE_AGENT="$PWD/tools/fake-agent/main.ts"` adds a **Fake agent**, which needs no account or network and plays scripted scenarios such as a long answer, a burst of tool calls or three approvals at once. Type `/` in its composer to see them; they are written in [`tools/fake-agent/scenarios.ts`](./tools/fake-agent/scenarios.ts). Set it in the scheme's environment to give the app's daemon the Fake agent.

`pnpm fetch:device-helpers` puts the device host's helpers in `out/helpers`: scrcpy's server for Android, checked by its SHA-256, and on macOS the iOS helpers built from `native/`, of which `sarto-ios-device` needs Rust.

### Packaging and releases

The Apple app, the daemon and Sarto Cloud carry independent semantic versions:

- **Mac app**: `MARKETING_VERSION` in [`apps/apple/project.yml`](./apps/apple/project.yml)
- **Daemon**: `version` in [`package.json`](./package.json)
- **Server (Sarto Cloud)**: versioned independently in its own repository; compatibility is negotiated via [`packages/sarto-wire`](./packages/sarto-wire)

Every build (Xcode, `pnpm build:daemon`, `package-mac.mjs` and `release.mjs`) automatically stamps a monotonic 12-digit UTC build number (`YYMMDDHHmmss`), build channel (`stable`, `beta` or `dev`) and short git commit into build outputs without modifying checked-in source files. See [docs/versioning-and-releases.md](./docs/versioning-and-releases.md) for the full versioning, channel and release layout rules.

`pnpm package:mac` packages `Sarto.app` into `dist/` as a release does: the app, with the daemon, the Node.js release it is pinned to, node-pty, the device helpers and the viewers in `Contents/Resources/runtime`, so it runs on a Mac without Node.js and outside this checkout. Pass `--version <appVer>`, `--daemon-version <daemonVer>`, `--channel stable|beta|dev`, `--build <12-digits>`, `--debug` (fast local Debug build) or `--clean` (fresh DerivedData) as needed. Local runs cache Xcode DerivedData and the SHA-256-verified Node.js runtime under `.cache/sarto-package/`. It is signed ad hoc (and defaults to the `dev` channel) unless `SARTO_SIGN_IDENTITY` names an identity, and `SARTO_BUNDLE_ID` builds it under another bundle identifier, to test it beside the installed app.

After `pnpm build`, `node tools/daemon/package.mjs --out dist/daemon` packages the standalone daemon for this computer: the pinned Node.js, the daemon, the viewers, node-pty and `bin/sarto`. [`tools/sarto/install.sh`](./tools/sarto/install.sh) is the install script a release carries, which `sarto update` (with optional `--channel stable|beta`) runs again for a newer release. `SARTO_RELEASES_URL` points the install script, `sarto update` and the app's updater at one other place laid out as Sarto's releases are.

`node tools/sarto/release.mjs` builds signed releases on a Mac with Apple silicon (`--target all|app|daemon`, `--channel stable|beta`, `--app-version <ver>`, `--daemon-version <ver>`, `--notes notes.md`): it packages the app with `--clean`, signs, notarizes and staples it, writes deltas from earlier releases, packages the standalone daemon, and writes and signs channel manifests (`latest-mac.json`, `beta-mac.json`, `latest-daemon.json`, `beta-daemon.json`). `node tools/sarto/publish-release.mjs` publishes any built release folder to Sarto Cloud's releases folder and atomically updates its channel manifests, `harnesses.json` (when present) and pointers.

`tools/sarto/harnesses.mjs` builds and signs the harness compatibility manifest from harness check results, as [tools/harness-checks/README.md](./tools/harness-checks/README.md) describes.

### Further reading

- [docs/versioning-and-releases.md](./docs/versioning-and-releases.md): decoupled versioning, 12-digit UTC build numbers, local caching, GitHub Actions releases and Sarto Cloud routing.
- [packages/sarto-wire/PROTOCOL.md](./packages/sarto-wire/PROTOCOL.md): the relay, push, price and sync protocols Sarto Cloud speaks.

## Project work

For the project's collaborators and their coding agents. Every change goes through an issue and a pull request, named and described as the Git conventions in [AGENTS.md](./AGENTS.md#conventions) say. Before a pull request leaves draft, make sure these pass:

```bash
pnpm format:check
pnpm lint
pnpm typecheck
pnpm test
```

For a Swift change, also run `swift test` in each package it touches and build the SartoMac scheme.

## The apps' interface

The apps are SwiftUI, with AppKit where SwiftUI falls short, such as the composer's text view, the Dynamic Island's panel and the menu bar's status item, and Metal for the Prism backdrops. They use no third-party Swift package.

- **Tokens**: colors come from PrismDesign's `PrismTokens`, read through `@Environment(\.prismTokens)`, and springs from `PrismSpringSpec` in `PrismMotion.swift`. New code adds no raw colors, so the four palettes stay consistent.
- **Motion**: every animation goes through the user's motion tier and Reduce Motion: `PrismSpringSpec.animation(tier:reduceMotion:)` returns none for either. Metal and other animated views draw at the rate `PrismEnergyPolicy` allows, which lowers it for still views, Low Power Mode and thermal pressure.
- **Text**: every word the apps show goes through `l10n.tr(_:)` (`@Environment(\.prismL10n)`), in English and Simplified Chinese, with the same keys in PrismDesign's `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hans.lproj/Localizable.strings`. The Dynamic Island keeps its own copy in `IslandLocalization.swift`.
- **State**: `SartoState` is the apps' `@MainActor`, `@Observable` store. Views read it through `@Bindable`, and values that change many times a second live in small leaf views, so a tick re-renders only what shows it.
- **Viewers**: the artifact type viewers in `src/renderer/src/viewers` are React 19 with Tailwind CSS v4 and shadcn/ui components on Base UI. Their colors come from `src/renderer/src/styles/tokens.css`, and `pnpm lint` rejects a color literal outside it.

## Dependencies

Ask the maintainer before adding any, in the apps or in the daemon. Libraries Vite bundles go in `devDependencies`. Only modules a process loads at runtime instead of from the bundle go in `dependencies`: `node-pty`, a native module the terminal host loads, and `agent-device` and `@expo/serve-sim`, which the device host runs as programs and `tools/daemon/package.mjs` ships beside the daemon.

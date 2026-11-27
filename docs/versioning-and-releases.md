# Versioning, Packaging and Releases

This document defines how Sarto versions, builds, signs and distributes its three independent components: the Apple client (`SartoMac`), the daemon (`sarto` and its utility hosts) and the server (`Sarto Cloud`).

## 1. Decoupled Version Sources

| Component                     | Base Version Source                             | Compatibility Mechanism                                                                                              |
| ----------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Apple Client** (`SartoMac`) | `MARKETING_VERSION` in `apps/apple/project.yml` | Talks to local/remote daemons via RPC & `runtimeFingerprint`                                                         |
| **Daemon** (`sarto` + hosts)  | `version` in root `package.json`                | Negotiates channel `protocol: { min, max }` with clients; matches `harnesses.json` with `node-semver`                |
| **Server** (`Sarto Cloud`)    | Independent server repository                   | Negotiates `/v1` + `features` via `packages/sarto-wire` (optional `serverVersion` in `GET /v1` for diagnostics only) |

## 2. Semantic Versions, Channels and 12-Digit UTC Build Numbers

Every build regardless of entry point stamps a monotonic 12-digit UTC build number (`YYMMDDHHmmss`, e.g. `261125143512`) and short git commit (`<sha>` or `<sha>-dirty`) into build outputs without mutating checked-in source files.

| Channel  | Semantic Version Format                               | Purpose                                             | Auto-update                                                                                                    |
| -------- | ----------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `stable` | `X.Y.Z` (e.g. `0.4.0`)                                | Production release                                  | Enabled (checks `latest-*.json`)                                                                               |
| `beta`   | `X.Y.Z-beta.<build>` (e.g. `0.4.0-beta.261125143512`) | Signed test channel                                 | Enabled (checks both `beta-*.json` and `latest-*.json`, taking the newer SemVer)                               |
| `dev`    | `X.Y.Z-dev.<build>` (e.g. `0.4.0-dev.261125143512`)   | Local Xcode / `pnpm build:daemon` / ad-hoc packages | Disabled by default (can be enabled for local updater testing with `SARTO_RELEASES_URL` + `SARTO_UPDATE_MODE`) |

### Why SemVer prereleases + `CFBundleVersion` instead of numeric suffix flags

- Apple notarization and LaunchServices expect `CFBundleShortVersionString` to remain pure `X.Y.Z`. Sarto keeps `CFBundleShortVersionString` at `X.Y.Z`, writes the 12-digit build number to `CFBundleVersion`, and writes full metadata into custom `Info.plist` keys: `SartoVersion`, `SartoBuildChannel`, `SartoGitCommit`.
- SemVer 2.0.0 guarantees `0.4.0-dev.<build> < 0.4.0-beta.<build> < 0.4.0 < 0.5.0-beta.<build>`, so beta builds seamlessly upgrade to newer beta builds and automatically graduate onto the stable `0.4.0` release.
- **Beta base-version rule (enforced by `release.mjs` and CI)**: always cut beta releases against the **next upcoming** `X.Y.Z` (e.g., if `0.3.1` is already shipped as stable, cut `0.3.2-beta.<build>` or `0.4.0-beta.<build>`, never `0.3.1-beta.<build>`). Repeated beta builds for that upcoming version automatically increment via `<build>` without bumping `X.Y.Z`, whereas every new `stable` release must bump `X.Y.Z`. Both `tools/sarto/release.mjs` and `.github/workflows/release-mac.yml` enforce this via `checkReleaseVersionOrder` (ignoring only the triggering tag itself on a CI tag push; pass `--allow-older` to `release.mjs` to override), and `apps/apple/scripts/package-mac.mjs` warns when `--channel beta` uses a base version `<=` the latest published stable tag.
- Component identity and daemon installation origin (`bundled`, `standalone`, `checkout`) are stored in explicit metadata fields (`DaemonStatus`, `runtime.json`, About UI, `sarto status` and problem reports) rather than encoded in version digits.

## 3. Build & Packaging Workflows

### Local Development Builds (automatic `dev` stamping)

- **Daemon**:
  ```bash
  pnpm build:daemon
  node out/daemon/main.cjs --version
  # -> 0.3.1-dev.261125143512
  ```
- **Mac App (Xcode / `xcodebuild`)**:
  ```bash
  xcodebuild -project apps/apple/Sarto.xcodeproj -scheme SartoMac build
  ```
  The `Stamp Dev Build Metadata` post-build script in `apps/apple/project.yml` writes `CFBundleVersion`, `SartoVersion`, `SartoBuildChannel=dev` and `SartoGitCommit` directly into the built `Info.plist` before code signing.

### Packaging `Sarto.app` (`apps/apple/scripts/package-mac.mjs`)

```bash
# Ad-hoc local test package (defaults to channel=dev, reads project.yml & package.json)
pnpm package:mac

# Fast local Debug-configuration test package (reuses .cache/sarto-package/)
node apps/apple/scripts/package-mac.mjs --channel dev --debug --skip-helpers

# Recommended local self-test package for /Applications/Sarto.app (Developer ID signed, no notarization)
# Keeps Keychain/TCC grants stable across rebuilds and enables SartoUpdateMode=install;
# use --channel dev to stay off auto-update prompts, or --channel beta to test beta updates.
SARTO_SIGN_IDENTITY="Developer ID Application: <Your Name> (<TeamID>)" \
  node apps/apple/scripts/package-mac.mjs --channel dev

# Package a beta test build with independent app & daemon base versions (pass --clean for a fresh DerivedData)
node apps/apple/scripts/package-mac.mjs \
  --version 0.4.0 \
  --daemon-version 0.5.0 \
  --channel beta

# Package alongside an installed Sarto using a separate bundle identifier
SARTO_BUNDLE_ID=dev.sarto.mac.test node apps/apple/scripts/package-mac.mjs --channel dev
```

`package-mac.mjs` caches Xcode `DerivedData` (`derived-release` / `derived-debug`) and the SHA-256-verified Node.js runtime under `.cache/sarto-package/` (override with `SARTO_PACKAGE_CACHE`) so subsequent local builds run in seconds; `release.mjs` passes `--clean` for clean release builds. `package-mac.mjs` builds the daemon with `SARTO_BUILD_PLACEHOLDER=1`, hashes the unsigned runtime into `runtimeFingerprint`, stamps the real daemon version/build/channel/commit into the bundle via `stampBuildInfo`, writes `Contents/Resources/runtime/runtime.json`, and builds `SartoMac` with `SARTO_PACKAGING=1` so the Xcode dev stamp script is skipped.

### Building Signed Releases (`tools/sarto/release.mjs`)

```bash
# 1. Combined stable release (legacy single vX.Y.Z folder when app and daemon versions match)
node tools/sarto/release.mjs \
  --version 0.4.0 \
  --notes notes.md

# 2. Decoupled stable release (app 0.4.0 bundling daemon 0.5.0 -> app-v0.4.0/ and daemon-v0.5.0/)
node tools/sarto/release.mjs \
  --target all \
  --channel stable \
  --app-version 0.4.0 \
  --daemon-version 0.5.0 \
  --notes notes.md

# 3. Beta channel release (app-v0.4.0-beta.<build>/ and daemon-v0.5.0-beta.<build>/)
node tools/sarto/release.mjs \
  --target all \
  --channel beta \
  --app-version 0.4.0 \
  --daemon-version 0.5.0 \
  --notes notes.md

# 4. App-only hotfix (no standalone daemon package emitted; the bundled daemon keeps the published
#    --daemon-version, package.json's X.Y.Z by default, on either channel)
node tools/sarto/release.mjs \
  --target app \
  --channel stable \
  --app-version 0.4.1 \
  --notes notes.md

# 5. Standalone daemon-only release (notes not required)
node tools/sarto/release.mjs \
  --target daemon \
  --channel beta \
  --daemon-version 0.5.1
```

### Publishing Releases (`tools/sarto/publish-release.mjs`)

```bash
node tools/sarto/publish-release.mjs dist/release/v0.4.0 user@host:/srv/sarto/releases
node tools/sarto/publish-release.mjs dist/release/app-v0.4.0-beta.261125143512 user@host:/srv/sarto/releases
node tools/sarto/publish-release.mjs dist/release/daemon-v0.5.0-beta.261125143512 user@host:/srv/sarto/releases
```

## 4. Signed Channel Manifests & Sarto Cloud Routing Layout

All update manifests are signed with Ed25519 over `"<filename>\n" + bytes` (`tools/sarto/signing.mjs` and `SartoUpdate/Signatures.swift`), so a manifest signed for one channel or component cannot be replayed on another.

| Component & Channel | Manifest File                   | Release Folder (`tag`)            | Pointer File                                                |
| ------------------- | ------------------------------- | --------------------------------- | ----------------------------------------------------------- |
| Mac App (`stable`)  | `latest-mac.json` (+ `.sig`)    | `v<ver>` or `app-v<appVer>`       | `latest-mac`                                                |
| Mac App (`beta`)    | `beta-mac.json` (+ `.sig`)      | `app-v<appVer>`                   | `beta-mac`                                                  |
| Daemon (`stable`)   | `latest-daemon.json` (+ `.sig`) | `v<ver>` or `daemon-v<daemonVer>` | `latest-daemon` (and legacy `latest` for a shared `v<ver>`) |
| Daemon (`beta`)     | `beta-daemon.json` (+ `.sig`)   | `daemon-v<daemonVer>`             | `beta-daemon`                                               |

### Sarto Cloud Releases Folder Contract (`SARTO_RELEASES_DIR`)

`publish-release.mjs` atomically copies each manifest and its `.sig` (and `harnesses.json` when present; `tools/sarto/harnesses.mjs --publish` also writes `harnesses.json` directly to the root) to the root of `SARTO_RELEASES_DIR` in addition to keeping them inside `<tag>/`:

- `GET /releases/latest/download/<file>`:
  - For channel manifests (`latest-mac.json`, `beta-mac.json`, `latest-daemon.json`, `beta-daemon.json`, their `.sig` files) and `harnesses.json`, serve directly from `SARTO_RELEASES_DIR/<file>` (falling back to `SARTO_RELEASES_DIR/v<latest>/<file>` for legacy files).
  - For `install.sh`, `install.sh.sig` and legacy artifacts, resolve via `latest-daemon` / `latest` pointer folders as before.
- `GET /releases/download/<tag>/<file>`:
  - Serve directly from `SARTO_RELEASES_DIR/<tag>/<file>` where `<tag>` is validated against `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` with no `..`.
- `GET /releases/latest`:
  - Keep redirecting (`302`) to `/releases/tag/v<latest>` for backwards compatibility with older daemons before `latest-daemon.json`.

### GitHub Actions Releases (`.github/workflows/release-mac.yml`)

- **Multi-platform 4-job pipeline**:
  - `meta` (`ubuntu-24.04`): resolves unified `target`, `channel`, `build`, `built_at`, tags and macOS delta targets, enforces `checkReleaseVersionOrder`, and runs `format:check`, `lint`, `typecheck` and `test`.
  - `build-mac` (`macos-15`): builds, signs and notarizes `Sarto.app` (ZIP, DMG, delta patches) when `target` includes `app`, and builds `sarto-daemon-darwin-arm64.tar.gz` when `target` includes `daemon`. Receives only Apple signing/notarization secrets.
  - `build-linux-daemon` (`ubuntu-24.04` in `quay.io/pypa/manylinux_2_28_x86_64` and `ubuntu-24.04-arm` in `quay.io/pypa/manylinux_2_28_aarch64`): builds `sarto-daemon-linux-x64.tar.gz` and `sarto-daemon-linux-arm64.tar.gz` via `tools/sarto/build-daemon-package.mjs`, verifying `node-pty` links `GLIBC <= 2.28`, passing PTY and headless `sarto run`/`sarto status` smoke tests. Receives no release secrets.
  - `publish` (`ubuntu-24.04`): sole job holding `SARTO_UPDATE_SIGNING_KEY`, `SARTO_HARNESSES_SIGNING_KEY` and mirror SSH secrets; runs `tools/sarto/assemble-daemon-release.mjs` (requiring all three platforms `darwin-arm64`, `linux-x64`, `linux-arm64`), signs channel manifests and `install.sh`, generates `SHA256SUMS.txt`, attests SLSA provenance, publishes GitHub Releases and mirrors atomically to `sarto.1o.ink`.
- **Tag triggers**:
  - `vX.Y.Z` (or `vX.Y.Z-beta.<build>`): builds `target=all`
  - `app-vX.Y.Z` (or `app-vX.Y.Z-beta.<build>`): builds `target=app`
  - `daemon-vX.Y.Z` (or `daemon-vX.Y.Z-beta.<build>`): builds `target=daemon`
- **Manual dispatch (`workflow_dispatch`)**: accepts `target` (`all|app|daemon`), `channel` (`stable|beta`), optional `version` (App), optional `daemon_version` (Daemon), and `draft`.
- **Pointer safety on GitHub Releases**:
  - Beta releases are published with `--prerelease` so they never move GitHub's `/releases/latest`.
  - Decoupled standalone `daemon-v*` releases are published with `--latest=false` so they never displace `latest-mac.json` on GitHub's `/releases/latest`.
  - Because GitHub's `/releases/latest/download/beta-mac.json` returns `404` when beta releases are prereleases, a beta `SartoUpdater` asks the next configured source (`https://sarto.1o.ink/releases`) whenever an earlier source has no `beta-mac.json`, and takes the newest version any source offered. On either channel, a source older than the running build sends the check on, and one offering the running version ends it.
  - The legacy `latest` pointer moves only with a shared `v<ver>` folder that carries the daemon (`latest-daemon.json` and `install.sh`), since older daemons follow it to `download/v<latest>/install.sh`.

### Standalone Daemon CLI Update, Install & SSH Provisioning

```bash
# Install stable (default) or beta channel on macOS (arm64) or Linux (x64/arm64, glibc 2.28+)
curl -fsSL https://sarto.1o.ink/releases/latest/download/install.sh | sh
curl -fsSL https://sarto.1o.ink/releases/latest/download/install.sh | sh -s -- --channel beta

# Container / non-systemd Linux host
curl -fsSL https://sarto.1o.ink/releases/latest/download/install.sh | sh -s -- --no-service

# Stable channel self-update (verifies latest-daemon.json, pins current platform SHA-256)
sarto update

# Beta channel self-update (verifies beta-daemon.json and latest-daemon.json, installs the newer SemVer)
sarto update --channel beta

# Direct install of a decoupled tag
curl -fsSL https://sarto.1o.ink/releases/download/daemon-v0.5.0-beta.261125143512/install.sh \
  | sh -s -- --version 0.5.0-beta.261125143512 --tag daemon-v0.5.0-beta.261125143512
```

When `install.sh` is called with `--version` alone (without `--tag`), it tries `download/daemon-v<version>` first and falls back to `download/v<version>`. Over SSH (`src/remote-host/ssh.ts`), beta daemons pass `--tag daemon-v<version>` automatically, while local `dev` builds omit `--version` so SSH provisioning installs the latest published release instead of failing on a local `-dev.<build>` tag.

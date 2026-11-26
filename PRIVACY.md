# Sarto Privacy & Cryptographic Architecture

[简体中文](./PRIVACY.zh-CN.md) · [Wire Protocol](./packages/sarto-wire/PROTOCOL.md) · [Security Policy](./SECURITY.md)

Sarto is an open-source client (`AGPL-3.0`) that optionally connects to Sarto Cloud (`https://sarto.1o.ink`, closed-source) for multi-Mac encrypted sync, encrypted remote relay, push notifications, and release downloads. Because an agentic development environment (ADE) handles source code, terminal sessions, and API keys, Sarto is designed so **you do not have to trust the closed-source server to keep your sensitive data confidential**.

All client networking, wire contracts ([`packages/sarto-wire/PROTOCOL.md`](./packages/sarto-wire/PROTOCOL.md)), and cryptographic implementations live in this open-source repository and can be audited directly.

---

## 1. What Never Leaves Your Machine

- **Source code and project files**: Sarto never uploads your repositories or workspace files to Sarto Cloud.
- **Conversation history database (`threads`)**: Your agent chat transcripts stay strictly in local storage; they are not included in Cloud Sync.
- **Agent provider credentials**: Sarto does not store or upload your Claude Code, Codex, Gemini, or other agents' own login sessions.
- **Machine-local configuration**: Local binary paths, config folders, and HTTP/SOCKS proxy credentials are excluded from Cloud Sync.
- **Zero telemetry or analytics**: Sarto includes no usage tracking SDKs, analytics beacons, or automatic crash reporters.

---

## 2. Complete Data Flow Breakdown

### A. Signed Out (Read-Only Public Requests)

You can use Sarto completely locally without creating or signing in to a Sarto account. When signed out, Sarto sends only read-only, unauthenticated requests to `https://sarto.1o.ink`, plus the third-party requests in [section D](#d-direct-third-party-connections-not-routed-through-sarto-cloud):

| Purpose                        | Endpoint & Cadence                                                                                                                                    | Visible to Server                                              | Client Code                                                                  |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| macOS app updates              | Hourly `GET /releases/sources.json`, `latest/download/latest-mac.json(.sig)` (or `beta-mac.json(.sig)`)                                               | IP address, `User-Agent` (app version, arch)                   | [`SartoUpdater.swift`](./apps/apple/macOS/Updates/SartoUpdater.swift)        |
| CLI daemon updates             | Manual `sarto update`: `GET /releases/latest/download/latest-daemon.json(.sig)` (or `beta-daemon.json(.sig)`), `/releases/latest`, `install.sh(.sig)` | IP address, `User-Agent` (`Sarto-daemon/<ver> (<os>; <arch>)`) | [`src/daemon/update.ts`](./src/daemon/update.ts)                             |
| Harness compatibility manifest | `GET /releases/latest/download/harnesses.json`                                                                                                        | IP address, `User-Agent`                                       | [`src/agent-host/harness-manifest.ts`](./src/agent-host/harness-manifest.ts) |
| Daily model price snapshot     | Every 24h `GET /v1/prices`                                                                                                                            | IP address, `If-None-Match` ETag (no account token)            | [`src/daemon/prices.ts`](./src/daemon/prices.ts)                             |

> [!TIP]
> The app downloads update files from GitHub Releases (`github.com/Rladmsrl/Sarto/releases`) first and falls back to `sarto.1o.ink`; both serve the same signed files.

> [!TIP]
> To minimize outbound requests: set **Settings → Advanced & About → Updates** to **Off**, and do not sign in to Sarto Cloud. Problem reports are sent only when you submit one.

---

### B. Signed In — End-to-End Encrypted (Server Sees Ciphertext Only)

When you sign in to Sarto Cloud and initialize an E2EE Sync Vault or connect across your devices, all sensitive payloads are encrypted on your device before transmission:

| Channel / Scope                                                          | Protected User Content                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Cryptography                                                                                                                                                                      | Client Code                                                                                                                      |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **Remote Relay Tunnels** (`/v1/hosts/<id>/connect` ↔ `/accept/<token>`)  | All remote agent sessions, diffs, file reads/uploads, PTY terminal I/O, permission approvals, and host-admin RPCs                                                                                                                                                                                                                                                                                                                                                          | `Noise_IK_25519_AESGCM_SHA256` (paired) / `Noise_IKpsk1` (QR pairing); AES-256-GCM; automatic `Rekey()` every 1 GiB or 1 hour; power-of-2 frame padding (256 B – 65,519 B)        | [`src/shared/remote/noise.ts`](./src/shared/remote/noise.ts), [`src/shared/remote/channel.ts`](./src/shared/remote/channel.ts)   |
| **Sync Scopes** (`/v1/sync/scopes/*`)                                    | • `ui-prefs`: UI preferences, fonts, notifications, browser allowlist<br>• `host-config`: default agent, pinned models, start modes<br>• `mcp-servers`: installed MCP server definitions<br>• **`mcp-vault`**: MCP API keys, OAuth tokens, and agent environment secrets<br>• `skills`: skill metadata and encrypted blob references<br>• `themes`: custom theme JSON<br>• **`memory-and-mesh`**: global Memory Markdown entries and trusted host/device Noise public keys | 256-bit random Sync Master Key (`SMK`) → `HKDF-SHA256` per-scope subkeys → `AES-256-GCM` with random 96-bit IV per write and AAD binding `(scope, rev, keyEpoch, encoding)`       | [`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts), [`src/daemon/sync/service.ts`](./src/daemon/sync/service.ts)         |
| **Skill Archives** (`/v1/sync/blobs/<sha256>`)                           | Packed contents of synced skill folders                                                                                                                                                                                                                                                                                                                                                                                                                                    | Compressed, then sealed with `HKDF(SMK, 'cas-blob')` + `AES-256-GCM`; CAS SHA-256 is computed over **ciphertext** (never plaintext) to prevent cross-account content probing      | [`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts)                                                                       |
| **Multi-Mac Usage** (`/v1/sync/scopes/usage/items/:key`)                 | Per-Mac 15-minute token usage buckets (including project paths), plan limits/balances, 48h quota history, and Usage Island snapshots                                                                                                                                                                                                                                                                                                                                       | Gzip-compressed, then sealed with `HKDF(SMK, 'scope/usage')` + `AES-256-GCM` with AAD binding `(usage, itemKey, rev, keyEpoch, gzip)`                                             | [`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts), [`src/shared/sync/protocol.ts`](./src/shared/sync/protocol.ts)       |
| **Push Notification Payloads** (`POST /v1/push` `sealed` / `attributes`) | Notification title, body, session ID, host name, permission request ID, and quick-action labels                                                                                                                                                                                                                                                                                                                                                                            | Ephemeral X25519 DH to device static key → `HKDF-SHA256` → `AES-256-GCM`, with inner Ed25519 host signature; APNs only receives a generic placeholder (`"Agent activity update"`) | [`src/shared/remote/push.ts`](./src/shared/remote/push.ts), [`src/remote-host/push-sender.ts`](./src/remote-host/push-sender.ts) |

---

### C. Signed In — Plaintext Metadata & Opt-In Uploads (HTTPS/TLS Only)

The following metadata is visible to Sarto Cloud in plaintext (protected in transit by HTTPS/TLS) because the server needs it for authentication, routing, quotas, or diagnostics:

| Feature                                                                        | Plaintext Fields Visible to Sarto Cloud                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Storage & Retention                                                                                                                                            |
| ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Account & OAuth Sessions** (`/api/oauth/*`, `/api/v1/me`, `/api/v1/devices`) | Email, display name, avatar URL, linked OAuth provider identities (Google/GitHub/LinuxDO), scrypt password hash (if password login is used), and per-session `client_info`: `kind`, **device/host name**, OS version, CPU arch, Sarto version, optional CLI system username, timestamps, and IP address (for rate limiting).                                                                                                                                                                                                                                                                                                                                                                                                  | Stored in server account store & OAuth SQLite DB until revoked/deleted.                                                                                        |
| **Web Theme Preference** (`PUT /api/v1/me/preferences`)                        | Active optical palette name (`obsidian`, `warm`, `crystal`, `alabaster`) so the web console matches your app theme.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Stored on account record.                                                                                                                                      |
| **Relay Signaling & Online Presence** (`WS /v1/hosts/<id>`, `GET /v1/hosts`)   | Host Ed25519 public key & `hostId`, host X25519 channel public key, **host name**, **platform**, online timestamps, active tunnel counts, and encrypted frame timing/padded lengths.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Held in memory only while connected (not persisted to disk).                                                                                                   |
| **Sync Vault Metadata** (`/v1/sync/*`, `WS /v1/sync/stream`)                   | • **Keybag v2**: approved devices' `deviceId`, X25519 public keys, **device names**, OAuth family ID, `keyEpoch`, `addedAt`, approver public key/MAC, and `authVerifier` (SHA-256 of an SMK-derived proof token).<br>• **Device approval mailbox (15-min TTL)**: requesting/approving device names, platforms, public keys, commitment, and nonces.<br>• **Scope & usage index**: scope names, revision counters (`rev`), update timestamps, random `nodeId`, ciphertext SHA-256 & byte sizes, and hashed per-Mac `usage` key (`SHA-256("sarto:" + IOPlatformUUID)[0..16]`).                                                                                                                                                  | Stored in sync SQLite DB; approval entries expire after 15 minutes.                                                                                            |
| **Push Gateway Routing** (`POST /v1/push`)                                     | Host Ed25519 public key & signature, `accountId`, timestamp, target APNs / Live Activity token, APNs environment (`production`/`sandbox`), push type, opaque `collapse` tag (hashed with device's secret X25519 public key), and ciphertext length.                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Not stored; validated for replay/rate-limit and forwarded to Apple APNs.                                                                                       |
| **Problem Reports (Opt-In Only)** (`POST /api/v1/reports`)                     | **Not end-to-end encrypted.** Uploaded **only** when you explicitly submit a report via **Help → Report a Problem…** or `sarto report`. Contains title, description, version, platform, **device name**, account (or anonymous), and a ZIP bundle (≤50 MiB). Before packaging, Sarto automatically masks detected secrets and replaces home paths with `~`, and lets you preview every file. Default files: `report.json`, redacted `settings.json`, `agents.json`, `host-log.json`, `sessions.json` (titles & project names excluded by default), and `logs/*.log`. **Only when explicitly checked by you**: session titles/projects/branches, raw agent traffic & stderr (`messages/*.json`), crash dumps, and screenshots. | Stored privately on Sarto Cloud for 90 days; accessible to the reporter and Sarto maintainers (`owner`) for debugging; signed-in reporters can delete anytime. |

---

### D. Direct Third-Party Connections (Not Routed Through Sarto Cloud)

Depending on the features and agents you enable, Sarto communicates directly with third-party services:

- **Extensions & Registries**: `registry.modelcontextprotocol.io`, `cdn.agentclientprotocol.com`, `registry.npmjs.org`, `pypi.org`, and `github.com` / `api.github.com` / `codeload.github.com` (when browsing/installing MCP servers, ACP agents, or skills). Sarto also checks `registry.npmjs.org` daily for updates of the agents it installed with npm.
- **Vendor Quota & Usage APIs**: Official endpoints of agents you have installed and signed in to (such as OpenAI/ChatGPT, Cursor, Cline, Kimi, MiniMax, Codeium/Devin, Factory).
- **Your Coding Agents**: Each coding agent connects directly to its own configured LLM provider.

---

## 3. Can the Closed-Source Server Decrypt Your E2EE Data?

Evaluated under a **malicious-server threat model** (assuming full server compromise or adversarial server behavior):

### Passive Eavesdropping or Database Breach: **No**

- The server never receives your `SMK`, your 128-bit random recovery key, your device X25519 sync private key, or your host/device Noise static private keys.
- The recovery wrap uses `HKDF-SHA256` over **128 bits of uniform cryptographic randomness** (not a user-chosen password), making offline brute-force infeasible ($2^{128}$ search space).
- `authVerifier` uses domain-separated `HKDF-SHA256` + `SHA-256`; even when a device presents its proof token during recovery-key enrollment, neither `SMK` nor any scope subkey can be derived from it.
- Every sync envelope authenticates `(scope, itemKey, rev, keyEpoch, encoding)` via AES-256-GCM AAD, preventing ciphertext tampering or cross-scope swapping.
- Paired relay tunnels run `Noise_IK` with pinned static X25519 keys on both sides; the relay cannot decrypt or MITM an established pairing.

### Active Attacks & Trust Boundaries You Should Know

1. **Always compare verification codes when adding a new device**:
   - **Sync Vault device approval** uses an **8-character code (`XXXX-XXXX`, 40-bit)** derived via a `commit-then-reveal` protocol ([`PROTOCOL.md §4.1`](./packages/sarto-wire/PROTOCOL.md#41-approving-a-device)). A malicious server cannot grind a matching code (random collision probability $2^{-40} \approx 10^{-12}$), and the new device refuses any key wrap without a verified `approval` MAC from the user-confirmed approver. **However, if you click "Approve" on your existing Mac without comparing the 8-character code shown on both devices**, an active malicious server could trick your existing Mac into sealing the `SMK` to a server-controlled key.
   - **Account-discovery remote pairing** uses a **6-digit code** bound to the Noise `handshakeHash` via `commit-then-reveal` (3 failed attempts trigger a 10-minute cooldown). Always confirm the 6-digit code matches on both screens.
2. **Software updates & supply chain**:
   - App updates, daemon `install.sh`, `sources.json`, and `harnesses.json` are verified against **Ed25519 public keys** compiled into the open-source client ([`tools/sarto/update-keys.json`](./tools/sarto/update-keys.json)), and `Sarto.app` additionally verifies the macOS **Apple Code Signature** against its own identity before swapping bundles.
   - Compromising the cloud server alone **cannot** push a backdoored update. Only the holder of the release signing key and Apple Developer certificate can sign a release; users requiring maximum assurance can build from source.
3. **Metadata & fresh-device rollback**:
   - A malicious server can observe plaintext metadata (account email, device names, IPs, timing, ciphertext sizes) and can deny service or serve an older previously valid `rev` to a brand-new device joining for the first time (existing devices reject `rev < currentRev`). It still cannot decrypt or forge ciphertext.

---

## 4. Independent Verification & Build Provenance

You do not have to take this document on faith. Because the client and daemon are open source and official releases are built directly from public commits in [GitHub Actions](./.github/workflows/release-mac.yml) with signed SLSA Build Provenance Attestations, you can verify both the **source code** and the **installed binary**:

1. **Verify build provenance** (proves the downloaded artifact was built untouched from a public commit in this repository):
   ```sh
   gh attestation verify Sarto-<version>-arm64.dmg --repo Rladmsrl/Sarto
   ```
2. **Verify checksums & Apple Code Signature**:
   ```sh
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   codesign --verify --deep --strict --verbose=2 /Applications/Sarto.app
   ```
3. **Inspect live network connections on your Mac** (optional):
   ```sh
   lsof -i -n -P | grep -E "Sarto|node"
   ```
   You can also audit the key cryptographic & network source files listed in [SECURITY.md](./SECURITY.md) directly or with any AI model of your choice.

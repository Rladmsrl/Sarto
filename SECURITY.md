# Security & Privacy Policy

> Language: **English** · [简体中文](./SECURITY.zh-CN.md)

Sarto runs coding agents that execute shell commands, and its daemon accepts encrypted connections from paired devices, so security and privacy are core invariants rather than afterthoughts.

## Privacy & Cryptographic Architecture

Because Sarto's client and daemon are open source while Sarto Cloud (`https://sarto.1o.ink`) is closed source, Sarto's protocols are designed so you **do not have to trust the cloud server** with your sensitive data.

### Documentation & Specifications

- **[PRIVACY.md](./PRIVACY.md)** ([简体中文](./PRIVACY.zh-CN.md)) — Full breakdown of everything that stays strictly local, everything uploaded encrypted vs. plaintext, and a malicious-server threat-model analysis.
- **[packages/sarto-wire/PROTOCOL.md](./packages/sarto-wire/PROTOCOL.md)** — Public Apache-2.0 wire protocol specification for Keybag v2 E2EE sync, `Noise_IK` relay framing, push envelopes, and signed releases.

### Data Boundary Summary

| Category                        | Scope                                                                                                                                                                                                            | Cloud Visibility                                        |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| **Never leaves your machine**   | Source code, project files, chat histories (`threads` DB), agents' own sign-ins, telemetry (none)                                                                                                                | Not transmitted                                         |
| **End-to-end encrypted (E2EE)** | Sync Vault (`ui-prefs`, `host-config`, `mcp-servers`, `mcp-vault` secrets/OAuth/env, `skills`, `themes`, `memory-and-mesh`, per-Mac `usage`), remote relay sessions/terminals (`Noise_IK`), mobile push payloads | Ciphertext only (cannot passively decrypt)              |
| **Plaintext metadata**          | Account email/profile, device registry (name, OS, arch, version, IP, X25519 pubkey), sync scope names/revisions/sizes, relay routing headers, APNs tokens                                                        | Visible over HTTPS                                      |
| **Opt-in manual submission**    | Problem Reports (**Help → Report a Problem…**), locally redacted and previewed file-by-file before sending                                                                                                       | Visible only when you explicitly click Submit           |
| **Direct third-party traffic**  | Model provider APIs & CLI harnesses (Claude, Codex, Gemini, etc.) and optional third-party MCP servers                                                                                                           | Direct from your machine (never proxied by Sarto Cloud) |

### Key Open-Source Files for Independent Audit

- Sync E2EE cryptography (`HKDF-SHA256`, `AES-256-GCM`, Keybag v2, 8-char `commit-then-reveal` approval): [`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts) · [`src/daemon/sync/service.ts`](./src/daemon/sync/service.ts)
- Remote relay & push encryption (`Noise_IK_25519_AESGCM_SHA256`, X25519 push envelopes): [`src/shared/remote/noise.ts`](./src/shared/remote/noise.ts) · [`src/shared/remote/push.ts`](./src/shared/remote/push.ts)
- Cloud account & opt-in problem report uploads: [`src/shared/account-api.ts`](./src/shared/account-api.ts) · [`src/daemon/problem-report.ts`](./src/daemon/problem-report.ts)
- Local Keychain secret storage (`0600`/`0700`): [`src/core/account/store.ts`](./src/core/account/store.ts) · [`src/core/market-keys.ts`](./src/core/market-keys.ts)
- Ed25519 update & harness manifest verification keys: [`tools/sarto/update-keys.json`](./tools/sarto/update-keys.json)

### Verifiable Builds (GitHub Actions Provenance)

Official releases are built from public commits via [`.github/workflows/release-mac.yml`](./.github/workflows/release-mac.yml) with signed GitHub Build Provenance Attestations (from the first public release on) and `SHA256SUMS.txt`, proving that the distributed binary matches this open-source repository:

```sh
# 1. Verify SLSA build provenance tied to this repository & commit
gh attestation verify Sarto-<version>-arm64.dmg --repo Rladmsrl/Sarto

# 2. Verify release checksum & Apple Code Signature
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
codesign --verify --deep --strict --verbose=2 /Applications/Sarto.app
```

---

## Reporting a Security Vulnerability

Report security vulnerabilities privately through GitHub's [private vulnerability reporting](../../security/advisories/new) — never in a public issue, pull request, or discussion.

### Supported Versions

Only the latest release receives security fixes.

### After You Report

We read every report and reply promptly. Confirmed vulnerabilities are fixed in a new release and published with a security advisory.

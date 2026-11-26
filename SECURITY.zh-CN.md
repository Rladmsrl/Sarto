# 安全与隐私声明

> 语言：[English](./SECURITY.md) · **简体中文**

Sarto 负责调度可执行终端命令的编码智能体，其 daemon 同时接收来自已配对设备的加密连接，因此安全与隐私是 Sarto 的核心底线。

## 隐私声明与加密架构

Sarto 的客户端与 daemon 完全开源，而 Sarto Cloud（`https://sarto.1o.ink`）为闭源服务端。Sarto 在协议设计上确保你**无需信任闭源服务端即可保护敏感数据机密性**。

### 核心文档与协议规范

- **[PRIVACY.zh-CN.md](./PRIVACY.zh-CN.md)**（[English](./PRIVACY.md)）—— 完整列出严格留在本地的数据、加密上传与明文元数据清单，以及针对闭源服务端的威胁模型分析。
- **[packages/sarto-wire/PROTOCOL.md](./packages/sarto-wire/PROTOCOL.md)** —— 公开的 Apache-2.0 通信协议规范（Keybag v2 端到端加密同步、`Noise_IK` 中继帧协议、推送加密信封与签名发布规范）。

### 数据边界一览

| 分类                   | 覆盖内容                                                                                                                                                                                                 | 服务端可见性                        |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| **永不离开本机**       | 源代码、项目文件、对话历史数据库（`threads`）、各 Agent 自身的登录、无任何遥测/埋点                                                                                                                      | 不上传                              |
| **端到端加密（E2EE）** | 云同步保险库（`ui-prefs`、`host-config`、`mcp-servers`、`mcp-vault` 密钥/OAuth/环境变量、`skills`、`themes`、`memory-and-mesh`、每台 Mac `usage`）、远程中继会话与终端流量（`Noise_IK`）、移动端推送正文 | 仅见密文（无法被动解密）            |
| **明文元数据**         | 账号邮箱/资料、设备注册信息（名称/系统/架构/版本/IP/X25519 公钥）、同步 scope 名称/版本号/密文大小、中继路由头、APNs Token                                                                               | 通过 HTTPS 对服务端可见             |
| **手动选择上报**       | 问题报告（**帮助 → 报告问题…**），上传前在本地自动脱敏并支持逐文件预览                                                                                                                                   | 仅在你主动点击提交后可见            |
| **直连第三方服务**     | 你配置的模型供应商 API 与 CLI 工具（Claude、Codex、Gemini 等）及自行安装的第三方 MCP 服务器                                                                                                              | 由本机直连（不经 Sarto Cloud 转发） |

### 关键开源代码审计索引

- 云同步端到端加密（`HKDF-SHA256`、`AES-256-GCM`、Keybag v2、8 位 `commit-then-reveal` 审批码）：[`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts) · [`src/daemon/sync/service.ts`](./src/daemon/sync/service.ts)
- 远程中继与推送加密（`Noise_IK_25519_AESGCM_SHA256`、X25519 推送信封）：[`src/shared/remote/noise.ts`](./src/shared/remote/noise.ts) · [`src/shared/remote/push.ts`](./src/shared/remote/push.ts)
- 云账号接口与手动问题报告上传：[`src/shared/account-api.ts`](./src/shared/account-api.ts) · [`src/daemon/problem-report.ts`](./src/daemon/problem-report.ts)
- 本机钥匙串与 `0600`/`0700` 密钥存储：[`src/core/account/store.ts`](./src/core/account/store.ts) · [`src/core/market-keys.ts`](./src/core/market-keys.ts)
- Ed25519 更新与 Agent 兼容清单验签公钥：[`tools/sarto/update-keys.json`](./tools/sarto/update-keys.json)

### 可验证的公开自动构建（GitHub Actions 溯源证明）

官方发布版本通过 [`.github/workflows/release-mac.yml`](./.github/workflows/release-mac.yml) 从公开 Commit 在 GitHub Runner 上自动构建，并附带由 GitHub 签名的 SLSA 构建溯源证明（Build Provenance Attestation，自首个公开版本起）与 `SHA256SUMS.txt`，确保你下载的安装包与本开源仓库源码完全一致：

```sh
# 1. 验证构建溯源证明（绑定到本仓库与具体公开 Commit）
gh attestation verify Sarto-<version>-arm64.dmg --repo Rladmsrl/Sarto

# 2. 验证 SHA-256 摘要与 Apple 代码签名
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
codesign --verify --deep --strict --verbose=2 /Applications/Sarto.app
```

---

## 安全漏洞上报

如发现安全漏洞，请通过 GitHub 的 [私密漏洞上报通道](../../security/advisories/new) 提交，请勿在公开 Issue、Pull Request 或讨论区披露。

### 支持版本

仅最新版本提供安全修复更新。

### 处理流程

我们会阅读并回复每一份报告；确认漏洞后将发布包含修复的新版本并同步公开安全公告。

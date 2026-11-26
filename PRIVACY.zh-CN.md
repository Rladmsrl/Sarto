# Sarto 隐私说明与加密架构

[English](./PRIVACY.md) · [通信协议规范](./packages/sarto-wire/PROTOCOL.md) · [安全策略](./SECURITY.md)

Sarto 的客户端与 daemon 完全开源（`AGPL-3.0`），并可选连接 Sarto Cloud（`https://sarto.1o.ink`，闭源服务端）以提供多 Mac 加密同步、跨设备加密中继、移动端推送通知与签名更新分发。由于编程 Agent 工作台（ADE）涉及源代码、终端会话与 API 密钥等高度敏感信息，Sarto 的核心设计原则是：**即使服务端闭源且完全不可信，服务端也无法解密你的端到端加密数据**。

客户端的全部网络调用、通信协议契约（[`packages/sarto-wire/PROTOCOL.md`](./packages/sarto-wire/PROTOCOL.md)）与密码学实现均在本开源仓库中公开可审计。

---

## 一、绝对不会上传到 Sarto Cloud 的内容

- **本地源代码与项目文件**：Sarto 不会将你的代码仓库或工作区文件上传至 Sarto Cloud。
- **对话历史数据库（`threads`）**：Agent 会话记录仅保存在你的本机磁盘，不参与云同步。
- **各 Agent 自身的登录凭据**：Sarto 不保存也不会上传 Claude Code、Codex、Gemini 等工具自身的登录会话。
- **本机专有配置**：本地二进制路径、配置目录以及 HTTP/SOCKS 代理凭据不会参与云同步。
- **零遥测与零埋点**：客户端不包含任何行为统计 SDK、分析埋点或静默崩溃上报。

---

## 二、客户端上传与外联全量清单

### 1. 未登录 Sarto Cloud 时（仅只读公开拉取）

Sarto 账号完全可选，不登录即可完整使用全部本机 ADE 功能。未登录状态下，客户端只向 `https://sarto.1o.ink` 发送匿名只读请求，另有下文「不经过 Sarto Cloud 的第三方直连」所列请求：

| 用途               | 接口与频率                                                                     | 服务端可见信息                                             | 对应客户端源码                                                               |
| ------------------ | ------------------------------------------------------------------------------ | ---------------------------------------------------------- | ---------------------------------------------------------------------------- |
| macOS 应用更新检查 | 每小时 `GET /releases/sources.json`、`latest/download/sarto-update.json(.sig)` | IP、`User-Agent`（App 版本、架构）                         | [`SartoUpdater.swift`](./apps/apple/macOS/Updates/SartoUpdater.swift)        |
| Daemon CLI 更新    | 手动执行 `sarto update`：`GET /releases/latest`、`install.sh(.sig)`            | IP、`User-Agent`（`Sarto-daemon/<版本> (<系统>; <架构>)`） | [`src/daemon/update.ts`](./src/daemon/update.ts)                             |
| Agent 兼容清单     | `GET /releases/latest/download/harnesses.json`                                 | IP、`User-Agent`                                           | [`src/agent-host/harness-manifest.ts`](./src/agent-host/harness-manifest.ts) |
| 每日模型价格快照   | 每 24 小时 `GET /v1/prices`                                                    | IP、`If-None-Match` ETag（不携带账号 Token）               | [`src/daemon/prices.ts`](./src/daemon/prices.ts)                             |

> [!TIP]
> 应用更新文件优先从 GitHub Releases（`github.com/Rladmsrl/Sarto/releases`）下载，失败时回退到 `sarto.1o.ink`，两处提供的是同一份签名文件。

> [!TIP]
> 如需尽可能减少对外连接：可在 **设置 → 高级与关于 → 更新** 中关闭自动更新，并不登录 Sarto Cloud。问题报告只在你主动提交时才会发送。

---

### 2. 登录 Sarto Cloud 后：**端到端加密（E2EE）内容**（服务端仅见密文）

登录并初始化端到端加密保险库或连接其他设备后，所有核心敏感数据均在离开本机前完成加密：

| 通道 / 同步范围                                                        | 实际保护的用户数据                                                                                                                                                                                                                                                                                                                                                                   | 加密方案                                                                                                                                                                                                  | 对应客户端源码                                                                                                                   |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **远程中继隧道**（`/v1/hosts/<id>/connect` ↔ `/accept/<token>`）       | 跨设备远程操作时的全部对话消息、代码 Diff、文件读写与上传下载、PTY 终端输入输出、权限审批与主机管理指令                                                                                                                                                                                                                                                                              | `Noise_IK_25519_AESGCM_SHA256`（已配对）/ `Noise_IKpsk1`（扫码配对）；AES-256-GCM；每 1 GiB 或每小时自动 `Rekey()`；帧长度对齐 2 的幂次填充（256 B – 65,519 B）；服务端仅转发二进制密文                   | [`src/shared/remote/noise.ts`](./src/shared/remote/noise.ts), [`src/shared/remote/channel.ts`](./src/shared/remote/channel.ts)   |
| **云同步 7 大 Scope**（`/v1/sync/scopes/*`）                           | • `ui-prefs`：界面偏好、字体、通知开关、浏览器白名单<br>• `host-config`：默认 Agent、置顶模型、启动模式等<br>• `mcp-servers`：已安装 MCP 服务器配置<br>• **`mcp-vault`**：MCP API 密钥、OAuth 令牌与 Agent 环境变量密钥<br>• `skills`：Skill 元数据与加密归档索引<br>• `themes`：自定义主题 JSON<br>• **`memory-and-mesh`**：全局 Memory Markdown 条目与已信任主机/设备的 Noise 公钥 | 本机生成 256-bit 随机同步主密钥（`SMK`）→ `HKDF-SHA256` 按 scope 派生独立子密钥 → `AES-256-GCM`（每次写入随机 96-bit IV，AAD 严格绑定 `scope/rev/keyEpoch/encoding`）                                     | [`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts), [`src/daemon/sync/service.ts`](./src/daemon/sync/service.ts)         |
| **Skill 归档包**（`/v1/sync/blobs/<sha256>`）                          | 同步的 Skill 文件夹打包内容                                                                                                                                                                                                                                                                                                                                                          | 压缩后使用 `HKDF(SMK, 'cas-blob')` + `AES-256-GCM` 加密；寻址哈希是对**密文**计算 SHA-256（而非明文），防止跨账号明文探测                                                                                 | [`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts)                                                                       |
| **多 Mac 用量记录**（`/v1/sync/scopes/usage/items/:key`）              | 每台 Mac 的 15 分钟 Token 用量桶（含项目路径）、套餐限额与余额、近 48 小时额度历史及灵动岛用量数据                                                                                                                                                                                                                                                                                   | 先 gzip 压缩，再使用 `HKDF(SMK, 'scope/usage')` + `AES-256-GCM` 加密（AAD 绑定 `usage/itemKey/rev/keyEpoch/gzip`）                                                                                        | [`src/shared/sync/crypto.ts`](./src/shared/sync/crypto.ts), [`src/shared/sync/protocol.ts`](./src/shared/sync/protocol.ts)       |
| **移动端离线推送正文**（`POST /v1/push` 中的 `sealed` / `attributes`） | 推送标题、正文、会话 ID、主机名、权限请求 ID 与快捷操作按钮                                                                                                                                                                                                                                                                                                                          | 每次推送生成临时 X25519 密钥对与目标设备公钥做 DH → `HKDF-SHA256` → `AES-256-GCM`，内部附加主机 Ed25519 签名；发往 Apple APNs 的外层文案固定为通用占位词（`"Agent activity update"`），在设备本地解密还原 | [`src/shared/remote/push.ts`](./src/shared/remote/push.ts), [`src/remote-host/push-sender.ts`](./src/remote-host/push-sender.ts) |

---

### 3. 登录 Sarto Cloud 后：**不加密的明文元数据与手动提交项**（仅受 HTTPS/TLS 传输保护）

以下元数据为实现登录鉴权、连接路由、配额统计或用户主动报障所需，对服务端可见：

| 模块                                                                         | 服务端可见的明文内容                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | 存储与保留方式                                                                         |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **账号与 OAuth 设备会话**（`/api/oauth/*`、`/api/v1/me`、`/api/v1/devices`） | 邮箱、昵称、头像 URL、绑定的第三方登录身份（Google/GitHub/LinuxDO）、密码的 scrypt 哈希（如使用密码登录）；每次登录及刷新令牌时上报 `client_info`：`kind`、**设备名/主机名**、系统版本、架构、Sarto 版本、可选 CLI 系统用户名、活跃时间及来源 IP（用于限流）。                                                                                                                                                                                                                                                | 存于服务端账号数据与 OAuth SQLite，移除设备或登出后吊销。                              |
| **Web 主题偏好**（`PUT /api/v1/me/preferences`）                             | 当前光学调色板名称（`obsidian` / `warm` / `crystal` / `alabaster`），用于让官网与云控制台与 App 保持一致外观。                                                                                                                                                                                                                                                                                                                                                                                                | 存于账号记录。                                                                         |
| **中继信令与在线状态**（`WS /v1/hosts/<id>`、`GET /v1/hosts`）               | 主机 Ed25519 公钥与 `hostId`、主机 X25519 通道公钥、**主机名**、**平台**、在线时间、隧道数量，以及密文帧收发时间与填充后的字节长度。                                                                                                                                                                                                                                                                                                                                                                          | 仅存服务端内存（不落盘）。                                                             |
| **云同步元数据**（`/v1/sync/*`、`WS /v1/sync/stream`）                       | • **Keybag v2**：已批准设备的 `deviceId`、X25519 公钥、**设备名**、OAuth 家族 ID、`keyEpoch`、`addedAt`、审批者公钥与 MAC、`authVerifier`（SMK 派生证明的 SHA-256）。<br>• **设备审批邮箱（15 分钟过期）**：请求/审批双方的设备名、平台、公钥、`commitment` 与随机数。<br>• **Scope 与用量索引**：scope 名称、版本号 `rev`、更新时间、随机 `nodeId`、密文 SHA-256 与字节大小，以及哈希后的用量设备键（`SHA-256("sarto:" + IOPlatformUUID)[0..16]`）。                                                         | 存于同步 SQLite；待审批记录 15 分钟后过期清除。                                        |
| **推送网关路由头**（`POST /v1/push`）                                        | 主机 Ed25519 公钥与请求签名、`accountId`、时间戳、目标 APNs / Live Activity Token、环境（`production`/`sandbox`）、推送类型、不透明折叠标签 `collapse`（由服务端未知的设备公钥参与哈希）及密文大小。                                                                                                                                                                                                                                                                                                          | 不落盘，校验签名与限流后直接转发至 Apple APNs。                                        |
| **问题报告（仅用户主动提交）**（`POST /api/v1/reports`）                     | **不进行端到端加密。**仅在你主动通过 **帮助 → 报告问题…** 或 `sarto report` 确认发送时上传。包含标题、描述、版本、平台、**设备名**、账号（可匿名）及 ZIP 附件（≤50 MiB）。打包前会自动对常见密钥/Token 脱敏并将家目录替换为 `~`，且支持逐文件预览。默认包含 `report.json`、脱敏后的 `settings.json`、`agents.json`、`host-log.json`、`sessions.json`（默认不含标题与项目名）及 `logs/*.log`；**仅在你显式勾选时**才附带会话标题/项目/分支、Agent 原始通信流量与 stderr（`messages/*.json`）、崩溃转储或截图。 | 私密保存 90 天，仅提交者本人与 Sarto 维护者（`owner`）可查看下载，登录用户可随时删除。 |

---

### 4. 不经过 Sarto Cloud 的第三方直连

当你使用对应功能或启用特定 Agent 时，客户端会直接连接第三方官方服务（不经由 Sarto Cloud）：

- **扩展与市场目录**：`registry.modelcontextprotocol.io`、`cdn.agentclientprotocol.com`、`registry.npmjs.org`、`pypi.org`、`github.com` / `api.github.com` / `codeload.github.com`（浏览或安装 MCP 服务器、ACP Agent 或 Skill 时）。Sarto 还会每天向 `registry.npmjs.org` 检查经 npm 安装的 Agent 是否有更新。
- **各 AI 厂商额度/余额查询**：仅针对你本机已安装并登录的 Agent（如 OpenAI/ChatGPT、Cursor、Cline、Kimi、MiniMax、Codeium/Devin、Factory 等官方接口）。
- **各编程 Agent 本体**：直接与各自配置的 LLM API 通信。

---

## 三、闭源服务端有没有破解加密数据的可能？

我们直接按**「假设服务端完全不可信 / 已被攻破」**的威胁模型给出透明分析：

### 被动窃听或服务端脱库：**不能破解**

- 服务端从不持有你的 `SMK`、128-bit 随机恢复密钥、本机 X25519 同步私钥，或主机的 Noise 静态私钥。
- 恢复密钥的封装虽然采用 `HKDF-SHA256`，但输入是客户端随机生成的 **128-bit 高熵密钥**（28 位 Crockford Base32，而非用户自选密码），离线暴力破解空间达 $2^{128}$，计算上不可行。
- `authVerifier` 使用独立域分离的 `HKDF-SHA256` + `SHA-256`，即使恢复解锁时上传证明令牌，也无法反推出 `SMK` 或任何 scope 子密钥。
- 每个同步信封均通过 AES-256-GCM AAD 绑定 `(scope, itemKey, rev, keyEpoch, encoding)`，服务端无法篡改或跨范围替换密文。
- 已配对的远程中继隧道基于双方固定的 X25519 静态公钥运行 `Noise_IK`，服务端无法解密历史或实时流量。

### 你需要了解的主动攻击与信任边界

1. **添加新设备时务必核对两端验证码**：
   - **同步保险库设备审批**使用基于 `commit-then-reveal` 协议生成的 **8 位核对码（`XXXX-XXXX`，40-bit）**（见 [`PROTOCOL.md §4.1`](./packages/sarto-wire/PROTOCOL.md#41-approving-a-device)）。恶意服务端无法伪造匹配核对码（碰撞概率 $2^{-40} \approx 10^{-12}$），且新设备会拒绝任何未经用户确认审批者 MAC 认证的密钥封装。**但如果你在老 Mac 上不核对两端 8 位验证码就盲点「批准」**，主动中间人服务端可能诱骗老 Mac 将真实 `SMK` 加密给服务端自己的公钥。
   - **账号发现远程配对**使用绑定了 Noise `handshakeHash` 的 `commit-then-reveal` **6 位核对码**（连续失败 3 次触发 10 分钟冷却），同样请在两端核对一致后再确认。
2. **软件更新与供应链信任**：
   - 应用更新、daemon 安装脚本 `install.sh`、`sources.json` 与 `harnesses.json` 均由编译在开源客户端内的 **Ed25519 公钥**验签（[`tools/sarto/update-keys.json`](./tools/sarto/update-keys.json)），且 `Sarto.app` 替换前还会校验新包的 macOS **Apple 代码签名**是否与当前应用一致。
   - **仅攻破云服务器无法下发木马更新**；只有同时持有发布签名私钥与 Apple 开发者证书的发布方才能签发有效更新。对供应链有极致要求的用户可直接从本开源仓库自行编译。
3. **元数据可见性与新设备回滚**：
   - 恶意服务端仍能观察上述明文元数据（邮箱、设备名、IP、时间、密文大小），或实施拒绝服务、对**首次同步的新设备**返回某 scope 较旧的历史合法密文版本 `rev`（老设备会拒绝 `rev < currentRev` 的回滚），但始终无法解密或伪造密文内容。

---

## 四、独立验证与公开构建溯源

你无需轻信任何单方面声明。Sarto 客户端与 daemon 完全开源，官方版本通过 [GitHub Actions](./.github/workflows/release-mac.yml) 直接从公开 Commit 自动构建并签发 SLSA 构建溯源证明（Build Provenance Attestation），你可以独立验证**源码**与**手中安装包的一致性**：

1. **校验构建溯源证明**（验证下载的 `.dmg` / `.zip` / daemon 压缩包确由本公开仓库的 GitHub Runner 原样构建，未经本机篡改）：
   ```sh
   gh attestation verify Sarto-<version>-arm64.dmg --repo Rladmsrl/Sarto
   ```
2. **校验 SHA-256 摘要与 Apple 代码签名**：
   ```sh
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   codesign --verify --deep --strict --verbose=2 /Applications/Sarto.app
   ```
3. **随时用系统工具核查实时外连**（可选）：
   ```sh
   lsof -i -n -P | grep -E "Sarto|node"
   ```
   你也可以随时对照 [SECURITY.zh-CN.md](./SECURITY.zh-CN.md) 中列出的关键加密与网络源码文件自行审计，或交给任意大模型代码审阅。

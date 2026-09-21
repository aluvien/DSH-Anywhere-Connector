# DSH Anywhere 交接记录

更新时间：2026-09-14

## 目标

为本机 DeepSeek Harness 提供原生 iOS 远程客户端，并逐步演进为多人可用的产品：每个用户的 iPhone 只访问自己的 Mac/Harness，Mac 主动连接公共 Relay，服务端不需要访问用户的本地端口。

当前产品名称确定为 **DSH Anywhere Connector**。Connector 是用户安装的本地服务；DSH Cordis 插件是它内部的 Harness 适配层，不作为两个独立产品让用户理解。

## 已确认架构

```text
DeepSeek Harness
      ↕ Cordis adapter plugin
DSH Anywhere Connector（Mac 本地服务）
      ↕ 出站 WSS / Relay payload
公共 Relay（服务器）
      ↕ HTTPS/WSS
原生 iOS App
```

每个用户拥有自己的 machineId。Relay 根据机器凭证和设备凭证路由消息，不能按客户端自报的 machineId 授权。

## 已完成

### Relay 协议和服务

- `packages/protocol/src/index.ts`
  - 增加严格的 `relay.ready`、`relay.presence`、`relay.payload`、`relay.error` schema。
- `packages/relay-server/`
  - `POST /v1/machines/register`：bootstrap token 注册机器。
  - `POST /v1/pair`：机器 pairing secret 绑定 iOS 设备。
  - `WS /v1/connect`：机器/设备出站连接与同机路由。
  - registry JSON 原子写入；只保存 token/secret 的 SHA-256 hash。
  - 机器隔离、错误 token 拒绝、目标不可用错误、配对限速。

Relay 默认监听 `127.0.0.1:8787`，部署模板位于 `deploy/relay/`。服务器反代必须
支持 HTTPS 和 WebSocket Upgrade；公网域名不能继续直通某一台用户 Mac 的 3080。

### Connector 核心

- `packages/connector/`
  - Relay WSS 与本机 Bridge WebSocket 双连接。
  - 指数退避、ping/pong、短暂事件缓冲、错误脱敏。
  - 把 Relay 的 `CommandEnvelope` 映射到本机 bridge HTTP API。
  - 把本机事件的 machineId 改写为 Relay 注册的 machineId，避免跨 ID 校验失败。
- CLI：`start`、`status`、`setup`。
- `setup` 会注册机器，写入 0600 的 `connector.json` 和 `bridge.env`。
- `scripts/run-bridge.sh` 会自动读取 `bridge.env`，`scripts/run-connector.sh` 启动
  Connector；`scripts/install-macos-services.sh` 可生成两个用户级 launchd agent。

### DSH 插件鉴权

- `packages/dsh-anywhere-plugin/src/auth.ts`
- `packages/dsh-anywhere-plugin/src/index.ts`
  - 支持 `DSH_ANYWHERE_CONNECTOR_TOKEN` / `connectorToken`。
  - Connector token 至少 32 字符，作为重启后稳定 trusted device。
  - 原有六位码直连配对仍兼容。
  - `/pair` 默认按远端地址限制每分钟失败次数。

### Relay 部署模板

- `deploy/relay/Dockerfile`
- `deploy/relay/compose.yaml`
- `deploy/relay/nginx-location.conf`
- `deploy/relay/.env.example`
- `deploy/relay/README.md`

Relay 应部署在自己的服务器上。现在的 `dsh.biaozhu.me` 仍曾经反代到个人 Mac 的 3080；迁移时应改为反代服务器本机 Relay（默认 8787），不能把公共域名继续直通某个用户的 Harness。

### iOS 图标与构建

- `ios/DSHAnywhere/Assets.xcassets/AppIcon.appiconset/` 已加入 1024×1024 的 AppIcon，并在
  Xcode target 的 `ASSETCATALOG_COMPILER_APPICON_NAME` 中启用。
- 当前图标使用产品指定的“星空鲸鱼 + 地球”原图，源稿保存在
  `design/dsh-anywhere-whale-source.png`；`design/prepare-user-icon.swift` 负责将
  透明角压平为不透明的 1024×1024 AppIcon。
- 模拟器构建已通过；Release 真机 archive 已在无签名模式通过，临时产物位于
  `artifacts/ios/DSHAnywhere-0.0.1-whale-icon-unsigned.xcarchive`。
- 已补齐 App Store Connect 要求的界面方向声明：iPad 支持竖屏、倒置竖屏和左右横屏，
  iPhone 支持竖屏和倒置竖屏；这部分已合并到下方的最终 build 2 archive。
- 已声明 `ITSAppUsesNonExemptEncryption = NO`（本 App 使用系统 HTTPS/WSS，不包含自定义或
  非豁免加密实现）。包含该声明的最新无签名 archive 位于
  `artifacts/ios/DSHAnywhere-0.0.1-build2-export-compliance-fixed-unsigned.xcarchive`；
  工程的 `CURRENT_PROJECT_VERSION` 已提升到 3，作为本次工作台功能更新的上传版本。
- 本机当前 `security find-identity -v -p codesigning` 返回 0 个有效签名身份，因此还不能直接生成可安装 IPA 或上传 TestFlight/App Store；需要 Apple Developer
  证书/Provisioning Profile，并确认上传目标。

### 最近更新（build 39 / Mac r11）

- 新建会话增加 Harness 原生权限模式：`workspace-write`（工作区内修改）和
  `danger-full-access`（完全访问）；模式在创建请求中传到本机 Bridge，并执行 Harness
  `/permission` 保持真实沙箱状态一致。
- 首页空态等待第一份权威 `session.snapshot` 后再显示，并关闭会话列表刷新时的隐式行动画，
  解决首次连接和重连时的闪烁。
- 图片/文件选择现在只是 iOS 本地草稿，输入区会显示可删除标签；点击发送后才上传、等待文件
  receipt，再将 receipt 随 prompt 一起提交。上传失败会保留尚未完成的附件。
- 最新本机包：`artifacts/macos/DSH-ANYWHERE-MAC-LOCAL-20260913-r11.zip`，SHA-256：
  `d39a3ffe6b3ea4f28731269d695f337069c49c15762544bfd14a9945c1fb01c9`。
- Relay 也要更新到 `artifacts/server/DSH-ANYWHERE-RELAY-SERVER-20260913-r11-clean.zip`，
  因为 Relay 的严格协议 schema 需要认识 `session.create.permissionMode`；SHA-256：
  `bb1fa04f0894261ff163a01225d19d2dd5955c6f4e509c68a6e83752e8023a92`。
- 最新 iOS 无签名归档：`artifacts/ios/DSHAnywhere-0.0.1-build40-staged-attachments-unsigned.xcarchive`
  （压缩包同名 `.zip`，SHA-256：
  `fa5b658cb6c1a8e5d18bb1677d4d4e347bc336bb92025a2e36f5f212012e0465`）。

### Harness 工作台同步（2026-09-13）

- 会话列表现在按 Harness workspace / 工作目录分组；默认隐藏已归档会话，工具栏可显式显示，
  archive 操作会写入 Harness 的 workspace archive registry。
- Bridge/Connector/协议新增模型目录与本会话模型选择，iOS 从本机 Harness 的 model catalog
  读取真实可选项，不再硬编码模型名。
- iOS 输入区新增指令面板（`compact`、`export`、`feedback`、`goal`、`permission`、`plan`、
  `model`）、照片/文件上传、附件回执和停止生成。
- 用量区显示轮次、步骤、总 token、缓存命中、上下文窗口和从 Harness timed stream 推导的生成速率。
- 权限选择只展示 Harness 当前公开支持的两个原生 preset：`workspace-write` 与
  `danger-full-access`。切换会执行 Harness `/permission`，同步写入 sandbox mode 和 approval policy，
  不再只是改变手机端显示。
- Mac 升级包发布在 `artifacts/macos/`；选择日期相同的最大 `r` 版本即可。压缩包不包含 token。
- iOS Build 40 已写入 `ios/DSHAnywhere.xcodeproj/project.pbxproj`。上传前在已登录 Apple
  Developer 的 Xcode 中执行 Product → Archive，然后在 Organizer 中选择 Distribute App →
  TestFlight / App Store Connect。
- 验证：`pnpm build`、Plugin 32、Connector 13 项测试通过；iOS 模拟器测试 46 项全部通过，
  Release 真机无签名 archive 也已成功生成。

### 首页项目浏览与实时渲染（build 41）

- 首页改成轻量的项目/工作区浏览器：每个项目标题单独一行，左侧文件夹图标，右侧三点菜单和
  新建会话按钮；会话行只显示标题和运行状态点，权限、模型、路径等信息留在会话详情页。
- 项目菜单目前提供新建、展开/折叠、刷新、显示已归档和设置，避免出现看起来可点但没有行为的
  装饰按钮；新建会话仍可在弹窗内选择工作区和权限模式。
- 首页从系统 `List` 改为稳定的 `ScrollView`/`LazyVStack`，关闭快照重排动画；归档过滤仍由
  `groupedForList` 统一处理。
- `DSHAppModel` 将 WebSocket 事件按 50ms 窗口批量归并后一次发布状态，减少 SwiftUI 全局重绘；
  对话流式输出自动跟随也取消逐 token 动画，避免高频 Core Animation 导致闪烁、发热和卡顿。
- 本次 UI 更新需要上传 iOS build 41；无签名 archive/zip 为
  `artifacts/ios/DSHAnywhere-0.0.1-build41-home-ui-unsigned.xcarchive`（压缩包同名 `.zip`），
  ZIP SHA-256：`80bf0333e6b12397dc88b8b28799440f64d70978da5a6862c07e28bb6c1ad96f`。在有 Apple
  Developer 证书的 Xcode Organizer 中重新签名后再上传。

### 附件发送、黑屏保护与首页头部（build 42 / Mac r12）

- 图片/文件选择仍只保存在 iPhone 当前输入草稿；点发送后才上传。相册图片会先缩小到最长边
  2048px，再以 JPEG 压缩，减少大图经过 WSS/Relay/Connector 时的超时和内存压力；上传等待窗口
  与 Connector 的本地 Harness 上传截止时间分开，Connector 现在给 `attachment.upload` 120 秒。
- 带图片的 prompt 会把文字和 `file` receipt 一起放进 Harness 读取的 `content` 数组，修复“图片
  发送成功但文字丢失”。Connector/手机会消费按 requestId 关联的 `protocol.error`，上传失败会
  立即恢复文字和未完成附件，不再盲等到超时。
- 会话内容为空或正在重连时显示明确的占位提示，避免审批/问题状态下出现整页黑屏；流式事件仍按
  50ms 批处理，自动跟随不再逐 token 动画。
- 首页恢复为参考图 4 的项目卡片头部：文件夹、连接状态、三点菜单和新建会话按钮；会话行只显示
  标题并向右缩进，权限/模型继续放在会话页。
- 最新本机升级包：`artifacts/macos/DSH-ANYWHERE-MAC-LOCAL-20260914-r12.zip`，SHA-256：
  `a3c58d6a073464a5cab3657e151f839452cc9facf98bcfc6996ad58ad5b7623c`。
- 最新 iOS 无签名归档：`artifacts/ios/DSHAnywhere-0.0.1-build42-attachments-home-unsigned.xcarchive.zip`，
  SHA-256：`c28475a32e6052d904a69ce0608493af408ca60164dca099f6541181148f68e5`。在已登录 Apple
  Developer 的 Xcode Organizer 中重新签名后上传 TestFlight。

## 当前个人环境

- 本机 DSH Anywhere bridge 使用 `127.0.0.1:3080`。
- frpc 当前已有 `127.0.0.1:3080 → 服务器 40822`。
- 个人直连测试曾验证 `https://dsh.biaozhu.me/dsh-anywhere/v1/health` 返回 200，但这不是多人 Relay 架构。
- `scripts/run-bridge.sh` 默认端口已切到 3080。

### 2026-09-21 一条命令安装部署

- GitHub 源码提交：`dc007b0`。
- Relay 已在 `dsh.biaozhu.me` 启用 `/install` 和 `/v1/machines/enroll`，健康信息返回
  `publicEnrollment: true`；线上脚本通过 Shell 语法、凭证占位符替换和固定源码下载检查。
- 完整工作区 152 项测试、所有 TypeScript 类型检查和构建通过。Connector 覆盖环境传递安装
  凭证与终端二维码；Relay 覆盖单次消费、重复拒绝和来源限流。
- 服务器部署前备份：`/opt/dsh-backup-one-command-20260921-134010`；旧镜像标签
  `relay-relay:before-one-command-20260921-134010`。配对注册表与原 `.env` 均已保留。

### 2026-09-21 Linux / Windows 一条命令安装

- GitHub 主线与线上 Relay 使用功能提交 `4de225c`。生产入口 `/install`、`/install-linux`、
  `/install-windows` 均返回 200、禁止缓存、完成占位符替换并固定下载该提交；源码归档返回 200。
- Relay 增加 `/install-linux` 与 `/install-windows`，沿用短时、单次、同来源绑定的公开注册
  凭证；`/install` 继续专用于 macOS。
- Linux 安装器支持 x64/arm64，安装 systemd 用户服务并尝试为当前用户启用 linger；Windows
  安装器支持 x64/arm64，使用当前用户启动目录与隐藏监护进程，无需管理员权限。
- 三个平台都会准备独立 Node.js/DSH 运行环境、保留已有机器注册、启动 Bridge 与 Connector，
  随后显示一次性二维码并打开本机配对页。
- 完整工作区 153 项测试、类型检查、构建、生产 Docker 构建与 PowerShell AST 解析通过。
  最新生产备份位于 `/opt/dsh-backup-platform-installers-20260921-170010`，旧源码为
  `/opt/dsh-anywhere-before-platform-20260921-170010`，旧镜像标签为
  `relay-relay:before-platform-20260921-170010`。

## 当前私测的连接步骤

Mac 已支持免账号的一条命令安装：

```sh
curl -fsSL https://dsh.biaozhu.me/install | sh
```

Relay 为每次脚本下载签发短时、单次、来源限流的安装凭证；脚本自动准备私有 Node.js、pnpm
和 DSH 环境，注册 Mac、安装 launchd 服务并显示二维码。服务器只运行 Relay，不运行用户的
DSH Harness。

### 服务器

服务器上传包：`artifacts/server/DSH-ANYWHERE-RELAY-SERVER-20260912-clean.zip`（不含密钥、
`node_modules`、iOS 工程和 Mac Connector）。

1. 将项目复制到服务器，例如 `/opt/dsh-anywhere`，安装 Docker Engine、Compose v2、Nginx，
   并让 `dsh.biaozhu.me` 的 DNS 指向服务器。
2. 在服务器执行：

   ```sh
   cd /opt/dsh-anywhere/deploy/relay
   cp .env.example .env
   openssl rand -base64 48
   # 将输出写入 .env 的 DSH_RELAY_BOOTSTRAP_TOKEN，并 chmod 600 .env
   docker compose --env-file .env -f compose.yaml up -d --build
   ```

3. 在该域名的 HTTPS Nginx server block 中加入 `deploy/relay/nginx-location.conf`，
   将请求和 WebSocket Upgrade 反代到 `127.0.0.1:8787`，然后执行 `nginx -t && systemctl reload nginx`。
4. `curl https://dsh.biaozhu.me/health` 应返回包含 `"ok":true,"version":1` 的 JSON。
   8787 不应直接暴露公网；旧的 frpc → Mac:3080 反代应停用。
5. 之后每次上游协议新增事件或命令，都要重新执行 `docker compose ... up -d --build`
   并重启 Mac 侧 bridge/Connector。Relay 会校验转发消息的 body，镜像里的 protocol
   快照过期时会直接丢弃新类型。用 `/health` 的 `schemaRevision` 与
   `packages/relay-server/src/server.ts` 的 `RELAY_SCHEMA_REVISION` 比对确认。

### Mac

1. 安装/确认 DSH Harness、Node.js 22+、pnpm 11；在项目根目录执行 `pnpm install && pnpm build`。
2. 使用服务器 `.env` 中的 bootstrap token 注册一次：

   ```sh
   node packages/connector/lib/cli.js setup \
     --relay https://dsh.biaozhu.me \
     --bootstrap-token '<服务器 bootstrap token>' \
     --machine-name 'My Mac'
   ```

   命令会生成 `~/Library/Application Support/DSH Anywhere/connector.json` 和
   `bridge.env`，并打印 `machineId`、`pairingSecret`。后两者只交给对应的 iPhone 用户。
3. 首次调试开两个终端：

   ```sh
   ./scripts/run-bridge.sh
   ./scripts/run-connector.sh
   ```

   bridge 默认只监听 `127.0.0.1:3080`；Connector 通过出站 WSS 连接服务器，不需要开放 Mac 入站端口。
4. 稳定运行可执行 `./scripts/install-macos-services.sh`，安装并启动两个用户级 launchd 服务。
   用 `node packages/connector/lib/cli.js status` 检查本地 bridge。

### iPhone

在 App 的配对页填写：

- Server：`https://dsh.biaozhu.me`
- Machine ID：Mac `setup` 输出的 `machineId`
- Pairing secret：同一条输出中的 `pairingSecret`

配对成功后，iOS token 存入 Keychain，之后会通过 Relay `/v1/connect` 通信。iPhone 不需要
安装 Node、DSH、frpc 或 Tailscale。

## 验证命令

依赖安装（首次或 workspace 包变化后）：

```sh
pnpm install --config.confirmModulesPurge=false
```

代码检查与构建：

```sh
pnpm check
pnpm build
```

Relay 网络测试需要允许测试进程监听本机随机回环端口：

```sh
pnpm --filter @dsh-anywhere/relay-server test
```

Connector 单测：

```sh
pnpm --filter @dsh-anywhere/connector test
```

iOS 无签名构建：

```sh
xcodebuild \
  -project ios/DSHAnywhere.xcodeproj \
  -scheme DSHAnywhere \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dsh-anywhere-derived \
  CODE_SIGNING_ALLOWED=NO build
```

## 当前未完成

### P0：下一步必须完成

1. 为公开安装入口增加数据库级配额、封禁和审计；当前使用进程内来源限流，适合小规模使用。
2. 为 Mac 安装包增加开发者签名、公证和自动更新；当前脚本从固定 Git 提交下载并在本机构建。

### 已完成但仍需真实环境冒烟

- iOS 已从旧的直连 bridge/六位码切换为 Relay 地址、machineId、pairingSecret 配对。
- iOS WebSocket 已使用 `/v1/connect`、Bearer device token 和 Relay envelope；收到
  `relay.ready` 后发送 `connection.resume`，只把同机 machine payload 解包成事件。
- Connector 维护最多 2,000 条 Relay-side 事件窗口，按 `connection.resume.lastSequence`
  补发初始 snapshot；其余命令映射到本地 bridge HTTP API。
- 已有 Swift 11 项测试、Relay 5 项测试、Connector 7 项测试；仍需在一台真实 Mac
  上启动 DSH、Relay 和 iPhone 做一次完整配对/Prompt/审批冒烟。

### P1：公开测试前

- 用户账号、机器/设备所有权和 session ACL。
- PostgreSQL 持久化替代 JSON registry。
- 事件持久化、gap/resync、命令幂等和离线队列。
- 设备撤销、Token 轮换、审计日志。
- Relay 与 Connector 的应用层 E2EE；当前 Relay payload 仍是明文协议对象。
- APNs、后台提醒、多 Mac 切换。

### P2：产品发布

- macOS 图形安装器、签名、公证和自动更新。
- iOS TestFlight/App Store 发布。
- App 内完善首次扫码引导；二维码和深链协议已可用。
- Relay 水平扩展、Redis presence、监控、日志轮转和版本回滚。
- 自托管 Relay 文档与官方 Relay 的配置切换。

## TestFlight 自动上传

本机已配置 App Store Connect API Key（私钥不进仓库），发布脚本位于
`scripts/release-testflight.sh`。它会自动递增 Build Number、使用 Xcode 自动签名、导出 IPA
并上传到 TestFlight；默认读取
`/Users/aluvien/.appstoreconnect/private_keys/AuthKey_3HM6YT6KMS.p8`。

执行：

```sh
./scripts/release-testflight.sh
```

也可以显式指定构建号：

```sh
./scripts/release-testflight.sh 42
```

如更换团队或密钥，可通过 `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_PATH` 覆盖默认值。脚本只负责
归档和上传构建版本；TestFlight 外部测试审核和正式 App Store 审核仍需在 App Store Connect
中确认。

## 安全边界

- 当前公开安装入口适合小规模免账号使用；在数据库配额、封禁和审计完成前，不适合作为无限制公共服务。
- API key 和 Harness 凭证必须留在 Mac；Relay 不应接收 provider secret。
- 公网必须强制 HTTPS/WSS；明文 HTTP 只允许 localhost 开发。
- 六位配对码不是公开产品级身份认证；必须有速率限制、失败审计和更强的一次性配对凭证。
- Relay 路由必须以服务端 token registry 为准，不能信任客户端传来的 machineId/deviceId。

## 接手者第一步

先运行：

```sh
pnpm check
pnpm build
```

然后优先阅读：

1. `packages/protocol/src/index.ts`
2. `packages/relay-server/src/server.ts`
3. `packages/connector/src/connector.ts`
4. `packages/connector/src/setup.ts`
5. `packages/dsh-anywhere-plugin/src/index.ts`
6. `ios/DSHAnywhere/App/DSHAppTransport.swift`
7. `scripts/run-bridge.sh` 与 `scripts/run-connector.sh`

接着用一个本地 Relay 实例完成“机器 Connector ↔ Relay ↔ iOS mock/device”的端到端
测试，再把服务器域名切到 Relay。不要在未完成迁移前把公共域名直通某个用户的 3080。

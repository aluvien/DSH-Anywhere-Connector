# DSH Anywhere

面向 DeepSeek Harness 的原生 iOS 远程客户端。公网只运行 Relay；每台 Mac 安装
`DSH Anywhere Connector`，Connector 主动向 Relay 建立 WSS，再把本机 Harness
桥接给已经配对的 iPhone。用户不需要安装 Tailscale 或 frpc，也不需要把 Mac
端口暴露到公网。

```text
iPhone（SwiftUI） ← HTTPS/WSS → 自有服务器 Relay ← WSS（出站） ← Mac Connector
                                                               ↕ localhost
                                                        DSH Harness + Cordis plugin
```

## 当前状态

这是可运行的私测 vertical slice：Relay、Connector、Cordis 适配插件和原生 iOS
Relay transport 已实现并有自动化测试。服务器的 JSON registry、手工安装流程和
pairing secret 仍适合个人/受控测试，不是公开 SaaS 的最终账号系统。

## 1. 在自己的服务器运行 Relay

服务器要求 Node.js 22+ 或 Docker，以及一个 HTTPS 域名。Relay 默认监听本机
`127.0.0.1:8787`，由 Nginx/Caddy 反向代理；代理必须支持 WebSocket Upgrade。

```sh
cp deploy/relay/.env.example deploy/relay/.env
# 编辑 .env，设置至少 32 字节的 DSH_RELAY_BOOTSTRAP_TOKEN
docker compose --env-file deploy/relay/.env \
  -f deploy/relay/compose.yaml up -d --build
```

然后把 `deploy/relay/nginx-location.conf` 合并进 HTTPS server block，并确认：

```sh
curl https://your-relay.example/health
```

应返回 `{"ok":true,...}`。当前的 `dsh.biaozhu.me` 如果仍反代到个人 Mac 的
3080，不能直接用于多人 Relay；必须改为反代服务器本机的 Relay 8787。

## 2. 在 Mac 注册 Connector

在本项目根目录构建，然后只由管理员执行一次 setup。bootstrap token 不要交给
终端用户：

```sh
pnpm install
pnpm build
node packages/connector/lib/cli.js setup \
  --relay https://your-relay.example \
  --bootstrap-token '<server bootstrap token>' \
  --machine-name 'My Mac'
```

命令会在 macOS 默认目录写入权限为 0600 的 `connector.json` 和 `bridge.env`，并
打印本机的 `machineId`、`pairingSecret`，以及一条 `pairingLink`。pairing secret
只应通过安全渠道交给该 Mac 的 iPhone 用户；不要提交到 Git 或粘贴到公共聊天。

setup 现在也把 `pairingSecret` 写进 `connector.json`（同样是 0600），这样本地
bridge 可以把它渲染成二维码，不必再手工转抄一次。

当前私测启动需要两个进程：

```sh
# 终端 1：启动本地 Harness bridge；脚本会自动读取 setup 写入的 bridge.env
./scripts/run-bridge.sh

# 终端 2：启动 Connector（只建立出站连接）
./scripts/run-connector.sh
```

bridge 启动后，在 **Mac 本机**打开下面这个地址即可看到配对二维码，用 iPhone
扫描就不用再手输 machineId 和 pairing secret：

```text
http://127.0.0.1:3080/dsh-anywhere/v1/pairing
```

该页面只在回环地址提供服务，并且会校验 Host 头，因此即使这台 Mac 的 3080 端口
被反向代理暴露到公网，这个页面也不会随之对外可访问。

macOS 用户服务也可以由安装脚本生成（会加载两个用户级 launchd agent，并自动重启
进程）：

```sh
./scripts/install-macos-services.sh
```

卸载这两个 agent：

```sh
./scripts/install-macos-services.sh --uninstall
```

也可以显式指定自定义配置：

```sh
DSH_ANYWHERE_CONFIG=/path/to/connector.json ./scripts/run-bridge.sh
DSH_ANYWHERE_CONFIG=/path/to/connector.json ./scripts/run-connector.sh
```

用户不需要配置 frpc/Tailscale；Mac 只需要能访问 Relay 的 HTTPS/WSS 域名。

## 3. 在原生 iOS App 配对

用 Xcode 打开 [`ios/DSHAnywhere.xcodeproj`](ios/DSHAnywhere.xcodeproj)，在
Signing & Capabilities 选择自己的 Team 和 Bundle ID，运行到 iPhone。配对页点
**Scan pairing code** 扫上面那个网页的二维码即可，也可以手工填写：

- Relay HTTPS 地址，例如 `https://your-relay.example`
- Connector 输出的 `machineId`
- Connector 输出的 `pairingSecret`

扫码只接受 `dshanywhere://pair` 链接（由 `packages/protocol` 的 `pairingLink`
生成）。扫到别的二维码会提示并继续扫描，不会填入半截凭证；相机权限只用于这一步。

App 通过 `POST /v1/pair` 换取设备令牌，并把令牌放进 iOS Keychain。之后 iOS
通过 `/v1/connect` 的 Relay WebSocket 收发会话、Prompt、工具状态和审批操作。

首页默认只显示未存档会话，网页端存档过的会话不会出现在列表里；需要查看时用
右上角菜单里的 **Show archived** 打开。

## 代码结构

```text
packages/protocol/              TypeScript/Zod 严格 wire protocol
packages/relay-server/          公网 Relay、注册、配对、同机路由
packages/connector/             Mac Connector CLI 与双 WebSocket 转发
packages/dsh-anywhere-plugin/   DeepSeek Harness / Cordis 本地适配层
ios/DSHAnywhere/Core/           Swift 协议、HTTP、Relay WebSocket、Keychain
ios/DSHAnywhere/Features/       SwiftUI 配对、会话、对话、审批界面
deploy/relay/                   Docker Compose 与反向代理模板
docs/HANDOFF.md                 当前实现、边界和后续任务
```

## 验证

```sh
pnpm check
pnpm build

cd ios
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/dsh-spm-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/dsh-clang-module-cache \
swift test --disable-sandbox --scratch-path /tmp/dsh-anywhere-swift-build
```

无签名构建 iOS App：

```sh
xcodebuild \
  -project ios/DSHAnywhere.xcodeproj \
  -scheme DSHAnywhere \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dsh-anywhere-derived \
  CODE_SIGNING_ALLOWED=NO build
```

## 目前的边界

- launchd 安装脚本适合源码私测；还没有签名安装器和自动更新机制。
- Relay 的 JSON registry 尚未接 PostgreSQL、账号、设备撤销和多租户 ACL。
- pairing secret 目前可重复使用，公开发布前必须改为一次性/可轮换凭证。
- Relay payload 目前是协议对象，不是应用层 E2EE；Relay 只应部署在自己信任的服务器。
- APNs、后台通知、附件、二维码/深链配对和 App Store/TestFlight 发布尚未完成。

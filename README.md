# DSH Anywhere

DSH Anywhere 让你通过 iPhone 远程使用 Mac 上运行的
[DeepSeek Harness](https://github.com/deepseek-ai)。Mac 主动连接自托管 Relay，不需要公网
IP、端口映射或对外开放 Harness 端口。

> [!IMPORTANT]
> **当前正式支持的移动客户端只有 iOS。** `android/` 是尚未完成的实验性原型，开发已经
> 暂停。Android **不纳入当前代码审计、安全审计、功能验收和发布范围**，也不提供可用性、
> 兼容性或安全性承诺。目录暂时保留，仅供以后恢复开发时参考；恢复前必须重新审计和测试。
> 本文下文中的“手机客户端”均指 iOS。

## 当前状态

| 部分 | 状态 | 说明 |
|---|---|---|
| iOS App | 主线开发 | 当前唯一受支持的移动客户端，部署目标为 iOS 17+ |
| Mac Connector / Bridge | 主线开发 | 连接 Relay，并把手机请求转交给本机 Harness |
| Relay | 主线开发 | 自托管的设备鉴权与消息转发服务 |
| Android App | **暂停开发** | 半成品，不属于当前审计、验收或发布对象 |

项目目前适合个人使用和受控测试，尚未按多租户公共服务的标准完成账号体系、持久化存储、
端到端加密和大规模运维能力。

## 工作方式

```text
iPhone ── HTTPS/WSS ──▶ Relay（你的服务器） ◀── WSS 出站 ── Mac Connector
                                                               │
                                                               ▼
                                                    Bridge / Harness :3080
```

| 组件 | 运行位置 | 职责 |
|---|---|---|
| iOS App | iPhone | 浏览会话、发送消息、上传附件、处理提问与审批 |
| Relay | 自托管服务器 | 注册机器、配对设备、验证凭据并转发消息 |
| Connector | Mac | 主动建立到 Relay 的出站连接并转发请求与事件 |
| Bridge | Mac | 运行 DSH Anywhere 插件，将 Harness 能力暴露给本机 Connector |

Relay 是受信任组件。HTTPS/WSS 只保护链路，当前协议**不是端到端加密**；Relay 在转发时
能够读取和校验明文业务消息。Relay 不主动持久化会话正文，但 Relay 主机及其管理员仍然属于
信任边界。

## 快速开始

### 1. 部署 Relay

需要一台带域名和有效 TLS 证书的 Linux 服务器，并安装 Docker 与 Compose 插件。

```sh
git clone https://github.com/aluvien/DSH-Anywhere-Connector.git DSH-ANYWHERE
cd DSH-ANYWHERE/deploy/relay
cp .env.example .env
printf 'DSH_RELAY_BOOTSTRAP_TOKEN=%s\n' "$(openssl rand -base64 48)" > .env
chmod 600 .env
docker compose --env-file .env -f compose.yaml up -d --build
```

Relay 容器默认只监听 `127.0.0.1:8787`，必须通过支持 WebSocket Upgrade 的 HTTPS 反向
代理对外提供服务。Nginx 配置模板和完整说明见
[`deploy/relay/README.md`](deploy/relay/README.md)。

如果反向代理传递 `X-Forwarded-For`，请把代理连接 Relay 时使用的精确源地址写入
`DSH_RELAY_TRUSTED_PROXIES`。未列入信任名单的客户端所提供的转发头会被忽略，防止其绕过
配对限流。

部署后验证：

```sh
curl -s https://你的域名/health
```

响应中的 `ok` 应为 `true`。`schemaRevision` 代表 Relay 支持的转发消息结构；修改共享协议
后必须同步部署 Relay。

### 2. 一条命令安装 Mac 服务

已启用公开安装入口的 Relay 上，Mac 用户只需执行：

```sh
curl -fsSL https://你的域名/install | sh
```

脚本会在 `~/Library/Application Support/DSH Anywhere` 内准备私有的 Node.js、pnpm 和
DeepSeek Harness 运行环境，下载并构建 DSH Anywhere，使用本次下载专属的短时单次凭证注册
Mac，安装两个 launchd 服务，最后在终端显示二维码并打开本机配对页。用户不需要账号、
bootstrap token、Git、Homebrew 或手动填写 Relay 地址。同一台 Mac 再次运行会保留原注册并
更新本机程序。

Relay 的 `/install` 每次只签发一个随机安装凭证；凭证不写入磁盘、不能重复使用，并受来源
限流。管理员的 bootstrap token 不会进入脚本或用户机器。

仅在维护或私有部署中需要手工安装。建议将仓库放在 `~/DSH-ANYWHERE` 等普通开发目录，
不要放在 `~/Documents`。首次手工注册并安装：

```sh
cd ~/DSH-ANYWHERE
export DSH_ANYWHERE_RELAY_URL='https://你的域名'
export DSH_ANYWHERE_BOOTSTRAP_TOKEN='Relay 的 bootstrap token'
export DSH_ANYWHERE_MACHINE_NAME='My Mac'
./scripts/install-macos-bundle.sh
```

安装脚本会：

1. 构建 TypeScript 工作区；
2. 向 Relay 注册 Mac；
3. 将 Connector 配置保存到 `~/Library/Application Support/DSH Anywhere/connector.json`；
4. 安装并启动 `com.dsh-anywhere.connector` 与 `com.dsh-anywhere.bridge` 两个用户级服务。

bootstrap token 只用于手工注册 Mac，不会写入 launchd 配置。不要把它放进 App、仓库或公开日志。

已经注册过的 Mac 不要重复注册：

```sh
git pull
pnpm install
pnpm build
./scripts/install-macos-services.sh
```

### 3. 配对 iPhone

推荐生成一次性配对码：

```sh
node packages/connector/lib/cli.js pair
```

配对码十分钟内有效且只能使用一次。在 iOS App 的配对页输入输出中的 Relay 地址、
`machineId` 和 `pairingCode`。

一键安装会自动显示二维码并打开本机配对页。以后也可以手动打开：

```text
http://127.0.0.1:3080/dsh-anywhere/v1/pairing
```

配对页只允许从本机访问。不要将它反向代理到公网，也不要公开页面中的长期配对密钥。

### 4. 构建 iOS App

使用 Xcode 打开：

```sh
open ios/DSHAnywhere.xcodeproj
```

选择自己的签名 Team 后安装到 iPhone。扫码需要真机；模拟器请使用手动输入方式。

## iOS 当前能力

- 多台 Mac 的配对、切换和设备撤销
- 按工作区组织会话，新建、打开、重命名、归档会话
- Markdown、代码块、表格、工具调用和流式内容展示
- 提问卡片与审批处理
- 权限和模型选择
- 图片及文件上传
- 简体中文、English 和跟随系统语言

功能仍在迭代，不应把当前版本视为已完成的公开发行产品。

## 运维

检查 Mac 服务：

```sh
launchctl list | grep dsh-anywhere
curl -s http://127.0.0.1:3080/dsh-anywhere/v1/health
node packages/connector/lib/cli.js status
```

查看日志：

```sh
tail -f ~/Library/Logs/DSH\ Anywhere/connector.log
tail -f ~/Library/Logs/DSH\ Anywhere/bridge.log
```

修改 Connector、Bridge 或共享协议后，先构建再重启服务：

```sh
pnpm build
launchctl kickstart -k gui/$(id -u)/com.dsh-anywhere.connector
launchctl kickstart -k gui/$(id -u)/com.dsh-anywhere.bridge
```

launchd 服务设置了 `DSH_ANYWHERE_SKIP_BUILD=1`，因此重启不会自动重新构建。重启 Bridge
会中断当前连接，但不会删除 Harness 已持久化的会话。

升级 Relay 时保留 `deploy/relay/.env` 和 Docker 卷 `relay-data`，然后重新构建容器。机器注册
和已配对设备存放在该卷内，正常的 `docker compose up -d --build` 不需要重新配对。

## 开发与验证

安装依赖并验证 TypeScript 工作区：

```sh
pnpm install
pnpm build
pnpm check
```

`pnpm check` 覆盖协议、Relay、Connector 和 Bridge 插件的类型检查与测试。

iOS 无签名构建检查：

```sh
xcodebuild build-for-testing \
  -project ios/DSHAnywhere.xcodeproj \
  -scheme DSHAnywhere \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Android 不属于当前产品验收基线。不要因为 `android/` 中存在工程、自动化检查、构建脚本或
历史文档，就推定它已经通过审计或能够正常使用；这些遗留设施也不构成支持承诺。

## 代码结构

```text
packages/
  protocol/             共享消息类型与 Zod 校验
  relay-server/         机器注册、设备配对、鉴权和消息转发
  connector/            Mac 出站连接、命令转发和 CLI
  dsh-anywhere-plugin/  Harness Bridge、会话 API、事件和本机配对页
ios/DSHAnywhere/        当前受支持的 iOS 客户端
android/                已暂停的 Android 半成品，不属于当前审计与发布范围
deploy/relay/           Docker Compose、Dockerfile 和 Nginx 配置
scripts/                Mac 安装、启动、同步和发布辅助脚本
```

`RELAY_SCHEMA_REVISION` 定义在
`packages/relay-server/src/server.ts`。如果修改 `packages/protocol` 中通过 Relay 转发的消息
结构，必须同步提升 revision 并重新部署 Relay，否则版本不匹配的消息会被拒绝。

## 安全边界

- Relay 能看到转发中的明文消息；当前没有端到端加密。
- Relay 持久化机器与设备注册信息，不主动持久化会话正文。
- Mac Connector 和 Bridge 能代表用户操作本机 Harness，应只运行在用户控制的机器上。
- 凭据配置应保持 `0600` 权限，日志必须经过敏感信息脱敏。
- 一次性配对码绑定指定机器，十分钟过期且消费后失效；长期配对密钥仍应视为高敏感凭据。
- 配对页面只能从 loopback 访问，不能暴露到公网。
- Relay 当前使用单文件 JSON 注册表，适合个人或小规模受控使用，不适合作为公共多租户服务。
- Android 未接受当前安全审计，不能用于生产环境或处理敏感数据。

## 已知限制

- Relay 属于信任边界，不具备零知识或端到端加密属性。
- 账号、组织、权限分层和公共多租户隔离尚未完成。
- Bridge 的请求幂等保护主要覆盖同一运行进程内的重复投递；进程在副作用完成后、响应持久化前
  崩溃时，结果仍可能处于未知状态。
- `dshanywhere://` URL Scheme 尚未作为通用系统深链路开放；请在 App 内扫码或手动配对。
- Android 开发已暂停，不维护与 iOS 的功能一致性。

## Android 恢复开发的前提

如果未来重新启动 Android 开发，至少需要先完成以下工作：

1. 重新确认产品范围和与 iOS 的协议兼容目标；
2. 对 `android/` 进行独立的代码、安全和隐私审计；
3. 补齐单元测试、集成测试、真机测试和网络异常测试；
4. 重新接入正式发布门禁；
5. 审计通过后，再修改本 README 中的支持状态。

在这些条件完成之前，Android 始终视为冻结的实验代码。

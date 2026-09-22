# DSH Anywhere

[简体中文](README.md) | [English](README.en.md)

DSH Anywhere 让你通过 iPhone 或 Android 手机远程使用 macOS、Linux 或 Windows 电脑上运行的
[DeepSeek Harness](https://github.com/deepseek-ai)。电脑主动连接自托管 Relay，不需要公网
IP、端口映射，也不需要向公网开放 Harness 端口。

> [!IMPORTANT]
> iOS 17+ 是当前稳定客户端。Android 原生客户端已恢复开发并进入功能对齐预览阶段，适合
> 本地构建与受控测试；正式发布前仍需完成独立安全审计与真机兼容验收。

## 支持状态

| 组件 | 状态 | 说明 |
|---|---|---|
| iOS App | 主线开发 | 当前稳定移动客户端 |
| macOS Connector / Bridge | 主线开发 | launchd 用户服务 |
| Linux Connector / Bridge | 主线开发 | x64/arm64，systemd 用户服务 |
| Windows Connector / Bridge | 主线开发 | Windows 10/11，当前用户启动项 |
| Relay | 主线开发 | 自托管的鉴权和消息转发服务 |
| Android App | 主线开发预览 | Kotlin + Jetpack Compose，正在与 iOS 对齐 |

项目目前适合个人使用和受控测试。账号体系、组织权限、公共多租户隔离、端到端加密和大规模
运维能力仍未完成。

## 工作方式

```text
手机 ───── HTTPS/WSS ──▶ Relay（你的服务器） ◀── WSS 出站 ── Connector
                                                               │
                                                               ▼
                                                    Bridge / Harness :3080
```

| 组件 | 运行位置 | 职责 |
|---|---|---|
| iOS / Android App | 手机 | 浏览会话、发送消息和附件、处理提问与审批 |
| Relay | 自托管服务器 | 注册机器、配对设备、验证凭据并转发消息 |
| Connector | macOS / Linux / Windows | 主动连接 Relay，转发请求和实时事件 |
| Bridge | macOS / Linux / Windows | 将本机 Harness 能力提供给 Connector |

Relay 属于信任边界。HTTPS/WSS 保护传输链路，但当前协议不是端到端加密；Relay 在转发时能够
读取和校验业务消息。Relay 不主动持久化会话正文。

## 一条命令安装

使用项目当前公开 Relay 时，选择电脑对应的系统执行一条命令。

### macOS

```sh
curl -fsSL https://dsh.biaozhu.me/install | sh
```

### Linux

支持 x64、arm64 和 systemd：

```sh
curl -fsSL https://dsh.biaozhu.me/install-linux | sh
```

### Windows

在 Windows 10/11 PowerShell 中执行：

```powershell
irm https://dsh.biaozhu.me/install-windows | iex
```

安装器会自动：

1. 为当前用户准备独立的 Node.js、pnpm 和 DeepSeek Harness 环境；
2. 下载并构建固定 Git 提交的 DSH Anywhere 源码；
3. 使用短时、单次、来源绑定的安装凭证注册当前电脑；
4. 安装并启动 Bridge 与 Connector 后台进程；
5. 在终端显示一次性二维码，并打开本机配对页面。

用户不需要注册账号，也不需要安装 Git、Homebrew 或手工输入 Relay 地址。重复执行安装命令会
保留现有机器身份并更新程序。macOS 使用 launchd，Linux 使用 systemd 用户服务，Windows
使用当前用户启动项和隐藏的自动重启监护进程。

安装脚本源码均保存在 [`scripts/`](scripts/) 中。Relay 会在下载时注入随机的一次性安装凭证；
该凭证不会静态保存到 GitHub、安装脚本或用户配置中，管理员 bootstrap token 也不会下发到
用户电脑。

## 配对手机

一键安装完成后，使用 iOS 或 Android App 扫描终端或浏览器中的二维码。配对码十分钟内有效，只能使用
一次。以后需要配对其他手机时，再次执行当前系统的一键安装命令即可；安装器会保留原有
机器身份，并生成新的二维码。

本机配对页地址：

```text
http://127.0.0.1:3080/dsh-anywhere/v1/pairing
```

配对页面只允许从 loopback 访问，不要将它反向代理到公网。

## 自托管 Relay

需要一台具有域名和有效 TLS 证书的 Linux 服务器，并安装 Docker Engine 与 Compose 插件。

```sh
git clone https://github.com/aluvien/DSH-Anywhere-Connector.git DSH-ANYWHERE
cd DSH-ANYWHERE/deploy/relay
cp .env.example .env
openssl rand -base64 48
```

编辑 `.env`，至少填写：

```dotenv
DSH_RELAY_BOOTSTRAP_TOKEN=上一步生成的随机值
DSH_RELAY_PUBLIC_URL=https://你的域名
DSH_RELAY_INSTALL_SOURCE_URL=https://github.com/aluvien/DSH-Anywhere-Connector/archive/你的固定提交.tar.gz
```

固定提交可以避免安装器自动下载未经审核的分支更新。然后启动 Relay：

```sh
chmod 600 .env
docker compose --env-file .env -f compose.yaml up -d --build
```

容器默认只监听 `127.0.0.1:8787`。必须通过支持 WebSocket Upgrade 的 HTTPS 反向代理对外
提供服务。Nginx 模板和完整说明见
[`deploy/relay/README.md`](deploy/relay/README.md)。

反向代理传递 `X-Forwarded-For` 时，请将代理连接 Relay 使用的精确源地址写入
`DSH_RELAY_TRUSTED_PROXIES`。Relay 会忽略其他来源提供的转发头，防止客户端伪造地址绕过
配对和安装限流。

部署后检查：

```sh
curl -s https://你的域名/health
```

响应中的 `ok` 和 `publicEnrollment` 应为 `true`。

## 构建 iOS App

```sh
open ios/DSHAnywhere.xcodeproj
```

在 Xcode 中选择自己的 Apple Developer Team 后安装到 iPhone。扫码需要真机；模拟器可以
使用手工配对。

## 构建 Android App

```sh
cd android
./build.sh :app:testDebugUnitTest :app:assembleDebug
```

调试 APK 位于 `android/app/build/outputs/apk/debug/app-debug.apk`。Android 版使用与 iOS
相同的 Relay、配对凭据和远端会话协议，界面与交互以当前 Remote 风格为准。详细的模拟器、
本地测试床和安装说明见 [`android/README.md`](android/README.md)。

## 当前能力

- 管理、切换和撤销多台电脑与多部手机
- 按工作区组织会话，新建、打开、重命名和归档会话
- Markdown、代码块、表格、工具调用和流式输出
- 提问卡片、审批处理、权限模式和模型选择
- 图片与文件附件
- 简体中文、English 和跟随系统语言
- 远端数据优先，本地缓存用于加速启动与恢复

## 运行与日志

### macOS

```sh
launchctl list | grep dsh-anywhere
curl -s http://127.0.0.1:3080/dsh-anywhere/v1/health
tail -f ~/Library/Logs/DSH\ Anywhere/connector.log
tail -f ~/Library/Logs/DSH\ Anywhere/bridge.log
```

### Linux

```sh
systemctl --user status dsh-anywhere-bridge dsh-anywhere-connector
journalctl --user -u dsh-anywhere-bridge -u dsh-anywhere-connector -f
curl -s http://127.0.0.1:3080/dsh-anywhere/v1/health
```

安装器会尝试为当前 Linux 用户启用 systemd linger。如果主机策略禁止普通用户启用 linger，
服务仍会在该用户登录期间运行，并在以后登录时自动启动。

### Windows

```powershell
Get-Content "$env:LOCALAPPDATA\DSH Anywhere\logs\connector.log" -Wait
Get-Content "$env:LOCALAPPDATA\DSH Anywhere\logs\bridge.log" -Wait
Invoke-WebRequest http://127.0.0.1:3080/dsh-anywhere/v1/health
```

升级 Relay 时必须保留 `deploy/relay/.env` 和 Docker 卷 `relay-data`。机器注册和设备凭据保存在
该卷中，正常执行 `docker compose up -d --build` 不需要重新配对。

## 开发与验证

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

## 代码结构

```text
packages/
  protocol/             共享消息类型与 Zod 校验
  relay-server/         机器注册、设备配对、鉴权和消息转发
  connector/            跨平台出站连接、命令转发和 CLI
  dsh-anywhere-plugin/  Harness Bridge、会话 API、事件和本机配对页
ios/DSHAnywhere/        稳定的 iOS 客户端
android/                正在与 iOS 对齐的原生 Android 客户端
deploy/relay/           Docker Compose、Dockerfile 和 Nginx 配置
scripts/                各平台安装器、后台服务和发布辅助脚本
```

`RELAY_SCHEMA_REVISION` 定义在 `packages/relay-server/src/server.ts`。修改通过 Relay 转发的共享
消息结构时，必须同步提升 revision 并重新部署 Relay。

## 安全边界与已知限制

- Relay 能读取转发中的明文消息；当前没有端到端加密。
- Relay 持久化机器与设备注册信息，不主动持久化会话正文。
- Connector 和 Bridge 能代表用户操作本机 Harness，只应运行在用户控制的电脑上。
- 一次性安装凭证与配对码受有效期、单次消费、来源绑定和限流保护。
- 本机凭据文件应保持仅当前用户可读，本机配对页面不能暴露到公网。
- 当前单文件 JSON 注册表适合个人或小规模受控使用，不适合公共多租户服务。
- 账号、组织、权限分层和公共多租户隔离尚未完成。
- Linux 需要 systemd；Windows 后台进程在当前用户登录后启动。
- `dshanywhere://` 尚未作为通用系统深链路开放。
- Android 尚未完成独立安全与隐私审计，当前仅用于开发和受控测试。

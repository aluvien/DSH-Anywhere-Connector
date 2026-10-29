# DSH Anywhere

**把 DeepSeek Harness 会话带到 iPhone 上。** 在手机上查看电脑会话、发送任务、跟进实时回复，并处理提问和审批。

[简体中文](README.md) · [English](README.en.md) · [项目介绍页（GitHub Pages 发布后访问）](https://aluvien.github.io/DSH-ANYWHERE-Connector/) · [加入 iOS TestFlight 测试](https://testflight.apple.com/join/cnkGqHtp)

DSH Anywhere 由 iOS App、电脑端 Connector 和 Relay 组成。电脑通过加密连接主动连到 Relay，因此无需为 Harness 暴露公网端口或配置端口转发。iOS 17+ 是当前移动客户端；Android 开发及公开下载已暂停。

## iOS 软件界面

| 会话列表 | 对话与用量统计示例 | 添加电脑并配对 |
| --- | --- | --- |
| ![iOS 会话列表截图](site/assets/ios-home.png) | ![iOS 对话与底部用量统计示例](site/assets/ios-conversation.png) | ![iOS 配对界面截图](site/assets/ios-pairing.png) |

## 快速开始

### 1. 安装 iOS App

在 iPhone 上打开 [TestFlight 测试加入地址](https://testflight.apple.com/join/cnkGqHtp)，加入测试并安装 DSH Anywhere。

### 2. 在电脑上安装 Connector

选择运行 DeepSeek Harness 的电脑系统，在终端执行对应命令。安装器会配置电脑端运行环境、注册电脑，并启动 Bridge 与 Connector。

macOS 安装器会自动识别你正在使用的 Harness：已初始化的 Harness 桌面客户端会走客户端 Bridge；其他情况会使用终端中的 `dsh` CLI。无需手动选择。若两者都安装，默认优先桌面客户端。

**macOS**

```sh
curl -fsSL https://dsh.biaozhu.me/install | sh
```

**Linux（x64 / arm64）**

```sh
curl -fsSL https://dsh.biaozhu.me/install-linux | sh
```

**Windows 10/11 PowerShell**

```powershell
irm https://dsh.biaozhu.me/install-windows | iex
```

安装结束后，终端会显示一次性配对二维码，也会打开电脑本机的配对页面。

不小心关闭二维码或配对页时，重新执行同一条安装命令即可。已有电脑身份和已配对的 iPhone 会保留，安装器只会生成新的、十分钟内有效的一次性二维码。

### 3. 扫码连接

打开 iPhone 上的 DSH Anywhere，选择扫描配对码并扫描电脑上的二维码。配对码 10 分钟后过期，且只能使用一次。若要添加另一台电脑，重新运行该电脑的安装命令即可。

### 4. 开始使用

- 在首页选择电脑和工作区，打开现有会话，或新建会话。
- 在底部输入任务并发送；可附上图片或文件，并查看实时回复和工具活动。
- 按提示回答 Harness 提问，或确认需要审批的操作。思考过程默认收起，可按需展开。
- 查看计划、目标、任务清单、子任务、工作流与执行轨迹；通过搜索和历史分页阅读较早的完整记录。
- 在电脑端配置页读取模型服务与插件信息，编辑原生配置、管理凭据引用，并从服务发现模型。保存冲突时保留手机草稿，核对电脑最新版本后再合并。
- 在设置中切换电脑、管理已配对设备、调整语言和界面选项。

## 工作方式

```text
iPhone App ── HTTPS / WSS ──▶ Relay ◀── 主动建立 WSS 连接 ── Connector
                                                               │
                                                               ▼
                                                       Bridge / Harness
```

| 组件 | 运行位置 | 作用 |
| --- | --- | --- |
| iOS App | iPhone | 浏览和管理会话，发送消息与附件，处理提问和审批 |
| Relay | 项目公开服务或自托管服务器 | 配对设备、验证凭据并转发消息 |
| Connector / Bridge | macOS、Linux 或 Windows 电脑 | 连接 Relay，并把请求转交给本机 Harness |

## 功能

- 管理多台电脑和多个已配对手机
- 按工作区整理会话，创建、打开、重命名和归档会话
- 查看 Markdown、代码块、表格、工具调用和流式输出
- 处理提问、审批、权限模式和模型选择
- 发送图片和文件附件
- 支持简体中文、English 和跟随系统语言

## 安全与适用范围

项目目前适合个人使用和受控测试。HTTPS/WSS 保护传输链路，但协议尚未提供端到端加密；Relay 属于信任边界，转发时能够读取业务消息。Relay 不主动持久化会话正文。账号体系、组织权限和公共多租户隔离仍未完成。只应将 Connector 安装在自己控制的电脑上。

## 自托管 Relay

需要自己管理 Relay 时，从 [`deploy/relay/README.md`](deploy/relay/README.md) 开始。配置自托管 Relay 需要 Linux 服务器、域名、TLS 证书、Docker Engine 和 Docker Compose。

## 升级与版本要求

本次 Harness 信息展示功能要求 Relay 的 `/health` 返回 `schemaRevision` 至少为 **11**。协议主版本仍是 1，但主版本相同不代表旧 Relay 能识别新增字段。

升级顺序：

1. 自托管用户先更新 Relay，并检查 `/health` 中的 `schemaRevision`；公开服务由服务维护者更新。
2. 在电脑上重新运行上面的安装命令，一并更新 Connector 和 Bridge；已有电脑身份与配对保留。
3. 更新 iOS App。若 Harness 桌面端提示需要重新加载插件，按提示操作后再连接。

新版 Connector 会在每次连接 Relay 时核对版本。确认之前不会转发聊天、配置或工具操作；版本过旧时，手机会收到升级提示，Connector 日志也会说明要求。Relay 升级后会自动重连并恢复暂存消息；缓存超出范围时，App 会重新读取电脑记录。不要通过删掉消息字段来绕过版本校验。

新版 Bridge 同样要求 Connector 声明支持 schema 11，旧 Connector 的接口和 WebSocket 请求会被拒绝并返回升级要求。Relay 对未请求版本协商的旧客户端保留原握手格式；这项兼容措施不代表旧电脑组件能使用本次新增功能。

## 从源码构建 iOS App

```sh
open ios/DSHAnywhere.xcodeproj
```

在 Xcode 中选择自己的 Apple Developer Team，再安装到 iPhone。扫码配对需要真机；模拟器可使用手动配对。

## 目录

```text
site/                     软件介绍页与 iOS 界面截图
ios/DSHAnywhere/          iOS 客户端
packages/protocol/        共享消息类型与校验
packages/relay-server/    Relay 服务
packages/connector/       跨平台电脑端连接器
packages/dsh-anywhere-plugin/ Harness Bridge
deploy/relay/             自托管 Relay 部署文件
scripts/                  macOS、Linux、Windows 安装器
android/                  已暂停开发的 Android 源码
```

网站源码位于 [`site/`](site/)。GitHub Pages 的自动发布工作流已配置：在仓库 **Settings → Pages → Build and deployment → Source** 选择 **GitHub Actions** 后，推送到 `main` 即会发布介绍页。

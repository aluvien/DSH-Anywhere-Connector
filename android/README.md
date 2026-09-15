# DSH Anywhere — Android 客户端

与 `ios/` 功能、UI 对齐的原生 Android 客户端（Kotlin + Jetpack Compose + OkHttp）。
独立工程：只共享线上协议（WSS/HTTPS + JSON），**不引用、不修改任何 iOS 代码**。

## 构建

工具链全部落在仓库 `.tooling/`（首次由编排 agent 自动下载，不污染系统）：

```sh
cd android
./build.sh :app:assembleDebug      # 产物 app/build/outputs/apk/debug/app-debug.apk
./build.sh :app:testDebugUnitTest  # 核心逻辑单元测试 + 本地测试床集成测试
```

`build.sh` 需要的三样东西（已就位时直接可用）：

| 组件 | 位置 | 说明 |
|---|---|---|
| JDK 21 (Temurin) | `.tooling/jdk21` | Adoptium 官方包解包 |
| Gradle | `.tooling/gradle-home` wrapper → 9.7.1 | AGP 9.4.0（内置 Kotlin 2.2.10） |
| Android SDK | `.tooling/android-sdk` | platforms 36.1/37.0 + build-tools 36.1/37.0，自系统 SDK 复制 + 官方 zip 补齐 |

> Android Studio 直接打开 `android/` 也可以；`local.properties` 的 `sdk.dir` 已指向
> `.tooling/android-sdk`（该目录被 gitignore，换机器改回你的 SDK 路径即可）。

## 安装与使用

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

流程与 iOS 相同：Mac 上跑 Connector → 手机扫 pairing code（或手输 relay 地址 /
machine ID / 8 位码或 43 位 secret）→ 连接。relay 必须 HTTPS（本机联调允许 HTTP
localhost）。

## 本地端到端测试床

不需要真 Mac/手机也能全流程验证客户端网络层：

```sh
./tools/testbed.sh                 # 起 relay(:8787) + mock machine，凭据写 .relay-local/
./build.sh :app:testDebugUnitTest --tests "*LiveRelay*"   # JVM 直接走真实协议栈
```

`tools/mock-machine.mjs` 会应答 resume/snapshot、流式 prompt、审批/提问/附件事件，
`--demo approval|question` 可触发对应卡片。

## 连接状态语义（与 iOS 对齐）

界面上的状态点/状态文案由三态合成，而不是单一 socket 状态：

| 字段 | 含义 |
|---|---|
| `transportState` | 手机 ↔ relay 的 socket 状态 |
| `machineOnline` | relay 上报的 Mac Connector 在线状态 |
| `bridgeReachable` | `null` 未知 / `true` Harness 已应答 / `false` bridge 请求失败 |

派生出的 `DSHDeviceStatus`（Offline / Error / Online / ApprovalRequired）驱动首页状态点、
会话状态条、设置页与新建会话的机器行；`transport.state` / `machine.presence` 控制事件
以 `sequence = 0` 走 reducer 的"序列门外"通道。

未读标记：`lastReadSessionTimestamps` + `unreadBaseline`，会话行在
`running || isSessionUnread` 时高亮，打开会话即 `markSessionRead`。

## 调试入口（对齐 iOS 的 --dsh-preview-* 启动参数）

```sh
adb shell am start -n com.dshanywhere/.MainActivity --es dsh-preview conversation
# 可选: conversation | home | home-grouped | home-unreachable（仅 debug 构建生效）
```

## 结构（与 ios/ 一一对应）

```
core/protocol   DSHJson/Events/Models/Pairing/Transcript/DSHMarkdown/Localization
core/network    DSHAPIClient · DSHWebSocketConnection · DSHConnectionState(+Backoff)
core/store      DSHStore(reducer) · DSHProfileStore · DSHSessionGrouping
core/security   DSHTokenStore（AndroidKeyStore AES/GCM ≈ iOS Keychain）
app             DSHAppModel · DSHAppTransport(Remote/Preview)
features/       pairing · settings · sessions · conversation
```

移植契约见 `docs/PORTING-SPEC.md`。

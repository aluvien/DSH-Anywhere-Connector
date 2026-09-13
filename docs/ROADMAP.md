# 后续路线

阶段 1（首页数据正确性）、阶段 2（对话页可读性）、阶段 3（首页重构）**已完成**，见
git 历史。本文件记录**尚未实施**的剩余工作：阶段 4。

判断理由：阶段 3 只动 iOS 展示层，风险低，已完成；阶段 4 要改 relay 的持久化与鉴权
模型，会牵动服务器部署，且必须先定账号策略。

---

## 阶段 3：首页按 Happy 的形态重构 —— 已完成

参考截图（用户提供）中可复用的要素：分组切换菜单、机器 + 项目上下文、可折叠分组、
独立设置页。

已实现：

1. **分组切换**：工具栏菜单与设置页都能切换「按工作区分组 / 平铺列表」，选择写入
   `UserDefaults`（`dsh-anywhere.group-by-workspace`）。分组/过滤/排序逻辑移入 Core
   的 `groupedForList(_:showArchived:)`，有单测覆盖。
2. **折叠状态持久化**：写入 `dsh-anywhere.collapsed-groups`，重开 App 保持。
3. **设置页**（`Features/Settings/SettingsView.swift`）：分组与归档开关、连接状态、
   机器名、Relay 地址、机器 ID、版本与构建号、断开连接（含二次确认）。过去这些散落
   在工具栏，且 relay 地址在配对完成后再也看不到。
4. **会话行信息密度**：标题与相对时间同一行，行高由三行降为两行。
5. 非工作区会话归入单一 "Other" 分组（阶段 1 引入，分组逻辑统一在 Core）。

**尚未做**：机器/项目的显式上下文条与机器切换——依赖阶段 4 的多机器档案。

---

## 阶段 4：多用户与多设备

### 现状（已具备的能力）

- **一台 Mac 绑多台设备已经可用**：relay 的 `pairDevice` 可重复调用，且有测试
  「can target a replay payload to one of several devices」覆盖 iPhone A/B。
  所以「一个用户多台设备」的主体能力不需要新建。
- 设备通过 `machineId + pairingSecret` 换取 device token；relay 只存 token 哈希。

### 已完成（决策无关部分）

- **客户端多机器档案**：过去 App 只存一个 profile，配对第二台 Mac 会静默覆盖第一台，
  于是「一个用户多台 Mac」永远只能碰到一台。现在 `DSHProfileStore` 保存机器列表 +
  当前激活项，Keychain 本就按 deviceId 分账号存放，多台凭证天然共存；旧版单档案
  键会在首次读取时迁移进列表。设置页新增 Machines 分组：点击切换、左滑移除。
  切换会先断开旧 socket（它带着上一台机器的身份）再重连。
  5 项单测覆盖：新增第二台不丢第一台、重复配对不产生副本、移除激活项会回退到
  剩余机器、旧布局迁移、切换只改激活项。

### 已完成（决策无关部分之二）

- **relay 设备列表与撤销**：`GET /v1/machines/:machineId/devices` 与
  `DELETE /v1/machines/:machineId/devices/:deviceId`。二者都要求令牌的
  machineId 与路径一致，因此机器可以管理自己的设备，设备也可以管理同机的兄弟
  设备（手机是通常发起方），但无法跨机器操作（401）。
  - 响应只含 deviceId/name/createdAt，永远不回显任何凭证（只有哈希被存储）。
  - 设备不能撤销自己：那会让调用方握着一个已失效的令牌且无路可回，因此返回
    409 并提示改用「断开连接」。
  - 撤销后立即关闭该设备的在线长连接（4401），不留到下次重连才失效。
  - 新增 3 项测试：列表不外泄凭证、同级撤销成功且被撤销令牌立刻 401、跨机器与
    未知 id 的边界。
  - **客户端已接线**（build 19）：设置页新增 Devices 分组，列出该 Mac 的全部设备、
    标记「This iPhone」、左滑撤销。列表失败（例如线上 relay 还是旧版本）在分组内
    显示原因，而不是弹窗打断——旧 relay 会回 404，那必须显示为错误，绝不能表现成
    「这台机器恰好没有设备」。当前设备不提供撤销入口，因为 relay 本来就会拒绝（409）。
  - 新增 3 项客户端测试，用 URLProtocol 打桩断言方法、路径与 bearer 头，并确认
    relay 的错误会抛出而不是被吞成空列表。

### 已完成（决策无关部分之三）

- **relay 一次性配对码**：`POST /v1/machines/:id/pairing-codes` 由机器令牌签发一个
  8 位、10 分钟有效、用后即废的配对码；`POST /v1/pair` 同时接受 `pairingCode` 与
  旧的 `pairingSecret`（既有安装无需重新配对）。
  - 配对码**只存在内存里**：寿命以分钟计且随时可再签发，不值得为它改持久化 schema；
    内存中也只存哈希。
  - 绑定单一机器并消费式使用，泄露的码既不能重放、也不能改投到别的机器。
  - 签发权限仅限机器令牌：这是「让新设备进来」的能力，不应扩散到每台已配对设备
    （已配对设备尝试签发返回 401，有测试）。
  - 校验失败统一返回同一个错误，避免调用方据此探测某个码是否存在。
  - 新增 3 项测试：签发/单次消费/不可改投/权限边界、旧 pairingSecret 仍然可用、
    过期与重放。
  - **Connector 与 App 已接入**（build 21）：`dsh-anywhere pair` 用机器令牌换码并输出
    code/expiresAt/pairingLink；协议链接与 iOS 的 DSHPairingLink 都能携带 code；配对页
    仍是一个输入框，由 DSHPairingCredential.detect 按形状区分码与密钥（两者长度不重叠，
    不需要用户选模式）。旧的长期密钥链接保持可用，既有安装无需重新配对。
  - 实测：在本机运行 `dsh-anywhere pair` 得到 relay 回应的 HTTP 404——因为线上还是
    r6、没有该端点。这同时验证了命令可用，以及 relay 拒绝时不会把空码交给用户显示。
  - **配对网页也改用它**：connector 每 5 分钟换一个新码写到 connector.json 同目录的
    pairing-code.json，插件优先用未过期的码渲染二维码，并在页面上标明是单次码
    （附剩余分钟数）还是长期密钥。旧 relay 或临时失败只记 warn，网页退回密钥。
    新增 3 项插件测试覆盖优先、回退、过期三种情形。

### 缺口（以下均需先定账号策略）

| 缺口 | 现状 | 影响 |
|---|---|---|
| 账号与归属 | 只有全局 bootstrap token，机器不归属任何用户 | 无法多用户 |
| 注册入口 | 管理员持 bootstrap token 手工执行 `setup` | 用户无法自助 |
| 设备管理 | 设备不可列出、不可撤销 | 设备丢失只能改密钥 |
| 配对凭证 | **长期可复用的明文密钥**（README 已标为发布前必须修改） | 泄露即长期可用 |
| 存储 | JSON registry，单文件全量读写 | 并发与规模都不行 |
| 客户端 | 只存**一个**配对档案 | 无法同时管多台 Mac |

### 需要先定的两件事

1. **账号从哪来**：自建账号（邮箱+密码）、还是复用 GitHub/Google OAuth？
   自建要处理密码重置与邮件，OAuth 要处理回调域与账号绑定。
2. **机器归属模型**：机器属于用户（个人多机），还是属于团队（多人共享一台）？
   后者需要成员与权限表，工作量显著更大。

### 建议的实施顺序（确认上面两点后再动）

1. **存储升级**：registry 由 JSON 换成 SQLite（`better-sqlite3`），保持现有
   `Registry` 接口不变，先做无行为变更的替换 + 迁移脚本（读旧 JSON 导入）。
   这一步不改协议，可独立验证。
2. **账号与归属**：新增 `users` 表与 `machines.userId`；relay 每条路由在现有
   `machineId === principal.machineId` 之外，增加「该机器属于该 principal 的用户」。
3. **自助注册**：用账号 token 换取注册权，替代全局 bootstrap token（保留
   bootstrap 作为首个管理员引导）。
4. **一次性配对码**：`pairingSecret` 改为短时效（如 10 分钟）一次性码。
   注意插件已有一套 6 位 `PairingAuthority`，应统一到同一套语义，避免两套并存。
5. **设备列表与撤销**：`GET/DELETE /v1/machines/:id/devices`，relay 侧撤销后
   立刻断开该设备的长连接。
6. **客户端多档案**：iOS 由「单 profile」改为 `[profile]` 列表，支持添加/切换/
   删除机器；Keychain 按 machineId 分别存 token。此项依赖阶段 3 的机器上下文 UI。

### 风险

- 阶段 4 会改动 relay 的路由鉴权，**每次上线都要确认 schemaRevision 并重新部署**，
  见 README「协议变更后必须重新部署 Relay」。
- 从 JSON 迁移到 SQLite 属于不可逆的数据变更，必须先备份 `relay-data` 卷。

---

## 未验证事项

- **New session 不跳转**：已定位到触发条件本身的缺陷并修复（build 20），但**尚未
  在真机上确认**。调查过程与结论：
  - 先排除了两条猜测：`sendEvent` 实际会用 `++this.sequence` 覆盖字面量 sequence，
    所以不是序号被丢弃；`DSHWebSocketConnection.normalized()` 会用连接配置里的真实
    deviceId 覆写命令，所以硬编码的 `"ios-device"` 不会触发 relay 的
    `body_device_mismatch`。
  - 直接调用本机 bridge 的 `POST /sessions` 验证：返回 `{sessionId, agentPreset,
    summary}`，形状正确，connector 的 `SessionSummarySchema.parse` 也不会拒绝。
    服务端这一跳是好的。
  - 定位到客户端：原触发条件是 `selectedSessionID == nil`，而该值只由列表视图的
    `onChange` 清空。若事件到达时列表不在屏上，它会一直保持非 nil，**从此永久
    禁用跳转**；且 Harness 会广播任何新会话，可能把用户拽进别处创建的会话。
  - 改为按 requestId 关联：connector 会把 `command.requestId` 回显为事件的
    `messageId`，客户端只在 id 匹配时打开，随后清除。新增 connector 测试锁定该契约。
  - 该修复无法单测覆盖（DSHAppModel 位于 App target，不在 SwiftPM 包内），
    因此仍需装机点一次确认。
- **提问卡片端到端**：插件与 relay 侧已就绪，尚未在真机上验证「手机与浏览器同时
  收到、先答的赢」。

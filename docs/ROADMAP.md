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

### 缺口

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

## 未验证事项（沿用自阶段 1/2）

- **New session 不跳转**：未能在静态分析中定位。已加两条兜底（失败弹窗、
  创建后拉取列表并 diff 出新会话再跳转），但根因仍未确认。装 build 16 后点一次，
  若有弹窗则说明是命令失败，把弹窗文案带回来即可定位。
- **提问卡片端到端**：插件与 relay 侧已就绪，尚未在真机上验证「手机与浏览器同时
  收到、先答的赢」。

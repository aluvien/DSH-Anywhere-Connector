# iOS 会话页 UI 交接（参考图对齐专项）

> 状态：已实现并验证（build 59 之后）。Blocked 项见 §3，需服务端配合。

## 1. 已按参考图实现（对照验证）

- 回复铺满：`AssistantTurnView` / `ThinkingDisclosure` 去掉 320pt 限宽，
  `ConversationView.swift`（`AssistantTurnView`、`timelineRow`）。
- 用时行：`用时 X分钟Y秒 >`，`>` 紧跟文字（非右对齐），下方全宽分割线
  （`Divider().padding(.horizontal, -16)`  bleed 到屏幕边）。
- 操作行：复制 + 分支 + 回复时间（`MessageBubble` actions），图标 20pt。
- 回复时间：`DSHChatMessage.timestamp`（ms），reducer 首见打点、重播保留，
  `EEEE HH:mm`（如“星期二 17:56”）。单测
  `testMessageTimestampIsStampedOnceAndSurvivesReplay`。
- 跳转按钮：原生复刻——`arrow.down`（直箭头，非 circle.fill）+ 白底 +
  hairline 描边 + 阴影，居中浮于输入框上方（实测 composer 高度定位）。
- 工具调用折叠进本轮时间线；跑着的任务自动展开，绝不藏 live 进度。
- 新增本地化 key（`Localizable.xcstrings`，手工 surgical 添加，保持原格式）：
  `Thinking`、`%lld operations`、`Took %lld sec/min/min+sec/hr+min`。

## 2. 故意与参考图不同的地方（用户明确要求）

- 输入框无麦克风键；无文件/智能体药丸（入口只留右上菜单）。
- 停止键为蓝色圆（参考无此态）。

## 3. Blocked：赞/踩按钮（未画，不是漏了）

- 调研结论（2026-09-16）：` /feedback` 只是会话级文本备注
  （`dsh-command-feedback/README.md`：`/feedback <text>`，裸调回用法错误），
  无 messageId 参数；逐消息评分要走 `messageFeedback/put
  {sessionId, messageId, rating: positive|negative, …}`
 （`dsh-message-feedback/lib/types/types.d.ts`），bridge 只透传
  `commands/execute`，protocol `CommandEnvelope` 无对应类型。
- 接入需要（按序）：protocol 加命令类型 → connector 透传 → bridge 调
  `messageFeedback/put` → iOS 操作行加两键。
  bridge 落地前不要在 App 里画假按钮（之前刚清过一批）。

## 4. 本轮（截图 batch）做的其他事

- 分支按钮 400 修好：`createSession` 有 workspace 时不再同时传 cwd
  （bridge 只收其一）；分支带最近 40 条 Q&A 文本作首语（无原生 fork，
  推理/工具细节不带，标题为 `原标题 分支`）。
- 权限选择成功不再弹“Command completed”卡：connector `permission.set`
  改走快照分支 + bridge 静默窗过滤原生 `/permission` 回声；失败仍弹窗。
- 输入框输 `/` 弹出命令补全（点选只补全不执行），会话/新建页共用
  `DSHSlashCommands`；命令菜单里的附件区已删。
- 会话圆点改 gutter 悬浮（标题边距零占用）；跳转键黑底改主色适配暗黑；
  上下文环改回单色圆环（弧长=比例）；复制/分支键改 17pt。
- `message.timestamp` 首见打点，用于回复时间行。

## 5. 网页端有、iOS 没有的功能（按价值排序，来自 dsh web 调研）

1. 会话搜索（标题+内容）：需 `session/search` 经 bridge 透传 + 新命令类型。
2. 会话重命名 / Fork（从某 turn 分叉）：需 `session/rename`、`session/fork`；
   iOS 现只有 workspace 重命名 + create 复刻的伪分支。
3. 工作区文件浏览+预览+变更：需 `workspaceFiles/*` + `changes/follow`；
   iOS 只有上传件列表。
4. 排队/steer 管理（改/删/追问已发 prompt）：需 control 流 + `session/updateQueue`。
5. Subagent 目录+续写/Stop：需 `subagents/*` + `session/follow`。
6. Todo/Goal 进度条：需 todo/goal 投影；iOS 只有 `/goal` 透传。
7. Trajectory/耗时账本：需 `session/page/follow` + `sessionStats`。
8. Deliverables 产出文件行：需 mutation 工具 `locations` 投影。
9. `@文件/@会话` 引用补全：需 `fileReferences` + `session-reference`。
10. 终端 PTY + 后台 Jobs：需 `terminal/*` + `jobs/*`；iOS 只有 tool 文本。
11. Skill 目录+卡片：需 `skills/list` + skill toolview。
12. 会话日志 ZIP 导出：需主机归档流 + 鉴权下载路由桥接。
13. Plan 态芯片 + plan-review 卡：需 `plan/mode` 投影。
14. Schedule/Workflow 只读目录：需 `schedule` 投影 + `workflow-run` 节点。
15. 工作区全管理 + Host 设置：需 `workspace/*` + `directory-picker/*` +
    `settings/describe/set/mutate`。

## 6. 原生化审计结论（iOS 27 方向）

- 已换原生：上下文环→ SF `gauge.with.dots.needle`（`accessoryCircular`
  Gauge 最小尺寸塞不进 34pt 行，实测放弃）＋用量配色保留；`apple.logo`
  首页菜单；`arrow.down` 跳转键；`line.3.horizontal`；`icloud.slash`；
  `cpu`；`shield*`。
- 删掉的自绘：`DSHRemoteContextGlyph`、`DSHRemoteAgentGlyph`、
  `DSHRemoteModelGlyph`、`DSHHappyAvatar` + `HappySessionRow`、
  `RemoteAgentsPanel`。
- 故意没动的：`presentationCompactAdaptation(.popover)`（改掉会变成
  sheet，大改 UX，先不动）、自绘 header + 隐藏导航栏（换原生栏会改
  产品视觉）、7pt 状态点（Shape 非 glyph，无碍）。

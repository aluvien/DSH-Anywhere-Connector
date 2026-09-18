# iOS 会话页待解清单（2026-09-16 用户截图 batch）

> 约定：修完一项就在下面改状态。`[树]` = 代码已改未发版，`[59/60/61]` = 已发版。

## 1. 编辑框降高 + 图标下移，底部距离不变
- 状态：[树]顶部 padding 10→7，底部 8 不动，待发版验证。
- 做法：expanded 卡顶部 padding 10→7（底部 8 不动），行距 7→6。

## 2. 模型弹窗智能滑块：指针与标签对齐，滑动实时同步 header，关闭时生效
- 状态：[树]滑块已加刻度标签（与 rail 同一套 `DSHReasoningRailMetrics` 几何，旋钮/圆点/标签同 x；边缘标签钳制不溢出），`ReasoningEffortMenu` 改 draft 态：滑动+换模型都只写 `pendingSelection` 并实时同步 header（模型名+智能名），关闭时 commit 一次 `selectModel`；支持 VoiceOver 可调。待发版验证。
- 注意：`Shared/DSHRemoteGlyphs.swift` 已进 Xcode target（`project.pbxproj` 有 BuildFile），`DSHRemoteReasoningSlider` 已被会话弹窗引用，归属已对齐。

## 3. 模型切换提醒连续只留最后一条
- 状态：[树]reducer 改替换（`modelChangesBySession[id] = [stamped]`），单测回归通过。
- 做法：reducer 里 `modelChangesBySession[session]` 改为替换而非追加。

## 4. 复制/分支按钮再小一号 + 上下边缘对齐
- 状态：[树]改 resizable 共用视觉高度 13（点击区仍 24），同字号包围盒不一致是错位根因。待发版截图验证。

## 5. 思考信息折叠在用时下面
- 状态：[树]已是该结构（展开区在时间行与分割线之间），待发版验证。

## 6. 图片多选 + 点击缩略图预览
- 状态：[树]双 composer 多选 10 + `DSHImageViewer` 全屏预览（起草/历史/新建页），真机验相机与相册。
- 做法：`PhotosPicker` 数组多选（上限 10）+ 全屏图片查看器
  （起草附件与历史消息共用）。

## 7. 跳转按钮以编辑框上方为基准、不遮挡
- 状态：[树]改到 dock 内部最上方（`composer(proxy:)` 首个 child，底边与编辑框顶边之间隔 stack 间距+4pt padding，结构上不可能再盖住输入框）；删掉 overlay + `DSHComposerHeightKey` 实测高度整套（漂移是遮挡根因）；去白底圆盘后进一步半透明（`opacity(0.5)`，内容从箭头底下透出来）。待发版验证。

## 8. 下滑隐藏键盘：跟手，不是一刀切
- 状态：[树]删掉自定义 DragGesture 的 `resignFirstResponder`（14pt 一刀切，抢在系统跟手逻辑前把键盘掐掉；iOS 26 起 resign 动画行为也有变化）。只留 `.scrollDismissesKeyboard(.interactively)`：转录区下滑键盘实时跟手。输入框本体起始的触摸系统无公开跟手 API（编辑器本身就是原生 TextField，非原生不是原因），那一块只能点空白/滑转录来收。

## 9. 任意位置右滑返回：原生打不开时自建全屏手势兜底
- 状态：[树]根因定位：原生全屏返回只在默认返回按钮时生效，自绘 header + 隐藏导航栏属于不支持情形（2026-05 社区教程实证），所以 build 65 的纯原生方案没反应。`Coordinator` 加自建全屏 `UIPanGestureRecognizer`，复用边缘手势自己的交互转场驱动（`targets`→`handleNavigationTransition:`，运行时解析，FDFullscreenPopGesture 同款手法），跟手+速度+可取消；`gestureRecognizerShouldBegin` 限右行速度方向 + 无转场进行中，竖滑与左滑代码块不受影响；iOS 17 同样生效。注意用了私有 targets/action（业界常用，未见批量拒审，但理论有审核风险）。待发版真机从屏幕中间起滑验证。

## 10. 代码引用块淡灰背景
- 状态：[树]quote 加 tertiary 底 + 圆角（fenced 本来就有）。
  待加 tertiary 底 + 圆角。

## 11. 回复内容椭圆遮罩盖四角【已修，待发版验证】
- 机制（已亲自读码确认）：`MessageBubble` 助手链路
  `background Clear` 却仍套 `.clipShape(RoundedRectangle(18))`
  （`ConversationView.swift` 约 2252 行），把内部代码块/表格直角底的
  四角切掉，看起来像椭圆罩盖在内容上。
- 修复：助手链路去 clip（用户气泡保留），1 行。
- 状态：[树]助手链路去 18pt clip（用户气泡保留），截图确认无罩。

## 12. 加号菜单图标去圆圈底
- 状态：[树]去底完成。

## 13. 本清单
- 状态：已落盘。修完一项改一项状态。

## 14. 编辑框图标统一视觉高度 + 沉底 + 输入框降高
- 状态：[树]新增 `DSHComposerGlyphHeight=19`：加号/麦克风/权限改 resizable 定高，上下文环 22→19、推理表 24→19（内部等比缩），四处 `size:20` 调用收敛到默认值；控制行本就是卡片最后一行（编辑框变高时仍贴内底）；`DSHRemoteComposer` 展开 112→100/收起 56→52，纵向 padding 13/9→10/8。待发版截图验证。

## 15. 思考行刷屏：无正文的 think 步骤折进下一轮
- 状态：[树]长 agent 回合以 think→tool→think→tool 到达，转录按工具位置拆成多轮，每轮各 render 一个"思考 >"行。`groupedTurns` 后加 `mergingReasoningOnlyTurns`：无可见正文的轮次把消息+工具并入下一轮，一轮只剩一个时间线行（截图里 7 个"思考 >"会收成 1 个"用时 8秒 >"）；尾部未完成的 think（直播中）与被用户/命令/模型切换打断的保持独立，直播进度不丢。新增 2 项单测（折叠/尾部保留），旧 2 项分组单测语义不变。待发版截图验证。

## 16. 执行中输入框上方两行直播状态
- 状态：[树]`composer` 内输入框卡片上方加 `liveTurnStatus`（running 或有工具在跑时出现）：第一行固定`深度求索中… {已用}`（`TimelineView` 每秒跳；计时从**最新被接收的用户消息**起（Mac 接到任务时刻，上传与本地排队耗时不计），`turnStartedAt` 仅作回退，落定后以用时行为准）；第二行最新动态（running 工具中文标题 > 流式正文末行 > 思考末行 > 执行中/等待响应）。待发版验证。

## 17. 直播打磨三件套（截图 batch）
- 状态：[树]①控制行图标下沉：`DSHRemoteComposer` 展开态底 padding 10→5（顶 10 不动，收起态对称 8 不动）；②跳转箭头去白底圆盘（裸主色箭头+投影，不再遮罩下面内容；dock 内置定位已保证不盖输入框）；③输出时转录不再出现思考行：`visibleTranscriptSections` 在 running 时过滤无可见正文的轮次（思考+工具都只走输入框上方的直播行），turn 一结束即以折叠形态正常出现。待发版截图验证。

## 18. 工具行搬网页版中文动词（"读取 · 路径"）
- 状态：[树]把网页版会话 UI（`dsh-client-ui-tool` 行模型：`TOOL_VARIANTS`/`TOOL_TITLE_KEYS`/`SUMMARY_KEYS`）逐字搬到手机：`DSHToolPresentation`（variant→读取/搜索/Bash/写入/编辑/代码/工具调用，`read_image`→读取图片等精确覆盖，摘要按 variant 取 path/file_path/url/command/description/query/pattern 首行）；`DSHToolActivity` 新增 `arguments` 字段（start 存参、complete 保留，标题不再被结果文本冲掉）；工具卡标题+状态（运行中/已完成/失败/已取消）与输入框上方直播第二行共用同一套 headline。新增 3 项单测。待发版截图验证（对照网页版"读取 · 路径"行）。

## 19. 会话页五件套（截图 batch）
- 状态：[树]①复制图标 13→15（分支同步放大保上下边缘对等）；②用时/回复分割线去 `-16` bleed，与回复同宽；③全屏右滑见第 9 项（自建兜底）；④智能仪表所指≠实际：`selectedEffortID` 与目录 id 空间漂移时旧代码 `?? 0` 直接打到最低，改为 `dshNearestReasoningEffortIndex`（精确命中优先，否则按语义 rank 就近，空表才 0），仪表/滑块/draft 三处同源，新增 1 项单测；⑤滑块绘图：刻度标签去边缘钳制（钳制把边 label 推离圆点，短名居中+长名中截断即可），填充改到旋钮中心（原来最小档右溢 7pt）；⑥模型选择卡顿：`selectModel` 推迟到弹窗关闭动画后 0.3s 再发（快照刷新与动画抢主线程是卡因），弹窗与 sheet 两处；⑦跳转箭头半透明（`opacity(0.5)`）；⑧发送即收键盘（`isDraftFocused=false` + `resignFirstResponder` 双收，分别覆盖展开/收起两套编辑器）。待发版验证。

## 20. 手绘图标原生化第一刀（有备份）
- 状态：[树]备份在 `../DSH-ANYWHERE-backup-20260917-icon-cleanup/`（4 文件原样 + 全量 patch + `RESTORE.sh` 一键还原，已逐字节校验）。删 `DSHRemoteComposeShape`（死代码，60 行）；"方案"图标自绘改 SF `list.bullet` 并删 `DSHRemotePlanShape`。首页文件夹开/合自绘**没动**（并行复刻 artwork，等拍板）。保留：智能仪表/滑块（定制交互无原生对应）、用量圆环（Gauge 实测塞不进）、Markdown 整套（原生不支持表格/代码块复制）、盾牌 `>_`（3 行，无 SF 对应）。待发版验证（加号菜单"方案"行图标）。

## 21. 会话页浮层上 Liquid Glass（含悬浮布局重构）
- 状态：[树]原因：之前全写死实心底（`Color(.systemBackground)`+描边+阴影）+ 自绘 header 藏了原生导航栏，所以吃不到系统玻璃；且 dock/顶栏是 safeAreaInset 切出来的独立段，透明了也只能透出实心底。改成悬浮布局：转录全幅滚动，输入框 dock 以 overlay 浮在上面（内容从底下穿过、玻璃里折射），末行留实测高度 spacer 防遮挡；键盘避让改手动（通知取帧高−home 条+8pt，随键盘动画曲线）；overlay 内各 stack 根逐层 `maxWidth: .infinity`（overlay 默认向内容收缩，不钉会缩成一条）。新增 `dshFloatingChrome(_:)`（`glassEffect(.regular, in:)`，iOS 26+；以下走原来实心卡）：输入框卡（双形态）、右上浮动胶囊、跳转箭头玻璃圆盘。转录文字区/工具卡故意保持实底。**顶栏最终形态**（整条毛玻璃违和→退回实心→今回）：顶栏容器透明无横条，毛玻璃只留返回圆钮与右上胶囊两个浮动件，标题字直接浮着，首行 spacer 与 header 测量保留。底 spacer **修正公式**为 `dockHeight + dockBottomPadding + 4`（旧公式少算 dock 自身底边距，恒定藏 8pt≈半行字；旧 `keyboardOverlap` 状态与 `homeIndicatorHeight` 已删除）。顶渐隐 0.75→0.5。待发版重点验证：①末行/卡片键盘弹起时是否可见；②键盘弹起 dock 是否跟上、有无抖动；③26 真机折射 vs 17 回退；④标题字滚过内容时是否可读。

## 22. 会话页三件套（截图 batch）
- 状态：[树]①用时行默认折叠：`AssistantTurnView` 加 `manualExpansion` 区分手点 vs 自动展开，跑任务时自动展开看直播，工具一落定自动收起（手点开的不收）。**根因补记**：旧 `hasRunningTools` 把失败/取消也算"运行中"，出一例失败整轮永久展开+呼吸灯常亮+直播行赖着不走；现仅 `status==running` 算 live，失败即落定（卡片呼吸灯同步只在 running 闪，删 `isCompleteStatus` 死代码）；②复制/分支 15→17 + medium 字重（SF 同字号包围盒不齐，沿用 resizable 定高保上下边缘对等；系统没有更粗的"复制按钮"，加粗本图标是最省的）；③右上新建按钮改真新建：`NewSessionSheet` 去 `private` 跨页复用，顶栏胶囊按钮不再调分支（分支保留在每条回复下），建完走已有 `selectedSessionID` 自动 push 进新会话。待发版验证。

## 23. 空白转录 + 跳转失灵（真机照片 batch，实锤两处）
- 状态：[树]现象：转录只剩工具卡，文字气泡（双方）全无；跳转按了没反应。排查：把本机会话最近 120 个真实事件喂进**真实** bridge 归一器（167 个协议事件，文字完好）再喂进**真实** Swift reducer（独立 harness 编译运行：41 消息 38 工具，分组后文字轮次都在）——直播链路清白。真凶①：历史回放重叠（25 会话 backfill/下拉/点开并发）时第二个 `history.started` 整体替换 carry + 首 batch 守卫丢弃旧 completion，会话超 1000 事件窗口的行永久丢失。修为 fold 进已打开的 carry（首 batch 保留），新增重叠单测（旧代码必丢 `old`，手算验证区分度）。真凶②（跳转）：`.defaultScrollAnchor(.bottom)` 与程序化 scrollTo 互掐是首要嫌疑，已删除，跟随完全交棒给每事件 scrollToLatest。**续**：74 上末行仍被咬，垫子公式复核无误（`dockHeight + dockBottomPadding + 4`，锚点落视口底边时数学成立），故 viewport 根本没落到底——跟随标记在转录抖动（过滤/合并/垫子伸缩）时被误清，onDisappear 把布局闪烁当成了滚走。改为 0.6s 鉴别：消失后 0.6s 内重现=抖动（保持跟随），不重现=真滚走（才放手）；落定态仍立即放手。注意：已丢失的旧行回不来了（回放只发最近 1000），新内容正常累积。待发版验证流式与跳转。

## 24. 转录分页一期（渲染窗口 + 附件封顶，不动协议）
- 状态：[树]初衷：手机不被信息炸。实测：转录文字有回放窗口兜底，真正无上限的是附件（内存字典无限+磁盘从不清理）与全量 ForEach 每 token 重排。做法：①渲染窗口——首屏只挂最新 50 段，顶部"↑ 加载更早 N 段"每次 +100（本地 store 零协议开销；加载后 pin 住原首行防跳；换会话重置）；**滑到顶自动翻页**（顶哨兵 onAppear 调同一加载函数，再出现不再触发故不循环；点按按钮保留）；②附件内存改 `NSCache`（100 个/50MB，自驱逐且线程安全，旧字典跨线程读还 race）+ 磁盘 200MB 按最旧删（写时顺手扫，`nonisolated` 后台跑）；③思维链点用时展开本就是本地行为，无需加载（store 里有）。转录 store 不动（动了就要新协议+重部署 Relay，留二期）。新增驱逐顺序单测。待发版验证长会话首屏速度与加载更多。

## 25. 照片三件套 + 跳转双驱（截图 batch）
- 状态：[树]①顶渐隐 0.5→0.65（0.75 嫌重、0.5 标题糊，取中）；②合并被模型卡截断：`mergingReasoningOnlyTurns` 对 `.row(.modelChange)` 穿透（只渲染不打断）+ 孤儿 tool 并入 pending（有 pending 就不是真孤儿），用户轮/命令结果仍是边界，旧单测语义不变，新增穿透单测；③跳转与跟随双驱：`DSHScrollFinder`（UIViewRepresentable 公开遍历找 UIScrollView）+ `DSHScrollCoordinator` 直设 contentOffset，`scrollToLatest` 改双发（SwiftUI 动画与否照旧 + UIKit 同目标），跳转键与三个跟随观察点共用；纯公开 API，无私有调用。待发版验证：思考+模型切换+回答是否收成一行；拉顶自动翻页跳不跳；跳转按下去动不动。

## 26. 执行中发送（排队/插话）+ 排队气泡（含真取消）
- 状态：[树]①分支图标 17→14（复制保持 17，主次拉开，同框居中）；②跑任务时输入框有字则发送键不再变停止键：点发送弹菜单二选一——排队发送（`mode:queue`，排在当前轮后）/插话发送（`mode:steer`，调整方向），通道协议+桥全现成（`prompt.send.mode` 直通），任务不暂停；无字时仍是停止键。`send(mode:)`/`sendPrompt(mode:)` 均默认 queue，老调用不动；③排队气泡：输入框上方右侧，一个显示原文、多个显示 N 条排队，点开详情表（模式+时间+原文）；④**取消/编辑真做了**：纯文本排队改本机持有（不发服务端，上轮落定自动 FIFO 发出），故取消=本地删、编辑=本地改、另有立即发送，附件排队仍走服务端直发（上传已发生，退不回）；持有跨杀进程持久化（按机器隔离，24h TTL，切机器自动换组）；被接收按原文匹配消泡。服务端队列改删仍需 `session/updateQueue` 协议专项（详情页已写明边界）。新增持有/改/消/取单测。待发版验证：排队→取消是否真不执行、落定是否自动发出下一条。

## 27. 76 落底仍被咬：双驱挂载 + 落定补钉
- 状态：[树]垫子公式复核成立（`dockHeight + dockBottomPadding + 4`，锚点落视口底时数学闭合），故视口根本没落到底。两处补钉：①finder 挂载空转：`updateUIView` 在输入不变时会被 SwiftUI 跳过，挂载时若早于 superview 就永为 nil，双驱的 UIKit 一半从没活过——加 `DSHScrollProbeView.didMoveToSuperview` 挂载即遍历（原 update 保留作备份）；②落定竞态：turn 结束瞬间过滤 lifting+合并折叠，立即钉按的是旧布局，idle 后再无事件补钉——结束且跟随时 0.4s/1.2s 各补钉一次（调度时跟随才排，窗口内滚走最多吃一钉）。待发版验证（务必报版本号）：落底末行、跳转、跑完回位三连。

## 28. 进会话闪烁 + 本轮剩余项（截图 batch）
- 状态：[树]①闪烁根因：回放 `history.started` 清空数组→1000 行逐条爆米花式重绘，进一次闪一次。改成不清屏：回放行按 id 合并（重复即无操作），首见序号保序、渲染按序号排——视觉上旧行原地不动，重播只补缺的行；carry 保留作纯安全网（窗口外行），超时合并与重叠单测语义不变，改了两处旧断言（数组顺序 live 在前）。沙盒 swiftc 间歇拒顶层语句，harness 验证走 Xcode 单测。②分支 14（复制 17，同框居中）；③排队/插话菜单 + 本地持有可取消/编辑（见 26）；附件上传图用户侧靠右；④顶栏最终：透明容器无横条 + 0.95 渐隐拉长 1.8 倍（标题区覆盖约 0.7）+ 返回圆钮/胶囊玻璃；⑤图二参照（整片磨砂顶栏）未做：要在现有透明头上再加整幅磨砂等于把横条请回来，先看 0.95 长渐隐的真机效果再定。待发版验证：进会话闪不闪、分支大小、附件位置。

## 29. 发送回执 + 失败重试（有去无回专项）
- 状态：[树]现状：socket 断时 `transport.send` 直接 throw，字已清空，只剩一条 alert 瞬闪，消息凭空消失；发出去 Mac 没收下则无限 limbo。做法（纯本机，无协议改动）：`sendPrompt` 自带 requestId 并登记待回执；被接收（accepted 原文匹配）即销号，迟到接受还能自愈失败横幅；15s 无回音判丢——relay 拒因 `protocolErrorsByRequestID` 精确归因服务端，连接非 connected 归本地，否则记 Mac 未响应；transport 当场抛错直接归本地并暂存原文+凭据、同时摘掉本次缩略图预挂载（防串到下一条）；输入框上方红条横幅（原因+原文+重试+关闭），重试原样重发。新增匹配/暂存/重试单测。待发版验证：断网发一条看横幅+重试、Mac 沉默 15s 看归因。

## 30. 顶栏整片磨砂 + 跳转落点修复
- 状态：[树]①顶栏改整幅 `ultraThinMaterial`（全版本通用，无需分支；返回圆钮/胶囊玻璃保留；渐隐删除；spacer 与测量保留）；②跳转落点：点箭头落在半路=按旧布局落锚（LazyVStack 尾部未算完），与落定补钉同款修法——点按后 0.35s/1.0s 再各钉一次。待发版验证。

## 31. Mac 侧图片回传（缩略图内嵌）+ 漏数据审计
- 状态：[树]根因：`{type:image, attachment:{attachmentId: sha256…}}`（网页上传/Mac 文件/模型回图）无 receiptId，手机无字节路径，桥还给随机 id（每次重播 duplicate 叠加）。做法：协议 `ChatAttachment.thumbnail?`（data URL，40 万字符封顶）+ `RELAY_SCHEMA_REVISION` 5→6；桥按 `DSH_HOME/attachments/v1/objects/ab/hex` 同步读盘嵌缩略图（256KB 封顶，超限/读不到降级纯名行；id 改用 attachmentId 保稳定；assistant 消息补发 attachments）；connector 仅重编（透传）；iOS 解 data URL，receipt 优先、缩略图兜底。测试：protocol 17（含封顶拒绝）、plugin 42（含稳定 id+内嵌正向）、relay 12、connector 13 全绿；iOS 单测走 Xcode。**发版顺序**：先重部署 Relay（旧 Relay 拒收新消息！），再发 App（旧 App 严格解码会整条丢消息！），最后 Mac 重编重启服务。审计余项：deliverables/presented（产出文件不可见）、todo/write（清单无展示，ROADMAP §6 已有）、llm/retry（重试中状态缺）、compaction/prune（压缩通知缺）、工具结果图片块（本会话零出现，暂不扩 schema）。待发版验证：网页传图→手机看缩略图。

## 32. 中断不断折 + 滚动零时序依赖 + 命令入框
- 状态：[树]①思考又被放出来（照片实锤新机制）：think 与回答之间隔了用户新消息（中途又发了一轮），用户轮把折叠打断。改为用户轮/命令卡/模型卡全部穿透（原地渲染不断折，pending 挂到下一个可见回答轮；队尾无回答才独立成段；取消轮误挂入下一时间线属罕见且默认折叠）。新增中断穿透单测。②滚动 H4 结构性消除：探针挂载时序不可远程验证，coordinator 加全窗最大 scroll view 回退（转录全屏恒最大，纯公开 API），挂载成败不再影响直驱。③加号 plan/goal 不再裸发空命令：改句首插入 `/plan `/`/goal `（替换行首旧 token，防连点叠加）并聚焦等参数；compact/export/feedback 裸跑有效不动，permission/model 照旧开面板。待发版验证（必须新版号）：思考单行、跳转落底、命令入框。

## 33. 键盘/展开缺重锚定（铬驱动事件）
- 状态：[✓Build 102]根因：inset 变大不搬 contentOffset；全部旧触发都是内容驱动，键盘/dock/focus 变化零开火——点输入框=旧视口+新高框，必埋末行（公式无罪）。修：keyboardHeight（含 0.35s 落定补钉）+ dockHeight 两个 flag 门控 observer（isDraftFocused 触发可省：无几何变化时无需钉）。Focus 提升（`focus: Binding?` 整套）已回滚：它让 solver 超时，且键盘 bug 不需要它（keyboard/dock observer 足够；compact 下父层仍看不见 focus，记为已知局限）。safeArea 双重避让经反证不存在；不重构成 safeAreaInset Composer（同样缺这三个钉）。构建插曲：ConversationView.body 超 19s solver 预算（83–101 连挂），解法是把 body 拆成 `transcriptScrollView`/`overlayChrome`/`bottomAnchorView`/`transcriptSectionView`/`loadEarlierBanner`/`inlineDecisionCards`/`ConversationModals`/`ConversationObservers` 八个独立预算单元（教训：巨 body + 修饰链是超时的根源，`warn-long-function-bodies` 可量化）。待发版验证（验收十条）。

## 协作备注（2026-09-16 发现，09-17 已对齐）
- `Features/Shared/DSHRemoteGlyphs.swift` 已进 Xcode target 并被 `ConversationView` 引用；归属已确认，无需再定。
- 动 `ConversationView.swift` / `SessionListView.swift` 前仍先对齐，避免互盖。

## 34. 2026-09-17 三张截图：上下遮挡、键盘跟随、模型等级动画
- 状态：[树]已修，未发布。保留此前 Build 102 的 body 拆分。
- 布局：header / transcript / composer 改为真实垂直布局；正文视口裁剪在两者之间，删除浮层占位、顶部可滚走 spacer、手算键盘高度和延迟补滚。原生键盘安全区负责抬升整页。
- 跟随：探针仅绑定正文最近的 UIScrollView；按用户滚动位置判断是否跟随，监听 contentSize / frame / bounds 在排版完成后保持末尾。删除 lazy anchor 出现/消失判定及全窗口最大 scroll view 回退，回看历史时不自动拉回。
- 等级：触发按钮与弹窗标题、滑块共用当前草稿；切换到不支持等级的模型隐藏滑块并显示中性模型图标。图标采用共享语义等级映射；指针和蓝弧端点共用 135°→330° 角度。拖动时取消反复启动 spring，轨道坐标固定，档位数量变化重新校准索引。
- 回归：`xcodebuild test -only-testing:DSHAnywhereTests/DSHConversationViewportTests` 6 项通过，`git diff --check` 通过；结果 `/tmp/dsh-viewport-final.xcresult`。新增测试覆盖长对话实际 SwiftUI 布局、输入框展开、320pt 键盘大小安全区变化、流式内容增高、回看历史不抢滚动、短内容 inset、不同 catalog 子集同等级图标一致、指针与弧端同向。截图附件保存在测试 xcresult。无头模拟器未渲染软键盘，因此软键盘跟手收起与真机连续拖动仍需设备复验。

## 35. 2026-09-18 Build 103 缺失 Remote 模式：发布源目录错误
- 已确认：用户手机 1.0(103) 的设置页没有 Interface/Home layout，且缺少“默认显示消息操作”。Xcode 归档 `/Users/aluvien/Library/Developer/Xcode/Archives/2026-09-17/DSHAnywhere 2026-9-17, 23.48.xcarchive` 的 dSYM 指向 `/Users/aluvien/DSH-ANYWHERE`；该独立旧目录不包含 Remote 路由/首页/设置。不要从该目录打包 iOS。
- 正确 iOS 源目录：`/Users/aluvien/Develop/App/DSH-ANYWHERE/ios/DSHAnywhere.xcodeproj`。本工作区源码与 102 归档均包含 Remote；不能仅靠源码有按钮就断言用户手机有按钮。
- 候选：1.0(104)，从当前完整工作树独立 clean archive，包含 §34 对话布局与等级修复。签名 archive/export 均通过；从最终 IPA 解包核对版本104及 Remote/设置相关二进制标记。2026-09-18 00:20（上海时间）上传成功，Apple 已接收，等待处理；Delivery UUID：5e020b69-b018-4cff-80b3-07c6af8fe615。
- 验证：Release 配置 `DSHHomeLayoutTests/testSettingsCanSwitchBothHomeLayoutsAndPersistSelection` 通过，实际找到设置页 UISegmentedControl 并切至 Remote、检查持久化，再切回经典；设置与两个首页截图均留存。另将既有 unread 测试的 Debug 专用 fixture 改为通用 fixture，使 Release 测试可编译。
- 交付：`artifacts/ios/remote-restored-build104-20260918/DSHAnywhere.ipa`；同目录 `source-manifest.json` 记录源目录、提交、未提交修改、源码摘要及 IPA SHA256，避免再次混用旧源。

## 36. 2026-09-18 恢复 104 丢失的磨砂与透明风格
- 状态：[✓Build 105]2026-09-18 00:40 上传成功，Apple 已接收；Delivery UUID：f675b77e-2872-479a-adb7-3af19d181abd。104 用 VStack 分割视口并 clipped，消除了控件背后的正文，导致顶部磨砂和底部透光一并消失；该视觉回归由 §34 的布局修复引入。
- 修复：用真实 header/composer 的 top/bottom safeAreaInset 替代 VStack 分区，正文 scrollClipDisabled 允许滚动经过浮层背后；顶部使用 ultraThinMaterial，底部保留现有 Liquid Glass，取消平面85%底色。继续由系统处理键盘，不加手动键盘高度。
- 跟随：监听 adjustedContentInset/contentInset，首尾可见范围与玻璃底层范围分开计算；惯性滚动、手动回看时仍不强制跳底。
- 验证：7项 DSHConversationViewportTests 通过；实际 SwiftUI host 断言原始滚动表面覆盖上下控件背后，可读视口仍在控件之间；输入框展开与320pt模拟键盘安全区下保持末尾。结果 `/tmp/dsh-glass-verified.xcresult`；截图 `artifacts/ios/glass-restoration-20260918/`。真实软键盘交互收起仍需设备复验。

## 37. 2026-09-18 编辑器统一与模型弹窗稳定性
- 状态：[✓Build 106]2026-09-18 02:06 上传成功，Apple 已接收；Delivery UUID：711fb8d5-a6be-4ddb-88a0-137790af98d2。
- 顶部：首页、会话、新建和设置共用轻模糊背景。直接降低模糊效果强度，而非把整层设透明造成锐利文字穿透；浅色去除灰色材质底，深色减轻底色。正文 safeAreaInset 与键盘跟随规则保持。
- 模型：新建与会话共用 DSHModelConfigurationPicker。移除气泡中的嵌套系统 Menu，列表在固定330×222pt气泡内切换；模型/智能紧凑排列，标签下方增加留白。等级只保留一个选中状态，轨道、填充、圆点、旋钮、标签与拖动命中共用坐标，消除端点多余蓝色突起。移除编辑器对子控件的整体动画；关闭气泡时只提交最终选择。
- 编辑器：删除另一套 expandedComposer 和旧新建编辑器，统一使用 DSHRemoteComposer；相同外边距、权限/模型选择器、上下文和发送控件。折叠偏好只决定加号菜单或展开附件操作。首页44pt按钮同样使用浮动玻璃样式，蓝色新建按钮为“图标 聊天”（两侧16pt，图文8pt）。
- 通知：以已接受用户消息为边界，发送前模型多次切换只保留最终一条；保留此前发送批次的选择提示，历史回放避免重复。权限状态不生成会话行，过滤旧版 preset 成功回执，失败仍显示。
- 设置：各区域采用适配浅/深主题的分组底色；Remote/经典切换保留。
- 验证：Release 配置11项界面/布局回归及45项事件状态测试通过。涵盖实际原生 popover 的列表/模型/等级切换尺寸不变、两种控件偏好下新建与会话输入框唯一且同宽、滑杆端点命中、键盘安全区、历史回看、通知合并和权限回执。结果 `/tmp/dsh-ui-final-verified.xcresult`、`/tmp/dsh-notice-final.xcresult`；真机连续手势和网络切换手感仍需安装验证。
- 最终顶部模糊调整后，3项受影响界面回归再次通过，结果 `/tmp/dsh-header-final.xcresult`。截图与日志保存在 `artifacts/ios/ui-refinement-20260918/`。


## 38. 2026-09-18 Remote 单一布局与原生交互细化
- 状态：[✓Build 107]2026-09-18 02:55 上传成功，Apple 已接收，等待处理；Delivery UUID：5059ee76-55af-41b4-984b-72d3c20a18f6。
- 首页底部改为原生 bottomBar 工具栏与透明系统材质，保留搜索和“图标 聊天”；用显式图文组合避免工具栏自动隐藏文字。
- 首页、会话等共用顶部背景改为 systemBackground 的50%透明色，删除自定义模糊层。代码块采用适配明暗模式的系统灰底；复制默认仅图标，点击后显示勾选和“已复制”。
- 模型气泡固定330×190pt，减少下方空白、增大模型与智能之间的间距。滑块只动画旋钮和填充，保持命中坐标稳定；档位改变触发 selection haptic，并适配减少动态效果设置。
- 向下按钮增加出现/消失过渡，点击时动画回到底部；回底动画期间暂停立即补钉，结束后按最新内容尺寸对齐。
- 删除经典首页、布局选项及持久化状态，根视图固定 Remote；删除思考旁本轮用量开关、状态、渲染及专属本地化字符串。设置分区统一系统分组灰底。
- 验证：Release 全套98项测试通过；滚动和首页改动后9项复验通过。模型列表和等级切换尺寸稳定，明暗模式截图已检查。触感实际强度仍需真机体验；无头模拟器键盘通过安全区变化验证。
- 最终原生首页图文组合复验1项通过（`/tmp/dsh-107-home-final.xcresult`），截图确认“聊天”文字完整显示。IPA、日志、截图和源码摘要：`artifacts/ios/remote-polish-build107-20260918/`；IPA SHA256：`a92faa908d8113b701cb6f58a8a2167b5c54a5c4935c1774f8e1332771e26bc3`。


## 39. 2026-09-18 首页宽搜索框
- 状态：[✓Build 108]2026-09-18 03:32 上传成功，Apple 已接收，等待处理；Delivery UUID：41c62a52-b742-4a39-9d31-cdd6056131d1。
- 首页底部搜索恢复占据“聊天”按钮左侧剩余空间的宽框，默认显示放大镜和“搜索聊天”；宽度取当前页面测量值，保留原生工具栏与透明材质。
- 原生 toolbar 搜索与聊天使用独立项目，搜索标签显式44pt高度，移除与系统工具栏冲突的 bordered 样式。Release 首页测试通过，实际截图确认宽搜索和聊天同时可见：`/tmp/dsh-108-home-native.xcresult`。
- IPA 与截图：`artifacts/ios/wide-search-build108-20260918/`。IPA SHA256：`5ee7aafc8acb15bca46938f30c2750ba2fb484f9f004e4b8a0f22b5e6990328e`。


## 40. 2026-09-18 远端项目、模式与会话同步（Build 109）
- 状态：[✓Build 109]2026-09-18 04:35（上海时间）上传成功，Apple 已接收，等待处理；Delivery UUID：acf41154-6065-433f-9943-ffc4a9b19801。Relay 已部署 schemaRevision 7 并通过健康检查，Mac Bridge/Connector 已重新构建并加载。
- 新建任务支持页面右滑返回，滑块操作不触发返回；首页保留原生透明宽搜索框。首页菜单新增“新建项目”，浏览配对 Mac 文件夹并通过原生 workspaceRegistry 创建工作区，空工作区也显示。
- 模式列表、默认模式和名称取自 Mac agentPresets；会话菜单改为远端重命名。空会话显示“新会话”，不持久化占位标题，发送后使用原生语意标题服务，并同步 Mac/网页标题变化。
- 远端工作区目录和名称为准，移除本地名称与隐藏覆盖。归档过滤按设备保留；请求响应按设备路由，刷新只接受最新请求，移除重复及不完整初始快照，避免旧信息闪现。
- 新增命令在客户端检查 Relay schemaRevision，旧服务下给出升级提示，保留已有会话通信。升级包：artifacts/server/DSH-ANYWHERE-RELAY-SERVER-20260918-r13-schema7.zip；部署说明：artifacts/server/RELAY-SCHEMA7-UPGRADE.md。保留服务器 .env 和数据卷。
- 验证：Release 全套104项 iOS测试通过，随后新增3项请求关联/失败状态测试并通过50项 EventStore 定向复验；后端90项测试及全部包类型检查通过。临时 Relay 实例 health 验证 schemaRevision 7。首页和新建任务截图已检查；真实远端联调与真机交互需部署后验证。

- 部署：服务器 `/opt/dsh-anywhere`，更新前完整源码与配对数据已备份至 `/opt/dsh-backup-109-20260918-042818`，旧镜像保留为 `relay-relay:before109`。保留原 `.env` 与数据卷，无需重新配对。
- Mac 启动路径修复：原 launchd 指向已不存在的 `/Users/aluvien/DSH-ANYWHERE`，现改为 `/Users/aluvien/Develop/App/DSH-ANYWHERE`；LaunchAgent 原件备份至 `/tmp/dsh-launchagents-before109`。原凭据配置不变。
- 实际联调：工作区列表正常，模式返回 standard/PTC/minimal/cordis 对应的 Mac 名称，未归档17条、已归档53条，现有手机请求继续正常处理。
- 真机后端兼容修复：macOS 原生目录选择器没有 list API，新增受认证保护的单层目录枚举，保持 Harness 排序、符号链接和1000项上限语义。插件43项测试通过；部署后实际主目录与项目子目录浏览均返回成功。
- 发布产物：`artifacts/ios/remote-workspaces-build109-20260918/`；IPA SHA256：`445a5db8a5984b3e88ac674821d4961112adb67d23be92c49a2d8bc95a216d6c`。包含签名、导出、上传日志和 iOS 源码摘要。


## 41. 2026-09-18 首页底部对齐与搜索展开（Build 110）
- 状态：[✓Build 110]2026-09-18 05:13（上海时间）上传成功，Apple 已接收，等待处理；Delivery UUID：88aa723b-c64f-4162-a5aa-8cf40c9c6184。13项 Release 界面回归通过。
- 首页搜索/聊天改为与会话输入框一致的底部 safeAreaInset，52pt控件高度、水平12pt、底部合计16pt；移除系统 bottomBar 额外边距与整条材质底，使用原生 TextField、Button 和独立 Liquid Glass。
- 点击搜索后显示宽胶囊搜索框（放大镜、输入光标）和右侧独立圆形关闭按钮。关闭清空搜索并恢复“聊天”，系统键盘安全区负责抬升，无手算键盘高度。
- 验证：实际搜索字段中心与会话编辑器中心对齐，搜索回车键、自动聚焦、320pt键盘安全区变化与关闭后恢复通过；现有会话滚动/模型面板回归通过，共13项。截图已检查，保存在 `artifacts/ios/home-search-build110-20260918/`。无头模拟器未显示实体软键盘，真实键盘交互仍需设备体验。
- IPA SHA256：`f1e4f23c0265308f0495614adc5bb6e1f5d7a1b15f3afe32ca8a155a383bd4f4`；发布日志和源码摘要与截图同目录保存。


## 42. 2026-09-18 聊天按钮还原与归档独立分类（Build 111）
- 状态：[✓Build 111]2026-09-18 05:34（上海时间）上传成功，Apple 已接收，等待处理；Delivery UUID：f5ec1234-fd4f-4cac-9ece-f351b62dbbf7。6项 Release 首页回归通过。
- 只调整用户指定内容：首页“聊天”恢复蓝底白色图标/文字，保留110搜索框与底部几何；选择项目文件夹隐藏点开头目录，目录名称和“上一级”使用正常文字色。
- 活跃项目列表和平铺列表始终排除归档项。“显示归档”入口不再依赖当前快照中已经有归档记录；展开后在下方独立“已归档”区按更新时间列出归档任务，含无项目任务，支持搜索、打开、取消归档及空态。远端查询与归档状态仍为数据来源。
- 验证：归档/活跃列表互斥、无项目归档保留、搜索与排序、隐藏目录过滤通过；上一版搜索中心线、键盘安全区移动与关闭恢复通过。浅/深色实际首页截图确认蓝底白字和独立归档分区。产物目录：`artifacts/ios/home-archive-build111-20260918/`。
- IPA SHA256：`5cd4da5dc17443e4cb9932bd89ad5261c2d59b16a61e2425afc40103cde1fffe`；签名、导出和上传日志及源码摘要保存于同一产物目录。


## 43. 2026-09-18 顶部磨砂、附件弹窗与真正流式输出（Build 112）
- 状态：[✓Build 112]2026-09-18 07:40（上海时间）上传成功，Apple 已接收，等待处理；Delivery UUID：a1f5b720-08e4-43d7-a41b-1323421413fd。Relay schemaRevision 8 已部署并通过健康检查，Mac Bridge/Connector 已重新构建和重启。
- 首页与会话顶部在内容经过时使用 regularMaterial 加18%页面底色，提高不透明度并真正模糊；无内容经过时保持页面原色，无灰色横块和分隔线。只在内容越过顶部留白后显示0.5pt细线，兼容系统/程序滚动及键盘安全区变化，其他页面样式保持。
- 删除首页中间的显示/隐藏归档点击条，右上角菜单继续控制独立“已归档”分类。
- 加号附件动作改为等待菜单消失后再展示系统照片/文件/相机选择器，避免同一presentation事务争用；运行中仍可暂存附件并按现有队列发送。
- 真正流式：Mac Bridge监听原生 agent/assistant-stream 的text-delta，不再把最终data.stream拼接成一次假增量。客户端通过session.open.streaming显式启用，Relay8以下自动回退普通历史请求。Connector仅向启用设备发送临时增量/丢弃事件，最终规范消息带replacesMessageId定向替换；旧客户端只收完整规范回复。重放保留设备隔离，临时消息在取消/重试时清理，历史回放不会复活临时气泡。
- 验证：iOS全套115项通过；最终顶部底色微调后15项界面复验通过。后端94项测试、全包构建和类型检查通过。真实Mac短回复收到6次增量、共110字符，首段早于最终完成101ms，临时ID与最终替换字段匹配；独立测试会话已归档。真实软键盘/照片选择交互仍需设备体验。
- 部署备份：服务器 `/opt/dsh-backup-112-20260918-073615`，旧镜像 `relay-relay:before112`；原.env和配对数据卷保留。升级包 `artifacts/server/DSH-ANYWHERE-RELAY-SERVER-20260918-r14-schema8.zip`。
- 产物：`artifacts/ios/streaming-build112-20260918/`；IPA SHA256：`6b58c9b733b110016e18e3da34f2b512ece803345c3f76e9b93493bebae5f5ca`。


## 44. 2026-09-18 修复历史记录路由到本机连接器而非手机
- 原因：session.open通过可信本机Connector凭据调用Bridge，历史publish沿用认证设备ID（dsh-anywhere-connector）；定向转发后Relay不会把这些历史事件送给实际请求的iPhone。Mac日志本身完整，列表与实时广播不受同一路径影响。
- 修复：Connector向Bridge open请求传入真实command.deviceId；Bridge仅允许可信Connector代指定历史接收方，普通直接连接设备仍只能读取发给自己的历史。历史开始/消息/工具/结束事件使用同一请求设备ID。
- 验证：修复前真实会话历史目标为dsh-anywhere-connector；部署后独立请求收到34条消息事件且目标统一为history-routing-probe。95项后端测试、全包build和diff检查通过。Mac Bridge/Connector已重启生效，无需新TestFlight客户端。


## 45. 2026-09-18 修复执行轨迹与编辑框状态不一致（Build 113）
- 原因：状态行只检查正在运行的工具与最后一条助手消息；工具结束后、空的工具调用消息或下一步思考期间会误回到“等待响应”。实时Bridge此前只投递正文增量，思考增量直到步骤完成才可见。
- 修复：状态按当前用户轮次的有效轨迹选择，保留工具结束后的最新活动，排除上一轮内容；实时思考沿用已有reasoning事件和临时消息替换机制，只向开启流式的设备发送。
- 顶部：根据补充要求，首页与会话页统一使用thinMaterial加10%页面底色，让经过的文字留下模糊轮廓；无内容经过时维持页面底色和无分隔线。
- 验证：106项iOS定向回归、97项后端测试及全包build通过；Mac Bridge/Connector已重启，真实会话历史仍完整。2026-09-18 09:54（上海时间）TestFlight 1.0(113)上传成功，Apple已接收，等待处理；Delivery UUID：f77f4260-ec85-4784-a392-c03d0a7e72ea。
- 发布产物：artifacts/ios/live-status-build113-20260918/；IPA SHA256：fdbe00a9f288edc7020885b0a7754f6653a382d936ad7daf98d5651eacea059f。无需更新Relay，schemaRevision保持8。

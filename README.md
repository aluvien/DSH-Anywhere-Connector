# DSH Anywhere

在 iPhone 上使用你 Mac 上的 [DeepSeek Harness](https://github.com/deepseek-ai)。会话、文件、
命令都留在本机，手机只是一个远程操作的窗口。

```
iPhone ──HTTPS/WSS──▶ Relay（你的服务器） ◀──WSS 出站── Mac Connector ──▶ 本机 Harness :3080
```

三个组件，各自解决一件事：

| 组件 | 位置 | 作用 |
|---|---|---|
| **Connector** | 你的 Mac | 主动向 Relay 建立**出站**连接，把本机 Harness 桥接出去 |
| **Relay** | 你的服务器 | 只做消息转发与设备鉴权，**不接触你的代码或密钥** |
| **Bridge** | 你的 Mac | 本机 Harness 实例（`dsh web`）+ DSH Anywhere 插件，提供 `:3080` 上的界面与 API |

**为什么是这个形状**：Mac 不需要公网 IP、不需要端口映射、不需要开放入站端口——它只
向外连。服务器上跑的 Relay 保存的是「哪台机器注册过、哪些设备配过对」，没有会话内容。

---

## 一、服务端部署（Relay）

### 前置条件

- 一台有公网 IP 的 Linux 服务器
- Docker 与 Compose 插件（`docker compose version` 能跑通）
- 一个已解析到该服务器的域名
- 一个 HTTPS 证书

> **必须用 HTTPS/WSS。** iOS 的 App Transport Security 会拒绝明文连接。证书推荐用
> Caddy 或 certbot 自动签发。

### 1. 准备代码与配置

上传发布包（`artifacts/server/DSH-ANYWHERE-RELAY-SERVER-*.zip`）到服务器并解压。
**包里没有顶层目录**，请直接解压到项目根目录：

```sh
APP=/opt/dsh-anywhere
mkdir -p "$APP"
ZIP=/opt/DSH-ANYWHERE-RELAY-SERVER-20260913-r7-clean.zip
unzip -o "$ZIP" -d "$APP"
```

生成 bootstrap token 并写入 `.env`：

```sh
cd "$APP/deploy/relay"
cp .env.example .env
printf 'DSH_RELAY_BOOTSTRAP_TOKEN=%s\n' "$(openssl rand -base64 48)" > .env
chmod 600 .env
```

> **发布包里不含 `.env`**，只含 `.env.example`，所以重复解压不会覆盖你的 token。
> 这个 token 是**注册新 Mac 的凭据**，泄露等于任何人都能往你的 Relay 上挂机器。

### 2. 构建并启动

```sh
docker compose --env-file .env -f compose.yaml up -d --build
docker compose --env-file .env -f compose.yaml ps
```

首次构建要拉基础镜像，需要几分钟。容器只监听 `127.0.0.1:8787`，**不直接对外**——
对外由 Nginx 反代。

### 3. Nginx 反向代理 + TLS

把 `deploy/relay/nginx-location.conf` 的内容放进你的 HTTPS `server` 块：

```nginx
location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;      # WebSocket 必需
    proxy_set_header Connection "upgrade";       # WebSocket 必需
    proxy_read_timeout 3600s;                    # 长连接必需
    proxy_send_timeout 3600s;
}
```

三个常被忽略的点：`Upgrade`/`Connection` 头不转发会导致**连接建立后立刻断开**；
`proxy_read_timeout` 太短会让空闲会话被掐断；`X-Forwarded-Proto` 影响 Relay 生成的链接。

### 4. 验证

```sh
curl -s https://你的域名/health
```

正常输出类似：

```json
{"ok":true,"version":1,"schemaRevision":3,"build":"2026-09-13",
 "deviceManagement":true,"oneTimePairingCodes":true}
```

| 字段 | 含义 |
|---|---|
| `schemaRevision` | **被转发的消息结构版本**。这个数字变了，说明必须重新部署 Relay，否则新客户端会发出旧 Relay 拒绝的消息 |
| `deviceManagement` | 是否提供设备列表与撤销路由 |
| `oneTimePairingCodes` | 是否提供一次性配对码 |

后两个是**能力标记**：只加路由、不改消息结构时不会升 `schemaRevision`，所以就靠它们
判断线上到底部署到哪一版。

### 升级

```sh
ZIP=/opt/DSH-ANYWHERE-RELAY-SERVER-<新版本>.zip
APP=/opt/dsh-anywhere

# 1) 先备份（token 与源码，出问题能退回去）
BACKUP="$APP/../dsh-relay-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -a "$APP/deploy/relay/.env" "$BACKUP/relay.env"
tar czf "$BACKUP/source.tar.gz" -C "$APP" \
  deploy packages package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json README.md

# 2) 覆盖并重建
unzip -o "$ZIP" -d "$APP"
cd "$APP/deploy/relay"
docker compose --env-file .env -f compose.yaml up -d --build

# 3) 验证
curl -s https://你的域名/health
```

**不需要重新配对。** 机器注册与设备令牌存在 Docker 卷 `relay-data`（容器内
`/data/registry.json`），`up -d --build` 不碰卷，所以 Mac 与手机的凭据都还在。

回滚：

```sh
cd "$APP" && tar xzf "$BACKUP/source.tar.gz"
cd "$APP/deploy/relay" && docker compose --env-file .env -f compose.yaml up -d --build
```

---

## 二、本地安装（Mac）

### 前置条件

- macOS
- **Node.js 22+**
- **pnpm**
- **DeepSeek Harness**：`dsh` 命令可用（`dsh --version`）
- 服务端已部署完成，并拿到 `DSH_RELAY_BOOTSTRAP_TOKEN`

### 1. 安装

**把这套代码放在 `~/DSH-ANYWHERE`，不要放在 `~/Documents`。** macOS 的隐私保护会阻止
launchd 执行「文稿」目录里的脚本，表现为服务反复启动失败。

```sh
git clone https://github.com/aluvien/DSH-Anywhere-Connector.git DSH-ANYWHERE
cd DSH-ANYWHERE
pnpm install
pnpm build
```

### 2. 注册这台 Mac 到 Relay

bootstrap token 通过环境变量传入，**不要写进任何文件**：

```sh
export DSH_ANYWHERE_RELAY_URL='https://你的域名'
export DSH_ANYWHERE_BOOTSTRAP_TOKEN='服务器 .env 里那个 token'
export DSH_ANYWHERE_MACHINE_NAME='My Mac'
./scripts/install-macos-bundle.sh
```

脚本会：

1. 调 `/v1/machines/register` 注册这台机器，取得 `machineId` / `machineToken` / `pairingSecret`
2. 把配置写到 `~/Library/Application Support/DSH Anywhere/connector.json`，权限 `0600`
3. 生成 `bridge.env`（Bridge 用它加载插件）
4. 注册两个 launchd 服务并启动

**这台 Mac 已经注册过时不要重复注册**，改用：

```sh
git pull
pnpm install && pnpm build
./scripts/install-macos-services.sh    # 只重装服务，不重新注册
```

### 3. 两个 launchd 服务

| 服务 | 作用 |
|---|---|
| `com.dsh-anywhere.connector` | 维持到 Relay 的出站连接，转发消息 |
| `com.dsh-anywhere.bridge` | 本机 Harness + 插件，监听 `127.0.0.1:3080` |

两个都是 `RunAtLoad` + `KeepAlive`：开机自启，崩溃自动拉起。

```sh
launchctl list | grep dsh-anywhere                     # 看状态与 PID
tail -f ~/Library/Logs/DSH\ Anywhere/connector.log     # Connector 日志
tail -f ~/Library/Logs/DSH\ Anywhere/bridge.log        # Bridge 日志
```

### 4. 验证

```sh
curl -s http://127.0.0.1:3080/dsh-anywhere/v1/health
node packages/connector/lib/cli.js status
```

### 5. 改了代码之后怎么让它生效

**这一点最容易搞错：三类改动需要三种不同的生效方式。**

| 改了什么 | 怎么生效 |
|---|---|
| iOS App（`ios/`） | 重新装 App，与 Mac 无关 |
| `packages/connector`、`packages/dsh-anywhere-plugin` | **重启对应服务** |
| `packages/protocol`（消息结构） | 重启服务 **且重新部署 Relay** |

```sh
pnpm build                                              # 先构建

launchctl kickstart -k gui/$(id -u)/com.dsh-anywhere.connector
launchctl kickstart -k gui/$(id -u)/com.dsh-anywhere.bridge
```

启动脚本带 `DSH_ANYWHERE_SKIP_BUILD=1`，**重启不会替你重新构建**，所以必须先 `pnpm build`。

**判断服务是否已经加载了新代码**——比较产物时间与进程启动时间：

```sh
stat -f "%Sm" packages/dsh-anywhere-plugin/lib/index.js                      # 产物时间
ps -p $(launchctl list | awk '/dsh-anywhere.bridge/{print $1}') -o lstart=   # 进程启动时间
```

产物比进程新，就说明进程还在跑旧代码。这一条能省下大量「我明明改了怎么没效果」的时间。

> 重启 Bridge 会**中断正在使用 `:3080` 的对话**。会话是持久化的，重开
> <http://127.0.0.1:3080> 即可恢复。

---

## 三、手机配对（扫码）

配对就是把三样东西交给手机：**Relay 地址**、**机器 ID**、**配对凭据**。三种方式，推荐
第一种。

### 方式 A：命令行生成一次性配对码（推荐）

在 Mac 上：

```sh
node packages/connector/lib/cli.js pair
```

输出：

```json
{
  "machineId": "machine_xxxxxxxx",
  "pairingCode": "ABCD2345",
  "expiresAt": 1757752800000,
  "pairingLink": "dshanywhere://pair?relay=https://...&machineId=...&code=ABCD2345"
}
```

然后在手机上打开 App → **Pair with Mac** → 手动输入机器 ID 与配对码。

**这个码 10 分钟内有效，且只能用一次。** 即使泄露也无法重放，更不能改投到别的机器。

### 方式 B：扫网页上的二维码（推荐给「就想扫一下」的情况）

在 Mac 上打开：

```
http://127.0.0.1:3080/dsh-anywhere/v1/pairing
```

页面上有一个二维码。**这个页面只监听本机（loopback），不要试图从外网打开它**——它存在
的意义就是「只有坐在这台 Mac 前面的人才能看到」。

然后在手机上：

1. 打开 DSH Anywhere
2. 点 **Scan pairing code**
3. 授权相机，对准 Mac 屏幕上的二维码

扫到即自动填入并开始配对。

> 页面上的凭据会**优先显示一次性码**（Connector 每 5 分钟换一个新码），并在下方标明
> 「还剩多少分钟」。只有在取不到新码时（例如 Relay 尚未支持该路由）才回退显示长期
> 密钥。**不要长期把长期密钥的二维码留在屏幕上。**

### 方式 C：手动输入

配对页可直接填：**Relay 地址**、**Machine ID**、**配对码或密钥**。

凭据只有一个输入框，按形状自动区分两者：8 位、且只含
`ABCDEFGHJKMNPQRSTUVWXYZ23456789`（去掉了 `0/O/1/I/L`，因为这个码要被人从屏幕上读出
来）的是一次性码，其余按长期密钥处理。两者长度不可能重叠，所以不需要你选模式。

### 二维码里是什么

二维码编码的是一个自定义协议的链接：

```
dshanywhere://pair?relay=<Relay 的 https 地址>&machineId=<机器 ID>&code=<一次性码>
```

令牌字段是 `code`（一次性码）或 `secret`（长期密钥）二选一。App 的扫码器解析这个格式，
非本协议的二维码会被忽略并继续扫描。

> **注意**：App 目前**没有向 iOS 注册 `dshanywhere://` 这个 URL scheme**，所以从 Safari
> 或信息里点这样的链接不会唤起 App。扫码必须**在 App 内**进行（即方式 B）。方式 A 与 C
> 不受影响。

### 配对之后

- 凭据存在 iOS 钥匙串；Mac 上的 `machineToken` 不动
- 一个 iPhone 可以配对**多台 Mac**，在「设置 → Machines」切换；「Devices」里可撤销其他设备
- 换手机或重装 App：重新走一次配对即可，不需要动 Mac
- 撤销某台设备：设置 → Devices → Revoke（立即生效，该设备的连接会被断开）

---

## 四、iOS App

### 自己构建

需要 Xcode，部署目标 **iOS 17.0**，Bundle ID `me.aluvien.DSHAnywhere`。

```sh
open ios/DSHAnywhere.xcodeproj
```

选择你的 Team 签名后 Run 到真机。**扫码需要真机**——模拟器没有可用相机（App 会提示改为
手动输入）。

### 界面语言

设置 → **语言**，可选**跟随系统**（默认）、简体中文、English。切换**立即生效**，不需要
重启 App。

### 当前功能

- 会话列表：按工作区分组、可折叠；新建会话时可选工作区
- 对话页：工具调用按**真实发生顺序**穿插在消息之间；一轮结束只留最终回答，思维链折叠
- Markdown 按块渲染：标题、代码块、列表、表格、引用
- 提问卡片可直接作答；审批可允许一次或拒绝
- 多机器切换、设备列表与撤销、图片与文件上传

---

## 代码结构

```
packages/
  protocol/             共享类型与 Zod 校验：被转发的每条消息都在这里定义
  relay-server/         服务器：注册、配对、设备管理、消息转发
  connector/            Mac 侧：出站连接、命令转发、CLI
  dsh-anywhere-plugin/  跑在 Harness 里的插件：会话与事件、配对页、提问
ios/DSHAnywhere/
  Core/                 协议、事件存储、网络、钥匙串（被 App 与测试共用）
  Features/             会话、对话、配对、设置
  App/                  应用外壳与全局状态
deploy/relay/           Dockerfile、compose、Nginx 片段
```

## 验证

```sh
pnpm -r test                              # TypeScript：protocol / connector / relay / plugin
cd ios && swift test --disable-sandbox    # Swift：协议、事件存储、markdown 解析
```

`RELAY_SCHEMA_REVISION` 定义在 `packages/relay-server/src/server.ts`。**改动
`packages/protocol` 里被转发的消息类型时必须同时提升它**，否则旧 Relay 会拒收新客户端
的消息，而错误信息只会说 `invalid_message`。

## 安全边界

- 服务器只保存机器与设备的**哈希**，没有会话内容、没有代码
- 所有凭据文件权限 `0600`；日志输出经过 `redactSecrets`
- 配对网页**只监听 loopback**，且校验 Host 头
- 一次性配对码：10 分钟有效、用后即废、绑定单一机器；签发权限仅限机器令牌
- 长期密钥仍可重复使用，**公开发布前应完全停用**；目前二维码已优先使用一次性码
- Relay 的持久化仍是单文件 JSON，适合单用户/小规模；账号体系与更大规模存储尚未实现

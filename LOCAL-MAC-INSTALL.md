# DSH Anywhere 本地 Mac 安装包

这个压缩包用于把本地 Bridge 和 Connector 放在 `~/DSH-ANYWHERE`，避免 macOS
阻止 launchd 执行 `~/Documents` 里的脚本。

当前修复包为 `DSH-ANYWHERE-MAC-LOCAL-20260914-r12.zip`。它必须替换旧的 r11，
因为附件上传超时和“图片有、文字丢失”的修复在本机 Connector/插件中。

## 已经注册过这台 Mac

不要直接解压到 `~`，否则会触发大量同名文件覆盖提示。升级时先解压到临时目录，再同步到固定安装目录：

```sh
staging=$(mktemp -d)
unzip -q /path/to/DSH-ANYWHERE-MAC-LOCAL.zip -d "$staging"
mkdir -p "$HOME/DSH-ANYWHERE"
rsync -a --exclude node_modules --exclude .git "$staging/DSH-ANYWHERE/" "$HOME/DSH-ANYWHERE/"
cd "$HOME/DSH-ANYWHERE"
./scripts/install-macos-bundle.sh
```

安装完成后检查：

```sh
curl -i http://127.0.0.1:3080/dsh-anywhere/v1/health
node packages/connector/lib/cli.js status
```

## 第一次注册新 Mac

不要把 bootstrap token 写进压缩包。先在当前终端设置变量，再执行安装：

```sh
export DSH_ANYWHERE_RELAY_URL='https://dsh.biaozhu.me'
export DSH_ANYWHERE_BOOTSTRAP_TOKEN='服务器 .env 中的 token'
export DSH_ANYWHERE_MACHINE_NAME='My Mac'
./scripts/install-macos-bundle.sh
```

脚本会把 `connector.json` 和 `bridge.env` 写入 macOS 的应用支持目录，并将权限设为
仅当前用户可读写。压缩包不包含任何 token、pairing secret 或服务器配置。

本机仍需预先安装：Node.js 22+、pnpm，以及 DeepSeek Harness 的 `dsh` 命令。
# Harness 桌面版（0.2.1）

桌面版默认使用系统分配的本机端口。Mac 安装脚本检测到已初始化的
`~/.dsh/profiles/desktop` 后，会安装桌面 Bridge 和独立 Connector，停用旧的
Web Bridge 启动服务。设置 `DSH_ANYWHERE_HOST=web` 可显式选择原来的 Web 方式。

Bridge 使用现有 `connector.json` 中的认证信息，并把实际地址原子写入同目录的
`bridge-endpoint.json`。Connector 在连接、重连、HTTP 请求和 `status` 检查时读取它；
显式设置 `DSH_ANYWHERE_BRIDGE_BASE_URL` 时优先使用指定地址。
手机仍然通过 Relay 连接，无需更新或重新配对。

更新本机安装：

```sh
./scripts/sync-mac-live.sh
```

脚本备份现有桌面安装、更新 Connector 并重启它。等待 Harness 中的任务结束后，
退出并重新打开 Harness，以加载新的 Bridge。不要将当前随机端口手工写死。
安装备份位于 `~/Library/Application Support/DSH Anywhere/backups/`。

检查实际连接地址：

```sh
node packages/connector/lib/cli.js status
```

新版 Gateway 的模式列表、命令和上传调用使用 Host 创建的 Peer；旧版继续使用原有调用格式。
读取失败会显示接口和 HTTP 状态，只有可能已执行的写入操作保留“结果未知”语义。

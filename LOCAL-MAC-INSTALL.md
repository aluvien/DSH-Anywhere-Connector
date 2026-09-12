# DSH Anywhere 本地 Mac 安装包

这个压缩包用于把本地 Bridge 和 Connector 放在 `~/DSH-ANYWHERE`，避免 macOS
阻止 launchd 执行 `~/Documents` 里的脚本。

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

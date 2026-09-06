# MAC Switch

面向个人使用的原生 macOS MAC 地址修改小工具。无需 Homebrew、Ruby 或 macchanger。

## 下载安装

从 [GitHub Releases](https://github.com/savvym/mac-switch/releases) 下载 `MAC-Switch-版本号-universal.dmg`。打开后将左侧的 **MAC Switch** 拖入右侧的 **Applications**，然后从“应用程序”启动。不要直接在只读 DMG 中运行。

发行包同时包含 Apple Silicon 和 Intel 架构，要求 macOS 13 或更高版本。安装不会删除已有地址列表。

**当前发行包未经过 Apple Developer ID 签名和公证。** 首次运行可能被 macOS Gatekeeper 提示或拦截；确认下载来源可信后，按“系统设置 → 隐私与安全性”中的提示处理。请不要关闭全局安全保护。发布页同时提供 SHA-256 校验文件。

## 使用

打开 `MAC Switch.app`，选择网卡，填写目标地址，点击“应用修改”。确认后由 macOS 请求管理员授权；本工具不接收或保存密码。

支持冒号、连字符和连续 12 位十六进制地址。自动排除全零、组播及广播地址。随机地址使用本地管理的单播地址。

## 每设备地址列表

- 每张网卡独立保存地址列表，按系统报告的硬件地址识别。改址前的设备安全核对仍使用当前设备实例，防止接口名被复用。
- 首次读取到的有效地址自动置顶并标记“原始”，不会随之后的修改覆盖。它不一定是出厂地址，也可能是当时生效的系统私有地址。
- 用加号添加地址和备注；相同地址自动去重。支持搜索、复制、修改备注和删除，原始地址与当前地址不可删除。
- 实际读取过的地址自动进入历史，成功改址另记使用时间。失败且未生效的目标不会被当作已使用地址，除非手动添加。
- 每行右侧的切换按钮直接进入该地址的修改确认，无需复制粘贴；仍需管理员授权，并可能断网。
- “恢复原始地址”使用该设备持久保存的首次记录。恢复数值不保证解除系统的“Wi-Fi 地址已由用户配置”状态。
- 数据保存在 `~/Library/Application Support/MACSwitch/addresses.json`，仅本机存储，不上传。升级和重启工具后保留。文件损坏时不会静默覆盖。
- 无法取得系统硬件地址时，只按当前运行实例保存，避免误把其他设备认成旧设备。若驱动改变其报告的硬件身份，列表可能被视为新设备。
- 旧版未写入磁盘的完整历史无法自动追溯。

## 范围与限制

- 主要面向 USB 有线网卡。直接执行 macchanger 有线分支使用的 `/sbin/ifconfig <interface> ether <address>`，不是 macchanger 的完整移植。
- Wi-Fi 默认直接改址；出现 `Can't assign requested address` 时，可以手动勾选“重启 Wi-Fi 后修改”。确认后先关闭再打开 Wi-Fi，再尝试改址，当前连接会中断。此模式仍不保证所有驱动可用。
- 重启模式要求 Wi-Fi 原本已打开。失败时会尝试重新打开 Wi-Fi，并提示恢复失败；不保证自动重新连上原网络。不会关闭系统的“私有 Wi-Fi 地址”设置。
- 不自动安装驱动、不修改系统安全设置、不常驻后台、不设置开机自动修改。
- 命令执行后读取实时地址验证，不能仅凭命令退出码宣告成功。此验证不等于已通过抓包验证实际发出的数据帧。
- 修改可能导致断网，MAC 绑定网络可能需要重新认证。请勿与同一网络中的其他设备使用相同地址。
- 重新插拔或重启后地址可能恢复。
- 界面中的“已启用”指接口启用状态，不代表网线连接或互联网可用。
- 使用 macOS 系统授权；构建产物使用临时签名，尚未接入 Apple Developer ID 签名及公证。
- 本地默认按当前机器架构编译；GitHub Releases 的 DMG 为双架构通用版本，最低 macOS 13。

## 构建与验证

安装 Xcode Command Line Tools 后，在本目录运行：

```bash
bash build.sh
```

双架构构建可以使用 `ARCHS="arm64 x86_64" APP_OUTPUT="dist/MAC Switch.app" bash build.sh`。测试在构建机器的原生架构执行，应用和改址辅助组件都编译并校验两个架构。

构建会先运行地址校验、随机生成、命令注入防护、错误映射、Wi-Fi 重启模拟、只读网卡发现、设备列表隔离、去重、初始地址保护和持久存储测试。不会修改任何网卡。

只读查看当前接口：

```bash
"MAC Switch.app/Contents/MacOS/MACSwitch" --inspect
```

演示界面（不会执行修改）：

```bash
open "MAC Switch.app" --args --demo
```

默认演示数据仅存在内存。测试重启持久化时，可在 `--demo` 后添加 `--demo-store /tmp/macswitch-demo/addresses.json`，不会使用真实地址库。

## 本地打包 DMG

在 macOS 上安装 Python 3.11+ 和 Xcode Command Line Tools 后运行：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r scripts/requirements-dmg.txt
.venv/bin/python -m unittest discover -s scripts -p 'test_*.py' -v
.venv/bin/python scripts/package_dmg.py
```

产物位于 `dist/`，包含通用应用、DMG 和 `.sha256` 文件。使用 `dmgbuild` 生成固定图标位置、背景和 `/Applications` 快捷方式，不依赖 Finder 自动操作。脚本会挂载成品检查应用签名、双架构、快捷方式及窗口布局，验证通过才输出最终 DMG。不会读取或打包用户的 MAC 地址库。

## GitHub Actions

- 推送 `main` 或提交 Pull Request：自动测试并生成 DMG，可在 Actions 的 Artifacts 中下载，保留 14 天。
- 推送 `v*` 版本标签：构建通过后自动创建 GitHub Release，附上 DMG、校验文件和发布说明。
- 手动运行 `Build and Release DMG`：仅构建产物，不创建 Release。
- 标签必须与 `Info.plist` 的 `CFBundleShortVersionString` 完全对应，例如 `v1.2.1` 对应 `1.2.1`。不匹配会失败，不会发布。

发布新版本时先更新 `Info.plist` 中的版本号和递增的 `CFBundleVersion`，提交后再推送标签。例如已将版本更新到 `1.2.1` 后：

```bash
git tag v1.2.1
git push origin main v1.2.1
```

工作流使用 GitHub 自带的 `GITHUB_TOKEN`，只有发布任务获得 `contents: write` 权限，无需额外 PAT。不要复用或强制移动已发布的标签；已有 Release 不会被工作流覆盖。Developer ID 签名和公证需要另外配置 Apple 开发者证书及公证凭据，当前工作流不包含这一步。

源代码参考：[acrogenesis/macchanger](https://github.com/acrogenesis/macchanger)。本工具独立实现，不包含其脚本。

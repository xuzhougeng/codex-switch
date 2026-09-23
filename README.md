# Codex Switch

本地 Codex 账号管理器。Windows 使用 **WinUI 3 / C#**，macOS 使用 **SwiftUI / Swift**，Linux 使用终端界面管理 mihomo。原 PowerShell 命令行继续保留。

当前版本 **0.1.0**：[下载](https://github.com/xuzhougeng/codex-switch/releases/tag/v0.1.0)

| 包 | 平台 |
| --- | --- |
| `CodexSwitch-0.1.0-windows-x64.zip` | Windows x64 |
| `CodexSwitch-0.1.0-macos-arm64.zip` | macOS Apple Silicon |
| `CodexSwitch-0.1.0-linux-x64.tar.gz` | Linux x64，含 mihomo |
| `CodexSwitch-0.1.0-linux-arm64.tar.gz` | Linux arm64，含 mihomo |

原生版采用松绿色账号卡片、紧凑侧栏和账号库，提供搜索、保存、切换、清空、移除、异步浏览器登录和取消登录；跟随系统浅色/深色主题。Windows 窄窗口自动收起侧栏文字，macOS 保留原生窗口、确认框及 Command-R 快捷键。清空和移除操作放在对应账号的更多菜单中。

## Windows

支持 Windows 10 2004 及以上、Windows 11；构建需要 .NET 8 或更新 SDK。NuGet 自动还原 Windows App SDK 和 Windows SDK 构建工具。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1
.\codex-switch.cmd
```

输出：`dist/windows-x64/CodexSwitch.Windows.exe`。发布目录包含 .NET 和 Windows App SDK 运行时，分发时请保留整个目录。ARM64 构建：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1 -Architecture arm64
```

安装到当前用户目录并加入 PATH：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

双击 `codex-switch.cmd` 默认启动原生版；未构建时会显示构建命令。旧界面仍可通过 `powershell -ExecutionPolicy Bypass -File codex-switch.ps1 gui` 启动。命令行兼容 `codex-switch.cmd list|add|switch|remove`。

## Linux

Linux 用终端界面管理 mihomo，形态接近 [ShellCrash](https://github.com/juewuy/ShellCrash) 的纯净模式：启动、停止、重启、节点、端口、日志、内核和用户级开机启动。它不改防火墙，也不做透明代理。

核心链路按端口直接接好。Codex / Claude 走 HTTP 端口，AI 目标在本机限流后，经 mihomo 的一跳 SOCKS 出去，再进美国家宽。限流跑在 `codex-switch serve` 进程里，不生成、也不再执行 `socks-limiter.py` 或 `start-ai.sh`。

官方 mihomo 内核放在 `src/Linux/kernel/`（当前 v1.19.31，GPL-3.0）。启动时优先用这份内核；配置里填了绝对路径时才改用别的。

```bash
bash scripts/build-linux.sh
./dist/linux-x64/codex-switch
./dist/linux-x64/codex-switch start
./dist/linux-x64/codex-switch status
```

构建需要 .NET 8。发布结果是自包含的 `linux-x64` 目录，内核在 `kernel/linux-x64/mihomo`。开发时也可以：

```bash
~/.dotnet/dotnet run --project src/Linux/CodexSwitch.Linux.csproj
```

默认端口是 HTTP `1990`、一跳 SOCKS `1991`、外部控制 `127.0.0.1:1993`、限流 `127.0.0.1:1994`。客户端使用：

```bash
export http_proxy=http://127.0.0.1:1990
export https_proxy=http://127.0.0.1:1990
```

配置仍在 `~/.codex/codex-switch/clash-proxy.json`。mihomo 只读运行时写出的 `clash/ai.yaml`。退出菜单后服务继续运行；`codex-switch stop` 或菜单里的停止会关掉它。开机启动写的是 `~/.config/systemd/user/codex-mihomo.service`。

## macOS

支持 macOS 13+，需要 Xcode 15+ 或相应 Swift 工具链。在 Mac 上运行：

```bash
bash scripts/build-macos.sh
open "dist/macos/Codex Switch.app"
```

脚本先执行 Swift 测试，再生成当前 Mac 架构的 `.app` 并添加本地 ad-hoc 签名。对外分发仍需要 Developer ID 签名与 Apple 公证。开发时可在 Xcode 打开 `src/macOS/Package.swift`，或运行 `cd src/macOS && swift run`。

**验证边界：SwiftUI 已通过 GitHub Actions 的 macOS 15 编译、存储层测试和 `.app` 打包。尚未完成 Mac 界面实测和真实浏览器登录验证。** Windows 版已在本机启动并使用虚拟账号验证搜索与切换。

## 账号数据与行为

两端遵循同一文件协议，默认位置是 `~/.codex`，原生版尊重 `CODEX_HOME`。兼容旧版 `codex-switch/accounts.json` 及按邮箱保存的 `auth.json` 快照，无需转换已有数据。旧 PowerShell CLI 仍固定使用用户目录下的 `.codex`。

```text
~/.codex/
  auth.json
  codex-switch/
    accounts.json
    <email>/auth.json
    backups/
```

- **登录新账号**：调用已经安装的 Codex CLI，在独立 `CODEX_HOME` 中执行浏览器登录，并显式使用文件凭据存储。成功后保存新账号并更新当前登录。失败、取消、超时保留原账号；CLI 输出不会写入日志。
- **切换**：验证目标快照身份，保存当前最新凭据并备份，再原子替换当前 `auth.json`。
- **清空登录**：先保存和备份，再移除当前 `auth.json`。
- **移除保存的账号**：把快照归档到备份，移除索引，不清空当前登录。备份仍包含登录凭据。
- **额度**：旧版从最近会话日志读取额度，但日志无法可靠归属到当前账号；新版显示“额度暂未核验”，避免显示错误账号的数字。
- **同一邮箱的多个工作区**：保持旧版按邮箱存储的约束；身份不同的覆盖会被拒绝。

## 双跳代理

原生界面增加「双跳代理」页，用来保存中转节点和美国家宽 SOCKS5，并启动 mihomo + 本机限流。

- 配置保存在 `~/.codex/codex-switch/clash-proxy.json`（含家宽凭据，权限 0600）
- 生成文件在 `~/.codex/codex-switch/clash/`：`ai.yaml`、`socks-limiter.py`、`socks-limiter.json`
- 启动后 Codex 走 `http://127.0.0.1:1990`。请自行设置 `http_proxy` / `https_proxy`，或在系统代理中指向该端口
- Windows 和 macOS 需要本机已安装 `mihomo` 和 `python3`（Windows 为 `python`）。也可在页面填写绝对路径。Linux 终端版自带 mihomo，并在进程内做限流

限流器把打向家宽的新建连接排队，避免 Claude / Codex 把住宅 SOCKS5 打满后出现中途断流。

切换完成后，需要用户完全退出并重新打开 Codex。工具不会关闭、启动或修改 Codex / ChatGPT 桌面应用，也无法保证桌面应用的独立登录缓存会立即接受文件切换。macOS 钥匙串等系统凭据存储不在本工具管理范围内；采用系统凭据存储时，请先确认 Codex 配置为文件存储。工具不会自动改写该配置。

快照和备份含敏感凭据，不要上传、分享或放入云同步目录。macOS 新凭据文件使用 `0600`，新存储目录使用 `0700`；Windows 使用当前用户目录继承的文件权限。原生操作有独占锁，但旧 CLI 和 Codex 自身不遵循此锁，请避免同时切换或写入登录文件。

## 开发与验证

应用图标的矢量源文件是 `assets/app-icon.svg`，PNG 和多尺寸 ICO 已随源码提供。修改后可安装 ImageMagick 并运行 `scripts/build-icons.ps1` 重新导出。Windows 将 ICO 嵌入程序并设置窗口图标；macOS 打包脚本使用系统工具生成 ICNS。

```powershell
dotnet run --project tests/Core.Tests/Core.Tests.csproj -c Release
```

Windows 集成测试使用临时目录和虚拟凭据，覆盖切换、最新凭据保留、备份、损坏文件、身份冲突、路径校验、并发锁，以及模拟 CLI 成功/失败/取消。不会操作真实账号。

[Native builds](https://github.com/xuzhougeng/codex-switch/actions/workflows/build.yml) 在每次推送时分别构建 Windows 和 macOS，并提供对应的下载产物。macOS 产物包含本地 ad-hoc 签名，不是已公证的发行版。

隔离界面预览（目标目录必须尚不存在）：

```powershell
dotnet run --project tests/Core.Tests/Core.Tests.csproj -c Release -- --seed-demo test-results/preview-home
$env:CODEX_HOME = Join-Path $PWD 'test-results/preview-home'
& .\dist\windows-x64\CodexSwitch.Windows.exe
```

`src/Core` 是 Windows 的无 UI 存储层，Linux 终端版也用它生成双跳配置并在进程内限流。`src/Windows` 是 WinUI 3 界面；`src/Linux` 是终端管理界面；`src/macOS/Sources/CodexSwitchCore` 是遵循相同协议的 Swift 存储层；`src/macOS/Sources/CodexSwitch` 是 SwiftUI 界面。账号界面各自使用原生运行时，不依赖 PowerShell 或 WebView。

# Codex Switch

本地 Codex 账号管理器。Windows 使用 **WinUI 3 / C#**，macOS 使用 **SwiftUI / Swift**。原 PowerShell 命令行继续保留。

原生版提供当前账号卡片、搜索、账号列表、保存、切换、清空、移除、异步浏览器登录和取消登录；跟随系统浅色/深色主题。Windows 使用 Mica 和原生对话框，macOS 使用侧栏、工具栏、原生确认框及 Command-R 快捷键。

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

## macOS

支持 macOS 13+，需要 Xcode 15+ 或相应 Swift 工具链。在 Mac 上运行：

```bash
bash scripts/build-macos.sh
open "dist/macos/Codex Switch.app"
```

脚本先执行 Swift 测试，再生成当前 Mac 架构的 `.app` 并添加本地 ad-hoc 签名。对外分发仍需要 Developer ID 签名与 Apple 公证。开发时可在 Xcode 打开 `src/macOS/Package.swift`，或运行 `cd src/macOS && swift run`。

**验证边界：macOS 源码、测试和打包脚本已提供；本次开发环境是 Windows，尚未在 Mac 上编译、验证界面或完成真实登录。**

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

切换完成后，需要用户完全退出并重新打开 Codex。工具不会关闭、启动或修改 Codex / ChatGPT 桌面应用，也无法保证桌面应用的独立登录缓存会立即接受文件切换。macOS 钥匙串等系统凭据存储不在本工具管理范围内；采用系统凭据存储时，请先确认 Codex 配置为文件存储。工具不会自动改写该配置。

快照和备份含敏感凭据，不要上传、分享或放入云同步目录。macOS 新凭据文件使用 `0600`，新存储目录使用 `0700`；Windows 使用当前用户目录继承的文件权限。原生操作有独占锁，但旧 CLI 和 Codex 自身不遵循此锁，请避免同时切换或写入登录文件。

## 开发与验证

```powershell
 dotnet run --project tests/Core.Tests/Core.Tests.csproj -c Release
```

Windows 集成测试使用临时目录和虚拟凭据，覆盖切换、最新凭据保留、备份、损坏文件、身份冲突、路径校验、并发锁，以及模拟 CLI 成功/失败/取消。不会操作真实账号。

隔离界面预览（目标目录必须尚不存在）：

```powershell
dotnet run --project tests/Core.Tests/Core.Tests.csproj -c Release -- --seed-demo test-results/preview-home
$env:CODEX_HOME = Join-Path $PWD 'test-results/preview-home'
& .\dist\windows-x64\CodexSwitch.Windows.exe
```

`src/Core` 是 Windows 的无 UI 存储层；`src/Windows` 是 WinUI 3 界面；`src/macOS/Sources/CodexSwitchCore` 是遵循相同协议的 Swift 存储层；`src/macOS/Sources/CodexSwitch` 是 SwiftUI 界面。两端复用数据协议和行为约定，各自使用原生运行时，不依赖 PowerShell 或 WebView 渲染界面。

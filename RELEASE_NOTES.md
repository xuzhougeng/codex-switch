## 更新内容

- macOS 新增「流量」页：实时速率、活动连接、会话累计三组指标，连接列表显示目的地、命中规则、完整出口链路、来源进程、TCP / UDP、连接时长与单连接速率，支持按目标域名和按出口节点聚合，可筛选全部 / 代理 / 直连 / 拦截并搜索，右键可关闭单条连接或拷贝域名；代理停止后会话累计仍可查看，可一键清空。
- macOS 日志页改为结构化渲染：按级别着色，自动隐藏 mihomo 连接行里的本机回环前缀并高亮命中的出口，新增关键词筛选，行数从 300 提升到 500。
- macOS 提供独立的 mihomo 代理管理，按 AI 工具、GitHub / 开发、家宽中转分别管理出口，并保留账号切换功能。
- macOS 与 Linux TUI 新增分流规则页面，提供智能分流、仅 AI 代理、全站代理三种预设，可修改各类用途的出口。
- 自定义规则支持添加、编辑、排序、停用、导入和预览；TUI 还支持导出与 `rules show / check / apply / import / preset` 命令。
- GitHub / Docker 默认优先可用香港节点，失效时自动回退；补齐 GitHub API、静态资源和下载域名的分流。
- 家宽双跳改为可选。启用时 Claude / Anthropic 使用家宽，未启用时沿用 AI 单跳出口。
- 规则可在服务运行中校验并应用，无需重启代理。无效规则不会替换正在运行的配置；切换预设保留自定义规则，旧配置继续兼容。
- macOS 支持保存多个 SOCKS5 出口、链路测试、系统代理恢复、连接与日志查看和登录自启动；Linux 保留端口、限流、内核和 systemd 管理。

## 下载与使用

| 包 | 平台与启动方式 |
| --- | --- |
| `windows-x64.zip` | Windows 10 2004+ / 11，解压后保留整个目录，运行 `CodexSwitch.Windows.exe` |
| `macos-arm64.zip` | macOS 13+，Apple Silicon，打开 `Codex Switch.app` |
| `linux-x64.tar.gz` | Linux x64，解压后运行 `codex-switch` |
| `linux-arm64.tar.gz` | Linux ARM64，解压后运行 `codex-switch` |

各下载文件名前缀包含本次版本号；`SHA256SUMS` 提供校验值。macOS 与 Linux 包内包含 mihomo v1.19.31，以及上游许可证和来源说明。

macOS 采用本地 ad-hoc 签名，未经 Apple 公证。首次使用请将 App 放在固定位置后再启用登录自启动。

自定义规则支持域名、IP 网段、进程、目标端口及 TCP / UDP；暂不支持 `RULE-SET` 和逻辑组合。端口、订阅节点和家宽服务的修改仍需重启代理。

Linux 客户端默认代理入口：

```bash
export http_proxy=http://127.0.0.1:1990
export https_proxy=http://127.0.0.1:1990
```

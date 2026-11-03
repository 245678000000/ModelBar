# ModelBar for Windows

在系统托盘统一管理你的 API 接口，一键同步到官方支持自定义接口的工具。功能和 Mac 版相同，用 C# 和 WPF 实现。

不修改任何工具的程序文件，只写它们公开的配置文件，所以工具更新不会影响使用。

## 安装

解压 `ModelBar-win-x64.zip`（ARM 电脑用 `ModelBar-win-arm64.zip`），运行 `ModelBar.exe`。不需要安装 .NET，也不需要管理员权限。

程序没有数字签名，第一次运行时 Windows 可能提示“已保护你的电脑”，点“更多信息”再点“仍要运行”。

运行后图标在任务栏右下角的托盘里，可能被收在“^”隐藏区。再次运行 `ModelBar.exe` 会直接弹出面板。

## 使用

1. 点托盘图标，选“添加接口”，填入 Base URL 和 API Key。添加后会自动拉取模型并测试连接。
2. 选模型和推理档位。
3. 在“同步到”里打开要用的工具。

关闭工具的开关会恢复它原来的配置。退出 ModelBar 后，工具继续按当前配置运行。

## 支持的工具

| 工具 | 写入的配置 | 接口要求 |
|---|---|---|
| Claude Code | `%USERPROFILE%\.claude\settings.json` | Anthropic；只有 Chat 时需开启本机转换 |
| Codex CLI | `%USERPROFILE%\.codex\config.toml` | Responses；只有 Chat 时需开启本机转换 |
| opencode | `%USERPROFILE%\.config\opencode\opencode.json` | Chat Completions 或 Responses |
| pi | `%USERPROFILE%\.pi\agent\models.json`、`settings.json` | Chat Completions 或 Responses |
| Grok | `%USERPROFILE%\.grok\config.toml` | Chat Completions |
| Factory Droid | `%USERPROFILE%\.factory\settings.json` | Chat Completions 或 Responses |
| Kilo Code | `%USERPROFILE%\.config\kilo\kilo.json` | Chat Completions 或 Responses |

## 和 Mac 版的区别

| 功能 | Mac | Windows |
|---|---|---|
| 常驻入口 | 菜单栏 | 系统托盘 |
| 保存 Key | 钥匙串 | 凭据管理器 |
| 转换服务常驻 | launchd | 自带守护进程，登录时由注册表启动项拉起 |
| Key 文件权限 | 0600 | 只有当前用户和系统账户能读的 NTFS 权限 |
| 工具读取 Key | `/bin/cat` | 自带的 `ModelBarGateway.exe --print-file`，不依赖 cmd 或 Git Bash |

## 数据和安全

- 设置、备份和日志都在 `%APPDATA%\ModelBar`。
- 主密钥存在 Windows 凭据管理器。工具读不了它，所以当前接口的 Key 会另存一份只有你的账户能读的文件，切换接口或停用全部工具时自动删除。
- 工具的配置文件里只写这个文件的路径，不写 Key 本身（Factory Droid 除外，它只接受明文）。
- 打开 Claude Code 的开关时，原来的 `ANTHROPIC_AUTH_TOKEN` 会移到 ModelBar 的设置文件里，关闭开关时放回。
- 本机转换只监听 `127.0.0.1`，请求必须带本机访问令牌，并校验 Host。日志不记录 Key 和请求内容。

## 卸载

先在面板里关掉所有工具的开关，这会恢复它们原来的配置并移除转换服务。然后退出 ModelBar，删除解压的文件夹和 `%APPDATA%\ModelBar`。开启过“开机时自动启动”的话，先在“通用”里关掉。

## 开发

需要 .NET 10 SDK。Mac 和 Linux 上也能编译和打包。

```bash
dotnet test tests/ModelBar.Core.Tests
```

```bash
./scripts/publish.sh
```

- `src/ModelBar.Core`：跨平台的核心逻辑。
- `src/ModelBar.Gateway`：本机转换服务。
- `src/ModelBar.App`：托盘和窗口，只能在 Windows 上运行。
- `tools/ModelBar.DevCli` 和 `tests/smoke/smoke.py`：不开界面，用真实 Agent 跑端到端测试。
- `.github/workflows/windows.yml`：在真实的 Windows 上跑测试和端到端测试，并渲染界面截图。

把环境变量 `MODELBAR_HOME` 指向一个空目录，应用的所有读写都会限制在那个目录里，不碰真实配置和凭据。

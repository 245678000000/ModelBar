# ModelBar

在 Mac 菜单栏统一管理你的 API 接口，一键同步到官方支持自定义接口的工具。

不修改 Cursor 或任何工具的程序文件，只写它们公开的配置文件，所以工具更新不会影响使用。

## 安装

运行 `./scripts/package-dmg.sh` 生成 `dist/ModelBar.dmg`，把里面的 ModelBar 拖进“应用程序”，然后打开。它只出现在菜单栏，不占程序坞。

如果菜单栏太挤、看不到图标，再次打开 ModelBar 就会直接弹出面板。

## 使用

1. 点菜单栏图标，选“添加接口”，填入 Base URL 和 API Key。添加后会自动拉取模型并测试连接。
2. 选模型和推理档位。
3. 在“同步到”里打开要用的工具。

之后切换接口、模型或档位，已打开的工具都会立即同步。退出 ModelBar 后，工具继续按当前配置运行。

## 支持的工具

| 工具 | 在哪里用 | 写入的配置 | 接口要求 |
|---|---|---|---|
| opencode | 终端 | `~/.config/opencode/opencode.json` | Chat Completions 或 Responses |
| Codex CLI | 终端 | `~/.codex/config.toml` | 必须支持 Responses |
| Kilo Code | Cursor / VS Code 扩展 | `~/.config/kilo/kilo.json` | Chat Completions 或 Responses |

其他工具（比如 Cline）可以在接口详情页拷贝 Base URL、模型名和 Key，手动填入。

## 限制

- **Cursor 自带的 Agent 面板和 Tab 补全用不了这些接口。** 在 Cursor 里要用 Kilo Code 扩展的面板。
- **接口不支持 Responses 时，Codex 用不了。** ModelBar 不会写入，Codex 保持原来的配置。
- **推理档位能否生效取决于服务商。** ModelBar 负责把 `reasoning_effort` 发出去。
- **Kilo Code 还没有用真实扩展测试过。** 配置格式来自官方文档。
- 其他也会改 `~/.codex/config.toml` 的工具可能和 ModelBar 互相覆盖。ModelBar 发现配置被改后会提示，不会自动改回去。

## 数据和安全

- 主密钥存在系统钥匙串。
- 工具读不了钥匙串，所以当前接口的 Key 会另存一份权限 0600 的文件，切换接口或停用全部工具时自动删除。如果某个工具还停留在上一个接口，它的 Key 文件会保留到下次全部同步成功。
- 工具的配置文件里只写这个文件的路径，不写 Key 本身。
- 每次改配置前自动备份，每个工具保留最近 10 份，位置是 `~/Library/Application Support/ModelBar/backups`。
- 关闭工具的开关会恢复它原来的配置。
- “测试连接”会发送两条极短的真实请求，可能产生极少量费用。除此之外，ModelBar 只在你操作时访问你填写的接口，不连接其他服务器。

opencode 的后台服务不会自动读取新配置，所以切换时如果它正在运行，ModelBar 会重启它，进行中的会话可能被打断。

## 从源码构建

只需要 Command Line Tools，不需要完整的 Xcode。

```bash
./scripts/build-app.sh
```

```bash
./scripts/package-dmg.sh
```

```bash
./scripts/test.sh
```

运行 `MODELBAR_KEYCHAIN_TEST=1 ./scripts/test.sh` 会额外测试真实钥匙串，结束后自动删除测试条目。

把环境变量 `MODELBAR_HOME` 指向一个空目录，应用的所有读写都会限制在那个目录里，不碰真实配置和钥匙串，适合调试。

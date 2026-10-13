# DeepSeek 消耗 · 维护与交接文档

> 版本：`1.1.0`（菜单栏卡片 `deepseek-usage-panel.js` 为 `1.0.12`）
> 平台：Windows 10 / 11，仅在 Codex 桌面端（商店版 MSIX）+ Codex 内置浏览器登录 DeepSeek 的组合上验证。
> 安装位置：`%LOCALAPPDATA%\Programs\DeepSeekUsage`

## 1. 它是什么

在 Codex 顶部菜单栏插入「消耗」按钮，展示 DeepSeek 充值余额与今日消费。
不依赖 Codex++：通过本机 CDP 调试端口把卡片脚本注入 Codex 渲染进程，数据由独立的 PowerShell 助手采集后推送。

## 2. 三个进程与各自职责

| 组件 | 由谁启动 | 职责 |
|---|---|---|
| `mcp-server.ps1` | Codex（按 `config.toml` 的 MCP 注册） | 拉起助手；检测缺少调试端口时排队自动修复 |
| `deepseek-usage-helper.ps1` | `mcp-server.ps1` | 取余额 / 取今日消费；通过 CDP 注入卡片并推送数据 |
| `auto-restart.ps1` | 计划任务（由 `mcp-server.ps1` 创建并运行） | 等若干秒后重启 Codex 并带上调试端口 |
| `deepseek-usage-panel.js` | 由助手注入页面 | 只负责界面：菜单栏按钮、卡片、刷新 |

核心原则：页面脚本不取任何数据；取数与凭证解析全部在助手进程里完成。

## 3. 关键流程

1. Codex 启动 → 按 `[mcp_servers.deepseek_usage]` 拉起 `mcp-server.ps1`。
2. 启动器拉起助手（隐藏窗口），助手开始每 `pollSeconds` 秒轮询调试端口。
3. 助手通过 CDP 找到 `app://` 主窗口（排除 `avatar-overlay`），若页面没有当前版本 UI 就注入 `deepseek-usage-panel.js`，并调用 `window.__dsUsageApply(payload)` 推数据。
4. 启动器同时检查端口：缺失则排队自动修复（见第 4 节）。
5. Codex 退出 → MCP 连接断开 → 启动器回收助手并退出。

## 4. 自动修复（为什么需要它）

菜单栏卡片依赖 CDP 端口，而商店版 Codex 有单实例锁：**已经运行的实例不会接受 `--remote-debugging-port`**。因此必须在启动时带上该参数，也就是需要重启一次 Codex。

自动修复流程：`mcp-server.ps1` 检测端口缺失 → 记状态（会话 / 冷却 / 失败计数）→ 通过计划任务派生 `auto-restart.ps1` → 等待 `autoRestartDelaySeconds` → 复查端口 → 调用 `launch-codex.ps1` 完成重启。

护栏（都在 `config.json`）：`autoRestart` 总开关、`autoRestartDelaySeconds`、`autoRestartCooldownMinutes`；每个会话只尝试一次，连续失败 2 次自动停用（写 `auto-restart.json`）。

## 5. 踩坑记录（重要，别再踩一遍）

### 5.1 进程无法“活过 Codex”

Codex 把 MCP 服务放在**作业对象（Job Object）**里，Codex 一退出，作业关闭，其派生的一切子进程都会被连坐杀掉。
实测现象：工作进程正在关 Codex 时自己消失，日志停在「正在退出 Codex…」。

失败过的做法：

- `Start-Process` → 在作业内，被连坐。
- WMI（`Win32_Process.Create`）→ 本机火绒拦截 WMI 创建的进程：进程建出来了但不执行脚本。
- Explorer `Shell.Application.ShellExecute` → 从 MCP 服务上下文调用时同样不落地。

**可行的做法：计划任务（`schtasks`）**——由 Task Scheduler 服务创建进程，完全在作业对象之外，且属受信任来源。

### 5.2 安装目录的 ACL 陷阱（最隐蔽的一个）

`%LOCALAPPDATA%\DeepSeekUsage` 若由 Codex 沙箱创建，会被加上 `CodexSandboxUsers` 与一个能力 SID 的 ACE。
后果：**计划任务在该目录里既跑不了脚本，也找不到 exe**（exe 报 `0x80070002`，脚本任务 `Last Result -196608`），但同一份文件放到 `%LOCALAPPDATA%\Programs\...`、`%USERPROFILE%\...`、`%TEMP%\...` 都正常。
所以安装目录固定用 `%LOCALAPPDATA%\Programs\DeepSeekUsage`。

### 5.3 其它

- 火绒（本机同时接管了 Defender）会拦脚本类启动：桌面双击 `powershell -File xxx.ps1` 可能毫无反应。排错时优先用日志判断，而不是凭现象猜。
- cc-switch 把每个供应商的**整份 config.toml** 存在自己的数据库里，切换供应商时整份覆盖写回，所以 `[mcp_servers.deepseek_usage]` 可能被抹掉；重跑 `install.ps1` 即可恢复。
- 助手每 2 秒连一次调试端口；手工连 CDP 读页面时可能撞上抢占，必要时先停助手。
- 行尾与 BOM：`.ps1` 为 UTF-8 **带 BOM**（Windows PowerShell 5.1 无 BOM 会按 ANSI 读，中文会乱码且可能报语法错）；`.md` / `.cmd` 用 CRLF 且不带 BOM。

## 6. 验证清单（发版前跑一遍）

- `node --check deepseek-usage-panel.js`；四个 `.ps1` 用 `Parser::ParseFile` 过一遍。
- 端口在听：`Get-NetTCPConnection -LocalPort 9229 -State Listen` 的属主应是 `ChatGPT`。
- 注入生效：连 `http://127.0.0.1:9229/json/list` 找 `app://` 目标，页面里 `window.__dsUsageUIVersion` 等于脚本 `@version`，`#ds-usage-menu-trigger` 在 `[role=menubar]` 内。
- 数据正确：点开卡片能读到余额与今日消费，且与 `platform.deepseek.com/usage` 的「今日」一致。
- 无开机自启：启动文件夹里没有本插件项。
- 卸载干净：`uninstall.ps1` 后 MCP 注册、桌面入口、安装目录都不再存在。

## 7. 版本与提交记录

| 版本 | 内容 |
|---|---|
| `1.0.0` | 首个独立版：菜单栏卡片、CDP 注入、MCP 随 Codex 启停、计划任务自动修复。 |

## 8. 维护建议

1. 升级卡片脚本时**同时**改 `@version` 与 `VERSION`，否则助手会反复注入旧版。
2. 保持「页面只画界面、助手负责取数」的边界，不要把网络请求搬进页面脚本。
3. 改动自动修复相关逻辑后，务必实测「排队 → 父进程被强杀 → 工作进程仍完成重启」这条链路。
4. Codex 升级后先验证菜单栏 DOM（`application-menu-trigger-*`、`application-menu-content-anchor`、`[role=menubar]`）是否还在。

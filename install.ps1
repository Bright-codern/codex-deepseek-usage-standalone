# DeepSeek 消耗 · Codex 桌面端插件 安装脚本
#
# 做什么：
#   1. 复制插件文件到 %LOCALAPPDATA%\Programs\DeepSeekUsage
#   2. 在 ~/.codex/config.toml 注册 MCP 服务器（Codex 启动时拉起数据助手，退出时回收）
#   3. 桌面放置「启动 Codex（带消耗按钮）」入口
#
# 为什么装在 Programs 下：%LOCALAPPDATA%\DeepSeekUsage 若由 Codex 沙箱创建，
# 会被加上 CodexSandboxUsers / 能力 SID 的 ACE，导致计划任务既跑不了脚本也找不到 exe
# （实测报 0x80070002）。Programs 子目录 ACL 干净，计划任务可正常执行。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$CRLF = [string][char]13 + [string][char]10
$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeekUsage'
$CodexConfig = Join-Path $env:USERPROFILE '.codex\config.toml'

Write-Host '== DeepSeek 消耗 · 安装 ==' -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $Target | Out-Null

Copy-Item -LiteralPath (Join-Path $Source 'helper\deepseek-usage-helper.ps1') -Destination (Join-Path $Target 'deepseek-usage-helper.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Source 'helper\mcp-server.ps1') -Destination (Join-Path $Target 'mcp-server.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Source 'helper\auto-restart.ps1') -Destination (Join-Path $Target 'auto-restart.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Source 'helper\finish-launch.ps1') -Destination (Join-Path $Target 'finish-launch.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Source 'deepseek-usage-panel.js') -Destination (Join-Path $Target 'deepseek-usage-panel.js') -Force
Copy-Item -LiteralPath (Join-Path $Source 'launch-codex.ps1') -Destination (Join-Path $Target 'launch-codex.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Source 'launch-codex.cmd') -Destination (Join-Path $Target 'launch-codex.cmd') -Force

# 清理历史版本可能留下的开机自启项（本插件不注册任何自启）
$startup = [Environment]::GetFolderPath('Startup')
foreach ($name in @('DeepSeek 消耗守护.lnk', 'DeepSeek 消耗挂件.lnk')) {
  $old = Join-Path $startup $name
  if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force; Write-Host ('已移除历史自启项：' + $name) }
}

# 配置
$cfgPath = Join-Path $Target 'config.json'
if (-not (Test-Path $cfgPath)) {
  $defaultConfig = @'
{
  "apiKey": "",
  "refreshSeconds": 360,
  "pollSeconds": 2,
  "debugPort": 9229,
  "autoRestart": true,
  "autoRestartDelaySeconds": 45,
  "autoRestartCooldownMinutes": 20
}
'@
  [System.IO.File]::WriteAllText($cfgPath, $defaultConfig, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ('已写入默认配置：' + $cfgPath)
} else {
  Write-Host ('保留已有配置：' + $cfgPath)
}

# 补齐必需的 uiScript 指向
try {
  $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
  if (-not ($cfg.PSObject.Properties.Name -contains 'uiScript') -or -not $cfg.uiScript) {
    $cfg | Add-Member -NotePropertyName uiScript -NotePropertyValue (Join-Path $Target 'deepseek-usage-panel.js') -Force
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '已补写 uiScript 指向'
  }
} catch { Write-Host ('配置补写跳过：' + $_.Exception.Message) }

# 注册 MCP
$launcher = Join-Path $Target 'mcp-server.ps1'
$block = "[mcp_servers.deepseek_usage]" + $CRLF +
  "command = '" + $env:WINDIR + "\System32\WindowsPowerShell\v1.0\powershell.exe'" + $CRLF +
  "args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '" + $launcher + "']" + $CRLF +
  "startup_timeout_sec = 15"

if (Test-Path $CodexConfig) {
  $toml = [System.IO.File]::ReadAllText($CodexConfig, [System.Text.Encoding]::UTF8)
  if ($toml -match '(?m)^\[mcp_servers\.deepseek_usage\]') {
    Copy-Item -LiteralPath $CodexConfig -Destination ($CodexConfig + '.dsusage.bak') -Force
    $pattern = '(?ms)\r?\n?\[mcp_servers\.deepseek_usage\]\r?\n.*?(?=\r?\n\[|\z)'
    $toml = [regex]::Replace($toml, $pattern, '')
    $toml = $toml.TrimEnd() + $CRLF + $CRLF + $block + $CRLF
    [System.IO.File]::WriteAllText($CodexConfig, $toml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '已更新 Codex 配置中的 MCP 注册（备份：config.toml.dsusage.bak）'
  } else {
    Copy-Item -LiteralPath $CodexConfig -Destination ($CodexConfig + '.dsusage.bak') -Force
    $toml = $toml.TrimEnd() + $CRLF + $CRLF + $block + $CRLF
    [System.IO.File]::WriteAllText($CodexConfig, $toml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '已注册到 Codex 配置（备份：config.toml.dsusage.bak）'
  }
} else {
  [System.IO.File]::WriteAllText($CodexConfig, $block + $CRLF, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host '已创建 Codex 配置并注册 MCP'
}

# 桌面入口
$desk = [Environment]::GetFolderPath('Desktop')
foreach ($f in @(Get-ChildItem -LiteralPath $desk -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Codex|消耗' -and ($_.Name -like '*.cmd' -or $_.Name -like '*.lnk') })) {
  Remove-Item -LiteralPath $f.FullName -Force; Write-Host ('已清理旧桌面项：' + $f.Name)
}
Copy-Item -LiteralPath (Join-Path $Target 'launch-codex.cmd') -Destination (Join-Path $desk '启动 Codex（带消耗按钮）.cmd') -Force
Write-Host '已创建桌面入口「启动 Codex（带消耗按钮）.cmd」'

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host 'Codex 启动后若检测到没有调试端口，插件会自动重启一次 Codex 并开启端口（默认 45 秒后），'
Write-Host '菜单栏随即出现「消耗」。也可以直接双击桌面「启动 Codex（带消耗按钮）」手动触发。'
Write-Host ('安装目录：' + $Target)
Write-Host '注意：cc-switch 切换供应商会整份覆盖 ~/.codex/config.toml，若插件不再随 Codex 出现，重跑本脚本即可。'

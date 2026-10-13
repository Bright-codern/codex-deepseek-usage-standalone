# DeepSeek 消耗 · Codex 桌面端插件 卸载脚本
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

$ErrorActionPreference = 'Stop'
$CRLF = [string][char]13 + [string][char]10
$Target = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeekUsage'
$CodexConfig = Join-Path $env:USERPROFILE '.codex\config.toml'

$old = @(Get-CimInstance Win32_Process | Where-Object {
  $_.Name -in @('powershell.exe','pwsh.exe') -and
  ($_.CommandLine -like '*deepseek-usage-helper.ps1*' -or $_.CommandLine -like '*auto-restart.ps1*' -or $_.CommandLine -like '*Programs\DeepSeekUsage\mcp-server.ps1*')
})
foreach ($p in $old) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
if ($old.Count -gt 0) { Write-Host '已结束助手 / 自动修复进程' }

& schtasks.exe /delete /f /tn 'CodexDeepSeekUsageAutoRestart' 2>&1 | Out-Null

$startup = [Environment]::GetFolderPath('Startup')
foreach ($name in @('DeepSeek 消耗守护.lnk', 'DeepSeek 消耗挂件.lnk')) {
  $lnk = Join-Path $startup $name
  if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host ('已移除自启项：' + $name) }
}
$desk = [Environment]::GetFolderPath('Desktop')
foreach ($f in @(Get-ChildItem -LiteralPath $desk -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Codex|消耗' -and ($_.Name -like '*.cmd' -or $_.Name -like '*.lnk') })) {
  Remove-Item -LiteralPath $f.FullName -Force; Write-Host ('已删除桌面项：' + $f.Name)
}

if (Test-Path $CodexConfig) {
  $toml = [System.IO.File]::ReadAllText($CodexConfig, [System.Text.Encoding]::UTF8)
  $pattern = '(?ms)\r?\n?\[mcp_servers\.deepseek_usage\]\r?\n.*?(?=\r?\n\[|\z)'
  if ($toml -match $pattern) {
    Copy-Item -LiteralPath $CodexConfig -Destination ($CodexConfig + '.dsusage.uninstall.bak') -Force
    $toml = [regex]::Replace($toml, $pattern, '')
    [System.IO.File]::WriteAllText($CodexConfig, $toml.TrimEnd() + $CRLF, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '已从 Codex 配置移除 MCP 注册'
  }
}

if (Test-Path -LiteralPath $Target) {
  Remove-Item -LiteralPath $Target -Recurse -Force
  Write-Host ('已删除安装目录：' + $Target)
}
Write-Host '卸载完成（Codex 重启后菜单栏「消耗」消失）。' -ForegroundColor Green

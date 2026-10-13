# 自动修复：当 Codex 没有带调试端口启动时，自动重启一次并带上端口。
# 由 mcp-server.ps1 以独立进程方式拉起（脱离 Codex 生命周期，因为要重启 Codex）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File auto-restart.ps1 -DelaySeconds 25

param(
  [int]$Port = 9229,
  [int]$DelaySeconds = 25,
  [switch]$DryRun,
  [string]$StatePath = ''
)

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogPath = Join-Path $Root 'auto-restart.log'
if (-not $StatePath) { $StatePath = Join-Path $Root 'auto-restart.json' }

function Write-AutoLog([string]$Message) {
  try {
    $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 262144)) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
  } catch {}
}

function Test-DebugPort([int]$Port, [int]$TimeoutMs = 500) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $task = $client.ConnectAsync('127.0.0.1', $Port)
    if ($task.Wait($TimeoutMs) -and $client.Connected) { $client.Close(); return $true }
    $client.Close()
    return $false
  } catch { return $false }
}

function Update-State([hashtable]$Changes) {
  try {
    $state = @{}
    if (Test-Path $StatePath) {
      try {
        $existing = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        foreach ($p in $existing.PSObject.Properties) { $state[$p.Name] = $p.Value }
      } catch {}
    }
    foreach ($k in $Changes.Keys) { $state[$k] = $Changes[$k] }
    [System.IO.File]::WriteAllText($StatePath, ($state | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

Write-AutoLog ('工作进程启动：等待 ' + $DelaySeconds + ' 秒后检查端口 ' + $Port)

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

if (Test-DebugPort $Port) {
  Write-AutoLog '端口已就绪，无需重启（可能已由启动器打开）'
  Update-State @{ failures = 0; lastResult = 'already-up' }
  exit 0
}

# 只有在 Codex 确实正在运行时才重启；否则（例如计划任务在深夜自行触发）直接退出，
# 避免平白无故把 Codex 拉起来。
$codexRunning = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue).Count -gt 0
if (-not $codexRunning) {
  Write-AutoLog 'Codex 未在运行，跳过（不主动启动 Codex）'
  Update-State @{ lastResult = 'codex-not-running' }
  exit 0
}

Write-AutoLog '端口仍未监听，开始重启 Codex 并带上调试端口'
$launcher = Join-Path $Root 'launch-codex.ps1'
if (-not (Test-Path $launcher)) {
  Write-AutoLog ('找不到启动器: ' + $launcher)
  Update-State @{ lastResult = 'launcher-missing' }
  exit 1
}

$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher, '-Force', '-NoPrompt')
if ($DryRun) { $args += '-DryRun' }
try {
  & powershell.exe @args 2>&1 | ForEach-Object { Write-AutoLog ('  ' + $_) }
} catch {
  Write-AutoLog ('启动器抛错: ' + $_.Exception.Message)
}

Start-Sleep -Seconds 3
if (Test-DebugPort $Port) {
  Write-AutoLog ('成功：端口 ' + $Port + ' 已监听')
  Update-State @{ failures = 0; lastResult = 'ok' }
  & schtasks.exe /delete /f /tn 'CodexDeepSeekUsageAutoRestart' 2>&1 | Out-Null
  exit 0
}

$failures = 1
try {
  if (Test-Path $StatePath) {
    $s = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($s.PSObject.Properties.Name -contains 'failures') { $failures = [int]$s.failures + 1 }
  }
} catch {}
Write-AutoLog ('失败：端口仍未监听（累计失败 ' + $failures + ' 次）')
Update-State @{ failures = $failures; lastResult = 'failed' }
& schtasks.exe /delete /f /tn 'CodexDeepSeekUsageAutoRestart' 2>&1 | Out-Null
exit 1

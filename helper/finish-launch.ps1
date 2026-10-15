# 收尾重启：由 launch-codex.ps1 在关 Codex 之前预先排好（独立计划任务）。
# 目的：即使关 Codex 的那条进程链在中途被系统/安全软件杀掉，这个独立任务也能把 Codex 重新拉起来并带上调试端口。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File finish-launch.ps1 -Port 9229 -DelaySeconds 20

param(
  [int]$Port = 9229,
  [int]$DelaySeconds = 20,
  [int]$WaitCodexExitSeconds = 40,
  [int]$WaitPortSeconds = 45,
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogPath = Join-Path $Root 'finish-launch.log'
$TaskName = 'CodexDeepSeekUsageFinish'

function Write-FinishLog([string]$Message) {
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

function Get-CodexMain {
  return @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -notmatch '--type=') })
}

function Get-CodexInfo {
  $pkg = Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1
  if ($pkg) {
    $exe = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $exe) { return @{ Aumid = ($pkg.PackageFamilyName + '!App'); Version = $pkg.Version } }
  }
  return $null
}

$activationSource = @'
using System;
using System.Runtime.InteropServices;
public static class AppActivation {
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication([In] string appUserModelId, [In] string arguments, [In] int options, [Out] out uint processId);
    [PreserveSig] int ActivateForFile([In] string appUserModelId, [In] IntPtr itemArray, [In] string verb, [Out] out uint processId);
    [PreserveSig] int ActivateForProtocol([In] string appUserModelId, [In] IntPtr itemArray, [Out] out uint processId);
  }
  [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
  private class ApplicationActivationManager { }
  public static uint Activate(string aumid, string arguments) {
    IApplicationActivationManager mgr = (IApplicationActivationManager)new ApplicationActivationManager();
    uint pid;
    int hr = mgr.ActivateApplication(aumid, arguments, 0, out pid);
    if (hr < 0) { Marshal.ThrowExceptionForHR(hr); }
    return pid;
  }
}
'@

Write-FinishLog ('收尾任务启动：等待 ' + $DelaySeconds + ' 秒')
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

if (Test-DebugPort $Port) {
  Write-FinishLog ('端口 ' + $Port + ' 已就绪，无需收尾')
  & schtasks.exe /delete /f /tn $TaskName 2>&1 | Out-Null
  exit 0
}

# 给启动器一点时间：它可能正把 Codex 重新拉起来（此时进程在、端口还没开）。
# 这种情况绝不能再去杀它，否则会和启动器互相打架。
$graceDeadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $graceDeadline) {
  if (Test-DebugPort $Port) {
    Write-FinishLog '端口在等待期内就绪，收尾任务退出'
    & schtasks.exe /delete /f /tn $TaskName 2>&1 | Out-Null
    exit 0
  }
  $m = Get-CodexMain
  if ($m.Count -gt 0) {
    $newest = ($m | Sort-Object CreationDate -Descending | Select-Object -First 1).CreationDate
    try { $ageSec = ((Get-Date) - [datetime]$newest).TotalSeconds } catch { $ageSec = 999 }
    if ($ageSec -lt 90) { Start-Sleep -Seconds 2; continue }   # 刚启动不久，继续等端口
  }
  Start-Sleep -Seconds 2
}
if (Test-DebugPort $Port) {
  Write-FinishLog '端口已就绪（宽限期内）'
  & schtasks.exe /delete /f /tn $TaskName 2>&1 | Out-Null
  exit 0
}
Write-FinishLog '宽限期结束仍未就绪，转入强制处理'

# 等 Codex 退出（正常情况下前面的进程已经把它关掉了）
$deadline = (Get-Date).AddSeconds($WaitCodexExitSeconds)
while ((Get-Date) -lt $deadline -and (Get-CodexMain).Count -gt 0) { Start-Sleep -Milliseconds 700 }

$remaining = Get-CodexMain
if ($remaining.Count -gt 0) {
  Write-FinishLog ('Codex 仍在运行（' + $remaining.Count + ' 个主进程），强制结束')
  foreach ($p in $remaining) {
    & taskkill.exe /PID $p.ProcessId /T /F 2>&1 | Out-Null
  }
  Start-Sleep -Seconds 4
  $remaining = Get-CodexMain
  Write-FinishLog ('强制结束后残留主进程: ' + $remaining.Count)
}

if ($DryRun) {
  Write-FinishLog '[DryRun] 跳过启动步骤'
  & schtasks.exe /delete /f /tn $TaskName 2>&1 | Out-Null
  exit 0
}

$info = Get-CodexInfo
if (-not $info) {
  Write-FinishLog '找不到 Codex 包，放弃'
  & schtasks.exe /delete /f /tn $TaskName 2>&1 | Out-Null
  exit 1
}

Write-FinishLog ('按 AUMID 启动 Codex（' + $info.Version + '），并带上端口 ' + $Port)
try {
  Add-Type -TypeDefinition $activationSource -Language CSharp -ErrorAction Stop
  $activationPid = [AppActivation]::Activate($info.Aumid, ('--remote-debugging-port=' + $Port))
  Write-FinishLog ('已激活，pid ' + $activationPid)
} catch {
  Write-FinishLog ('激活失败: ' + $_.Exception.Message)
}

$deadline = (Get-Date).AddSeconds($WaitPortSeconds)
$ok = $false
while ((Get-Date) -lt $deadline) {
  if (Test-DebugPort $Port) { $ok = $true; break }
  Start-Sleep -Milliseconds 700
}
Write-FinishLog ('端口 ' + $Port + ' ' + $(if ($ok) { '已就绪，成功' } else { '仍未就绪，失败' }))
& schtasks.exe /delete /f /tn $TaskName 2>&1 | Out-Null
exit $(if ($ok) { 0 } else { 1 })

# 启动 Codex（带调试端口）——「消耗」菜单按钮的前提条件
# 全过程写入 launch.log，便于排查「按了没反应」这类问题。
# 用法：双击桌面「启动 Codex（带消耗按钮）」
#
# 为什么必须重启：菜单栏「消耗」按钮靠 CDP 注入，需要 Codex 启动时带调试端口；
# 商店版（MSIX）Codex 有单实例锁，已开着的实例不会接受端口参数。
#
# 为什么优先用「按 AUMID 激活」而不是直接运行 exe：
# 实测直接运行 WindowsApps 下的 exe 拿不到端口；而按 AUMID 激活时，
# 参数会真实出现在新进程的命令行里（已用进程快照验证）。

param(
  [int]$Port = 9229,
  [switch]$DryRun,
  [switch]$Force,
  [switch]$NoPrompt
)

$ErrorActionPreference = 'Continue'

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogPath = Join-Path $Root 'launch.log'

function Write-LaunchLog([string]$Message) {
  try {
    Add-Content -Path $LogPath -Value ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message) -Encoding UTF8
  } catch {}
  try { Write-Host $Message } catch {}
}

function Get-CodexInfo {
  $pkg = Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | Select-Object -First 1
  if ($pkg) {
    $exe = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $exe) {
      return @{ Exe = $exe; Aumid = ($pkg.PackageFamilyName + '!App'); Version = $pkg.Version }
    }
  }
  return $null
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

function Get-CodexMainProcesses {
  return @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -notmatch '--type=') })
}

function Write-CodexCommandLines([string]$Tag) {
  $procs = Get-CodexMainProcesses
  Write-LaunchLog ('  [' + $Tag + '] Codex 主进程 ' + $procs.Count + ' 个:')
  foreach ($p in $procs) { Write-LaunchLog ('    pid ' + $p.ProcessId + ' : ' + $p.CommandLine) }
}

function Wait-ForPort([int]$Port, [int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-DebugPort $Port) { return $true }
    Start-Sleep -Milliseconds 600
  }
  return $false
}

function Stop-Codex {
  $procs = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return }
  Write-LaunchLog ('正在退出 Codex…（' + $procs.Count + ' 个进程）')
  foreach ($p in $procs) { try { $null = $p.CloseMainWindow() } catch {} }
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue).Count -gt 0) {
    Start-Sleep -Milliseconds 400
  }
  foreach ($p in @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)) {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
  # 等单实例锁释放，否则新实例会直接交接给“幽灵实例”而拿不到端口
  $waitRelease = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $waitRelease -and @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue).Count -gt 0) {
    Start-Sleep -Milliseconds 400
  }
  Start-Sleep -Seconds 2
  Write-LaunchLog ('Codex 已退出（残留 ' + @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue).Count + ' 个进程）')
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

function Invoke-Activation([string]$Aumid, [string]$Arguments) {
  try { Add-Type -TypeDefinition $activationSource -Language CSharp -ErrorAction Stop } catch {}
  return [AppActivation]::Activate($Aumid, $Arguments)
}

# ================= 主流程 =================
Write-LaunchLog '================ launcher 启动 ================'
Write-LaunchLog ('参数: Port=' + $Port + ' DryRun=' + $DryRun.IsPresent + ' Force=' + $Force.IsPresent + ' NoPrompt=' + $NoPrompt.IsPresent)

$info = Get-CodexInfo
if (-not $info) {
  Write-LaunchLog '找不到 Codex 程序（Get-AppxPackage 无结果），请确认已安装 Codex 桌面端。'
  if (-not $NoPrompt) { Read-Host '按回车退出' }
  exit 1
}
Write-LaunchLog ('Codex 版本 ' + $info.Version)
Write-LaunchLog ('exe  : ' + $info.Exe)
Write-LaunchLog ('aumid: ' + $info.Aumid)

if (Test-DebugPort $Port) {
  Write-LaunchLog ('调试端口 ' + $Port + ' 已在监听，无需重启。')
  if (-not $DryRun -and -not $NoPrompt) { Start-Sleep -Seconds 2 }
  exit 0
}

$running = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
Write-LaunchLog ('当前 ChatGPT 进程数: ' + $running.Count + '，端口 ' + $Port + ' 未监听')

if ($DryRun) {
  Write-LaunchLog '[DryRun] 不执行任何启动/退出操作。'
  exit 0
}

if ($running.Count -gt 0) {
  if (-not $Force -and -not $NoPrompt) {
    Write-Host ''
    $answer = Read-Host '需要退出并重启 Codex 才能带上调试端口。现在重启？(Y/N)'
    if ($answer -notmatch '^(y|Y)') { Write-LaunchLog '用户取消。'; Start-Sleep -Seconds 2; exit 0 }
  }
  Stop-Codex
}

$portOk = $false
$usedMethod = ''

# --- 方式 1：按 AUMID 激活并传参（推荐，已实测参数可到达进程） ---
Write-LaunchLog '--- 方式 1：按 AUMID 激活并传参 ---'
try {
  $pid1 = Invoke-Activation $info.Aumid ('--remote-debugging-port=' + $Port)
  Write-LaunchLog ('  已激活，返回 pid ' + $pid1)
  if (Wait-ForPort $Port 45) { $portOk = $true; $usedMethod = 'AUMID 激活' }
  else { Write-LaunchLog '  方式 1 失败：45 秒内端口未监听'; Write-CodexCommandLines '方式1之后' }
} catch {
  Write-LaunchLog ('  方式 1 抛错: ' + $_.Exception.Message)
}

# --- 方式 2：直接启动 exe（备用） ---
if (-not $portOk) {
  Write-LaunchLog '--- 方式 2：直接启动 exe ---'
  foreach ($p in @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
  Start-Sleep -Seconds 3
  try {
    Start-Process -FilePath $info.Exe -ArgumentList ('--remote-debugging-port=' + $Port) | Out-Null
    Write-LaunchLog '  已发起启动'
    if (Wait-ForPort $Port 30) { $portOk = $true; $usedMethod = '直接启动' }
    else { Write-LaunchLog '  方式 2 失败：30 秒内端口未监听'; Write-CodexCommandLines '方式2之后' }
  } catch {
    Write-LaunchLog ('  方式 2 抛错: ' + $_.Exception.Message)
  }
}

if ($portOk) {
  Write-LaunchLog ('成功（' + $usedMethod + '）：端口 ' + $Port + ' 已就绪，菜单栏「消耗」按钮几秒后出现。')
  if (-not $NoPrompt) { Start-Sleep -Seconds 6 }
  exit 0
}

# --- 兜底：正常启动，保证 Codex 可用 ---
Write-LaunchLog '--- 兜底：正常启动 Codex（不带端口，本次不会有「消耗」按钮）---'
try {
  Start-Process 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $info.Aumid) | Out-Null
  Start-Sleep -Seconds 6
  Write-CodexCommandLines '兜底之后'
} catch {
  Write-LaunchLog ('  兜底启动失败: ' + $_.Exception.Message)
}
Write-LaunchLog '结束：端口未开启。请把 launch.log 发给开发者排查。'
if (-not $NoPrompt) { Read-Host '按回车关闭窗口' }
exit 1

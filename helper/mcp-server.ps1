# DeepSeek 消耗：MCP 启动器
# Codex 启动时由 Codex 自己拉起本进程，本进程再拉起数据助手；Codex 退出时把助手一起收掉。
# 另外负责「自动修复」：若 Codex 没有带调试端口启动，排队一次自动重启（见 auto-restart.ps1）。
#
# stdout 只输出 JSON-RPC，日志一律写文件。

param(
  [string]$HelperPath = ''
)

$ErrorActionPreference = 'Continue'

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogPath = Join-Path $Root 'launcher.log'
$ConfigPath = Join-Path $Root 'config.json'
$StatePath = Join-Path $Root 'auto-restart.json'

function Write-LauncherLog([string]$Message) {
  try {
    $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 262144)) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
  } catch {}
}

function Test-DebugPort([int]$Port, [int]$TimeoutMs = 400) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $task = $client.ConnectAsync('127.0.0.1', $Port)
    if ($task.Wait($TimeoutMs) -and $client.Connected) { $client.Close(); return $true }
    $client.Close()
    return $false
  } catch { return $false }
}

function Get-ConfigValue([string]$Name, $Default) {
  try {
    if (Test-Path $ConfigPath) {
      $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
      if ($cfg.PSObject.Properties.Name -contains $Name) { return $cfg.$Name }
    }
  } catch {}
  return $Default
}

function Get-State {
  $state = @{ lastAttemptUtc = $null; lastSession = 0; failures = 0; lastResult = ''; disabled = $false }
  try {
    if (Test-Path $StatePath) {
      $s = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
      foreach ($p in $s.PSObject.Properties) { $state[$p.Name] = $p.Value }
    }
  } catch {}
  return $state
}

function Save-State([hashtable]$State) {
  try { [System.IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

# 派生一个能活过 Codex 生命周期的独立进程。
#
# 实测结论（本机 Windows 11 + 火绒）：
#   Start-Process      → 进程在 Codex 的作业对象里，Codex 一退出就被连坐杀掉；
#                       表现是工作进程跑到一半（正在关 Codex 时）自己消失。
#   WMI Win32_Process  → 火绒拦截 WMI 创建的进程：进程建出来了但不执行脚本。
#   Explorer ShellExecute → 从 MCP 服务上下文调用时同样不落地。
#   计划任务 (schtasks)  → 由 Task Scheduler 服务创建进程，完全在 Codex 作业对象之外，
#                       且属受信任来源，实测可执行、可存活。
# 所以这里以计划任务为准。
function Start-DetachedWorker([string]$WorkerPath, [int]$Port, [int]$Delay) {
  $taskName = 'CodexDeepSeekUsageAutoRestart'
  $argString = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $WorkerPath + '" -Port ' + $Port + ' -DelaySeconds ' + $Delay

  try {
    & schtasks.exe /create /f /tn $taskName /tr ('powershell.exe ' + $argString) /sc once /st 23:59 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-LauncherLog ('schtasks /create 返回 ' + $LASTEXITCODE) ; return '' }
    & schtasks.exe /run /tn $taskName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-LauncherLog ('schtasks /run 返回 ' + $LASTEXITCODE); return '' }
    return 'schtasks'
  } catch {
    Write-LauncherLog ('schtasks 失败: ' + $_.Exception.Message)
    return ''
  }
}

if (-not $HelperPath) { $HelperPath = Join-Path $Root 'deepseek-usage-helper.ps1' }

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

# ---------- 拉起数据助手 ----------
$helper = $null
try {
  if (Test-Path $HelperPath) {
    $helper = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $HelperPath) -WindowStyle Hidden -PassThru
    Write-LauncherLog ('helper spawned (pid ' + $helper.Id + ')')
  } else {
    Write-LauncherLog ('helper not found: ' + $HelperPath)
  }
} catch {
  Write-LauncherLog ('helper spawn failed: ' + $_.Exception.Message)
}

# ---------- 自动修复：让 Codex 带上调试端口 ----------
try {
  $port = [int](Get-ConfigValue 'debugPort' 9229)
  $autoRestart = Get-ConfigValue 'autoRestart' $true
  $delay = [int](Get-ConfigValue 'autoRestartDelaySeconds' 25)
  $cooldown = [int](Get-ConfigValue 'autoRestartCooldownMinutes' 20)

  if (-not $autoRestart) {
    Write-LauncherLog 'auto-restart: 已在配置中关闭'
  } elseif (Test-DebugPort $port) {
    Write-LauncherLog ('auto-restart: 端口 ' + $port + ' 已就绪，无需处理')
    $s = Get-State
    if ([int]$s.failures -ne 0 -or $s.lastResult -ne 'ok') { $s['failures'] = 0; $s['lastResult'] = 'ok'; $s['disabled'] = $false; Save-State $s }
  } else {
    $parentPid = 0
    try { $parentPid = [int](Get-CimInstance Win32_Process -Filter ("ProcessId=" + $PID)).ParentProcessId } catch {}

    $state = Get-State
    $skip = $null
    if ($state.disabled -eq $true) { $skip = '先前已连续失败，自动修复已停用（删除 auto-restart.json 可恢复）' }
    elseif ([int]$state.failures -ge 2) { $skip = '失败次数过多，停用自动修复'; $state['disabled'] = $true; Save-State $state }
    elseif ($parentPid -gt 0 -and [int]$state.lastSession -eq $parentPid) { $skip = '本会话已尝试过' }
    else {
      try {
        if ($state.lastAttemptUtc) {
          $last = [datetime]::Parse([string]$state.lastAttemptUtc)
          if (((Get-Date) - $last).TotalMinutes -lt $cooldown) { $skip = ('冷却中（距上次 ' + [Math]::Round(((Get-Date) - $last).TotalMinutes, 1) + ' 分钟）') }
        }
      } catch {}
    }

    if ($skip) {
      Write-LauncherLog ('auto-restart: 跳过——' + $skip)
    } else {
      $state['lastAttemptUtc'] = (Get-Date).ToString('o')
      $state['lastSession'] = $parentPid
      $state['lastResult'] = 'pending'
      Save-State $state

      $worker = Join-Path $Root 'auto-restart.ps1'
      if (Test-Path $worker) {
        $how = Start-DetachedWorker -WorkerPath $worker -Port $port -Delay $delay
        if ($how) {
          Write-LauncherLog ('auto-restart: 已排队（派生方式 ' + $how + '），' + $delay + ' 秒后检查并重启 Codex（父会话 pid ' + $parentPid + '）')
        } else {
          Write-LauncherLog 'auto-restart: 派生失败，改用当前进程后台任务'
          Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $worker, '-Port', $port, '-DelaySeconds', $delay) -WindowStyle Hidden | Out-Null
        }
      } else {
        Write-LauncherLog ('auto-restart: 找不到 ' + $worker)
      }
    }
  }
} catch {
  Write-LauncherLog ('auto-restart 逻辑出错: ' + $_.Exception.Message)
}

# ---------- MCP: stdio JSON-RPC ----------
function Send-Response($Id, $Result) {
  $payload = @{ jsonrpc = '2.0'; id = $Id; result = $Result } | ConvertTo-Json -Depth 10 -Compress
  [Console]::Out.WriteLine($payload)
  [Console]::Out.Flush()
}

function Send-Error($Id, [int]$Code, [string]$Message) {
  $payload = @{ jsonrpc = '2.0'; id = $Id; error = @{ code = $Code; message = $Message } } | ConvertTo-Json -Depth 10 -Compress
  [Console]::Out.WriteLine($payload)
  [Console]::Out.Flush()
}

try {
  while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }

    $line = $line.Trim()
    if ($line -eq '') { continue }

    $message = $null
    try { $message = $line | ConvertFrom-Json } catch { continue }

    $id = $message.id
    if ($null -eq $id) { continue }

    switch ($message.method) {
      'initialize' {
        $protocol = $message.params.protocolVersion
        if (-not $protocol) { $protocol = '2025-06-18' }
        Send-Response $id @{
          protocolVersion = $protocol
          capabilities = @{ tools = @{} }
          serverInfo = @{ name = 'deepseek-usage'; version = '3.1.0' }
        }
      }
      'tools/list' {
        Send-Response $id @{ tools = @(
          @{
            name = 'deepseek_usage'
            description = '读取 DeepSeek 充值余额与今日消费（与菜单栏「消耗」卡片同一份数据）。'
            inputSchema = @{ type = 'object'; properties = @{}; additionalProperties = $false }
          }
        ) }
      }
      'tools/call' {
        if ($message.params.name -ne 'deepseek_usage') {
          Send-Error $id -32602 ('unknown tool: ' + $message.params.name)
        } else {
          $payloadPath = Join-Path $Root 'last-payload.json'
          $body = '助手还没取到数据，请稍后再试。'
          if (Test-Path $payloadPath) {
            try { $body = [System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8) } catch {}
          }
          Send-Response $id @{ content = @(@{ type = 'text'; text = $body }); isError = $false }
        }
      }
      'resources/list' { Send-Response $id @{ resources = @() } }
      'prompts/list' { Send-Response $id @{ prompts = @() } }
      'ping' { Send-Response $id @{} }
      default { Send-Error $id -32601 ('method not found: ' + $message.method) }
    }
  }
} catch {
  Write-LauncherLog ('stdio loop failed: ' + $_.Exception.Message)
}

try {
  if ($helper -and -not $helper.HasExited) {
    Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue
    Write-LauncherLog ('helper stopped (pid ' + $helper.Id + ')')
  }
} catch {}
Write-LauncherLog 'launcher exiting (codex exited)'

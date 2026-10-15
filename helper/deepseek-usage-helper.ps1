param(
  [switch]$Once
)

$ErrorActionPreference = 'Stop'

if (-not $Once) {
  $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'CodexPlusPlusDeepSeekUsageHelper')
  if (-not $script:InstanceMutex.WaitOne(0)) { exit 0 }
}

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Root) { $Root = Join-Path $env:APPDATA 'Codex++\deepseek-usage' }
$ConfigPath = Join-Path $Root 'config.json'
$LastPayloadPath = Join-Path $Root 'last-payload.json'
$LogPath = Join-Path $Root 'helper.log'

New-Item -ItemType Directory -Force -Path $Root | Out-Null

function Write-Log([string]$Message) {
  $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
  try {
    if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 262144)) {
      Remove-Item $LogPath -Force -ErrorAction SilentlyContinue
    }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
  } catch {}
}

function Get-Config {
  $defaults = [ordered]@{
    debugPort = 9229
    refreshSeconds = 360
    pollSeconds = 2
    apiKey = ''
    uiScript = ''
  }
  $cfg = $null
  if (Test-Path $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { Write-Log "config parse failed: $($_.Exception.Message)" }
  }
  $out = @{}
  foreach ($k in $defaults.Keys) {
    $v = $null
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains $k)) { $v = $cfg.$k }
    if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) { $v = $defaults[$k] }
    $out[$k] = $v
  }
  return $out
}

function Get-ApiKey($cfg) {
  if ($cfg.apiKey) { return [string]$cfg.apiKey }
  $authPath = Join-Path $env:USERPROFILE '.codex\auth.json'
  if (Test-Path $authPath) {
    try {
      $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
      if ($auth.OPENAI_API_KEY) { return [string]$auth.OPENAI_API_KEY }
    } catch { Write-Log "auth.json parse failed: $($_.Exception.Message)" }
  }
  # Codex 换用 cc-switch 等代理后不再写 auth.json，token 落在 config.toml 里
  $tomlPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  if (Test-Path $tomlPath) {
    try {
      $toml = [System.IO.File]::ReadAllText($tomlPath)
      $m = [regex]::Match($toml, 'experimental_bearer_token\s*=\s*"([^"]+)"')
      if ($m.Success -and $m.Groups[1].Value) { return [string]$m.Groups[1].Value }
    } catch { Write-Log "config.toml parse failed: $($_.Exception.Message)" }
  }
  return ''
}

function Get-Balance($apiKey) {
  $headers = @{ Authorization = "Bearer $apiKey"; Accept = 'application/json' }
  $resp = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Headers $headers -Method Get -TimeoutSec 20
  if (-not $resp.balance_infos -or $resp.balance_infos.Count -eq 0) { throw 'balance_infos empty' }
  $info = $resp.balance_infos[0]
  return [ordered]@{
    currency = $info.currency
    total = [double]$info.total_balance
    granted = [double]$info.granted_balance
    toppedUp = [double]$info.topped_up_balance
  }
}

function Get-BrowserStorageDirs {
  # 凭证只从 Codex 内置浏览器读取：它是 Electron 分区，
  # Local Storage 位于 <userData>\<profile>\Partitions\<分区>\Local Storage\leveldb。
  # 不扫描 Chrome / Edge：Chrome 136+ 禁止对默认配置目录开调试端口，
  # Cookie 又是 app-bound 加密，外部拿不到可用的登录态。
  $dirs = @()
  $patterns = @(
    (Join-Path $env:APPDATA 'Codex\web\Codex\*\Partitions\*\Local Storage\leveldb'),
    (Join-Path $env:APPDATA 'Codex\web\*\*\Partitions\*\Local Storage\leveldb'),
    (Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_*\LocalCache\Roaming\Codex\web\*\Partitions\*\Local Storage\leveldb')
  )
  foreach ($pattern in $patterns) {
    foreach ($item in @(Get-Item -Path $pattern -ErrorAction SilentlyContinue)) { $dirs += $item.FullName }
  }
  return ($dirs | Select-Object -Unique)
}

function Get-PlatformTokenFromBrowser {
  $found = $null
  foreach ($ls in (Get-BrowserStorageDirs)) {
    if (-not (Test-Path -LiteralPath $ls)) { continue }
    $files = Get-ChildItem -LiteralPath $ls -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.log', '.ldb' } | Sort-Object LastWriteTime
    foreach ($f in $files) {
      $bytes = $null
      try {
        $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $ms = New-Object System.IO.MemoryStream
        $fs.CopyTo($ms)
        $fs.Close()
        $bytes = $ms.ToArray()
        $ms.Close()
      } catch { continue }
      if (-not $bytes -or $bytes.Length -eq 0) { continue }
      foreach ($text in @([System.Text.Encoding]::UTF8.GetString($bytes), [System.Text.Encoding]::Unicode.GetString($bytes))) {
        foreach ($m in [regex]::Matches($text, 'userToken[^{]{0,10}\{"value":"((?:[^"\\]|\\.)*)"')) {
          $candidate = $m.Groups[1].Value
          if ($candidate.Length -ge 20) { $found = $candidate }
        }
      }
    }
  }
  return $found
}

function Get-PlatformTodaySpend($token) {
  if (-not $token) { return $null }
  $now = Get-Date
  $startSec = [long][DateTimeOffset]::new($now.Date).ToUnixTimeSeconds()
  $endSec = [long][DateTimeOffset]::new($now.Date.AddDays(1)).ToUnixTimeSeconds()
  $rawOffset = [int]([TimeZoneInfo]::Local.GetUtcOffset($now).TotalSeconds)
  $tzSec = 3600 * [Math]::Floor($rawOffset / 3600)
  $shift = $rawOffset - $tzSec
  $uri = "https://platform.deepseek.com/api/v0/usage/by_api_key/cost?start=$($startSec + $shift)&end=$($endSec + $shift)&tz=$tzSec"
  $headers = @{
    Authorization = "Bearer $token"
    Accept = 'application/json'
    Referer = 'https://platform.deepseek.com/usage'
    Origin = 'https://platform.deepseek.com'
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'
  }
  $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 25
  if ($resp.data -and $resp.data.biz_code -and [int]$resp.data.biz_code -ne 0) { throw "platform biz error $($resp.data.biz_code): $($resp.data.biz_msg)" }
  if ($resp.code -and [int]$resp.code -ne 0) { throw "platform error $($resp.code): $($resp.msg)" }
  $biz = $resp.data.biz_data
  if (-not $biz) { throw 'platform response missing biz_data' }
  $sum = 0.0
  $currency = $null
  foreach ($entry in @($biz.data)) {
    if (-not $entry) { continue }
    if (-not $currency -and $entry.currency) { $currency = $entry.currency }
    foreach ($series in @($entry.series)) {
      if (-not $series) { continue }
      foreach ($bucket in @($series.buckets)) {
        if (-not $bucket) { continue }
        $cost = $bucket.cost
        if ($null -ne $cost -and "$cost" -ne '') { $sum += [double]$cost }
      }
    }
  }
  return [ordered]@{ cost = $sum; currency = $currency }
}

# ---------- CDP：仅在 Codex 开着调试端口时使用（独立版挂件不需要） ----------

function Test-DebugPort([int]$Port, [int]$TimeoutMs = 400) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $task = $client.ConnectAsync('127.0.0.1', $Port)
    if ($task.Wait($TimeoutMs) -and $client.Connected) { $client.Close(); return $true }
    $client.Close()
    return $false
  } catch { return $false }
}

# ---------- CDP (short-lived connections: the app drops idle sessions) ----------

function Invoke-PageExpression([string]$Expression, [int]$Port, [int]$TimeoutSec = 12) {
  $result = $null
  $ws = $null
  try {
    $list = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
    $pages = @($list | Where-Object { $_.type -eq 'page' -and $_.url -like 'app://*' })
    # 应用里有多个渲染进程（主窗口、头像浮层…），菜单栏只在主窗口里。
    # 之前直接取第一个，命中的是头像浮层，数据推过去主窗口收不到，卡片一直显示"等待助手进程"。
    $target = $pages | Where-Object { $_.url -notlike '*avatar-overlay*' } | Select-Object -First 1
    if (-not $target) { $target = $pages | Select-Object -First 1 }
    if (-not $target) { return $null }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    $connect = $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, $ct)
    if (-not $connect.Wait(5000)) { return $null }

    $payload = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $Expression; returnByValue = $true; awaitPromise = $true; userGesture = $true } } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $send = $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct)
    if (-not $send.Wait(5000)) { return $null }

    $buf = New-Object byte[] 1048576
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
      $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
      $task = $ws.ReceiveAsync($seg, $ct)
      if (-not $task.Wait(3000)) { continue }
      $res = $task.Result
      if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
      if ($res.Count -le 0) { continue }
      $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
      if (-not $text.StartsWith('{"id"')) { continue }
      $message = $null
      try { $message = $text | ConvertFrom-Json } catch { continue }
      if ($message.id -ne 1) { continue }
      if ($message.result -and $message.result.result -and ($message.result.result.PSObject.Properties.Name -contains 'value')) {
        $result = $message.result.result.value
      }
      break
    }
  } catch {
    $result = $null
  } finally {
    if ($ws) { try { $ws.Dispose() } catch {} }
  }
  return $result
}

# ---------- collect ----------

$cfg = Get-Config
$apiKey = Get-ApiKey $cfg
$uiPath = $cfg.uiScript
if (-not $uiPath) { $uiPath = Join-Path $env:APPDATA 'Codex++\user_scripts\deepseek-usage-panel.js' }
$script:PlatformToken = $null

$uiSource = ''
if (Test-Path $uiPath) {
  $uiSource = Get-Content -LiteralPath $uiPath -Raw
} elseif (Test-DebugPort ([int]$cfg.debugPort)) {
  Write-Log "ui script not found: $uiPath"
}

$uiScriptVersion = '1.0.3'
if ($uiSource -match '(?m)^//\s*@version\s+([^\s]+)') {
  $uiScriptVersion = [string]$Matches[1]
}

$probeExpression = @"
(function(){
  if (window.__dsUsageUIVersion !== '$uiScriptVersion') {
$uiSource
  }
  var refresh = window.__dsUsageRefreshFlag === true;
  window.__dsUsageRefreshFlag = false;
  return JSON.stringify({ ui: !!window.__dsUsageUIVersion, refresh: refresh });
})()
"@

function Collect {
  $payload = [ordered]@{
    ok = $false
    currency = 'CNY'
    symbol = '¥'
    totalBalance = $null
    toppedUpBalance = $null
    grantedBalance = $null
    accountBalance = $null
    balanceUnavailable = $null
    todaySpend = $null
    todaySpendSource = $null
    todaySpendUnavailable = $null
    updatedAt = [long][DateTimeOffset]::new((Get-Date)).ToUnixTimeMilliseconds()
    error = $null
  }
  try {
    # 余额与今日消费相互独立：任一失败只影响自己那一行
    if (-not $apiKey) {
      $payload.balanceUnavailable = '未找到 DeepSeek API Key'
      Write-Log 'balance unavailable: no api key'
    } else {
      try {
        $balance = Get-Balance $apiKey
        $payload.ok = $true
        $payload.currency = $balance.currency
        if ($balance.currency -eq 'USD') { $payload.symbol = '$' } else { $payload.symbol = '¥' }
        $payload.totalBalance = [Math]::Round($balance.total, 2)
        $payload.toppedUpBalance = [Math]::Round($balance.toppedUp, 2)
        $payload.grantedBalance = [Math]::Round($balance.granted, 2)
        # 账户余额 = 充值余额 + 赠送余额。
        # 优先用接口的 total_balance：它是全精度相加后再取整，与官网显示一致；
        # 若该项缺失或为 0，再退回自行相加（避免百分比舍入造成的 1 分误差）。
        $account = [double]$balance.total
        if ($account -le 0) { $account = [double]$balance.toppedUp + [double]$balance.granted }
        $payload.accountBalance = [Math]::Round($account, 2)
      } catch {
        $payload.balanceUnavailable = $_.Exception.Message
        Write-Log "balance failed: $($_.Exception.Message)"
      }
    }

    $platform = $null
    $unavailable = ''
    if (-not $script:PlatformToken) {
      $script:PlatformToken = Get-PlatformTokenFromBrowser
      if ($script:PlatformToken) { Write-Log 'platform token read from codex browser storage' }
    }
    if ($script:PlatformToken) {
      $token = [string]$script:PlatformToken
      try { $platform = Get-PlatformTodaySpend $token }
      catch {
        Write-Log "platform usage failed: $($_.Exception.Message)"
        $unavailable = '登录态过期，请在 Codex 内置浏览器重新登录'
        # 网页版可能刚刷新过登录态，重新读一次再试。
        $script:PlatformToken = Get-PlatformTokenFromBrowser
        if ($script:PlatformToken -and ([string]$script:PlatformToken) -ne $token) {
          try {
            $platform = Get-PlatformTodaySpend ([string]$script:PlatformToken)
            $unavailable = ''
          } catch {
            Write-Log "platform retry failed: $($_.Exception.Message)"
          }
        }
      }
    } else {
      # 今日消费只认 DeepSeek 网页接口的精确值，取不到就明说，不做余额差值估算。
      $unavailable = '请先在 Codex 内置浏览器登录 DeepSeek'
      Write-Log 'today spend unavailable: no platform token in codex browser storage'
    }
    if ($platform) {
      $payload.todaySpend = [Math]::Round([double]$platform.cost, 2)
      $payload.todaySpendSource = 'platform'
      if ($platform.currency) {
        $payload.currency = $platform.currency
        if ($platform.currency -eq 'USD') { $payload.symbol = '$' } else { $payload.symbol = '¥' }
      }
    } else {
      $payload.todaySpendUnavailable = $unavailable
    }
  } catch {
    $payload.ok = $false
    $payload.error = $_.Exception.Message
    Write-Log "collect failed: $($_.Exception.Message)"
  }
  return $payload
}

function Publish($payload) {
  $json = $payload | ConvertTo-Json -Depth 6 -Compress
  try { Set-Content -LiteralPath $LastPayloadPath -Value $json -Encoding UTF8 } catch {}
  # 独立版：Codex 没开调试端口时直接跳过页面推送
  if (Test-DebugPort ([int]$cfg.debugPort)) {
    Invoke-PageExpression "window.__dsUsageApply && window.__dsUsageApply($json)" ([int]$cfg.debugPort) | Out-Null
  }
}

if ($Once) {
  $payload = Collect
  $payload | ConvertTo-Json -Depth 6
  Publish $payload
  exit 0
}

Write-Log 'helper started'
$lastFetch = [datetime]::MinValue
$pending = $true
$lastProbe = [datetime]::MinValue
$connectedOnce = $false

while ($true) {
  $now = Get-Date
  if (($now - $lastProbe).TotalSeconds -ge [int]$cfg.pollSeconds) {
    $lastProbe = $now
    $raw = Invoke-PageExpression $probeExpression ([int]$cfg.debugPort) 8
    if ($raw -is [string] -and $raw.StartsWith('{')) {
      if (-not $connectedOnce) { Write-Log 'codex window found'; $connectedOnce = $true }
      try {
        $probe = $raw | ConvertFrom-Json
        if ($probe.refresh) { $pending = $true; Write-Log 'refresh requested from panel' }
      } catch {}
    } elseif ($connectedOnce) {
      Write-Log 'codex window not reachable'
      $connectedOnce = $false
    }
  }

  $due = ((Get-Date) - $lastFetch).TotalSeconds -ge [int]$cfg.refreshSeconds
  if ($pending -or $due) {
    $pending = $false
    $lastFetch = Get-Date
    $payload = Collect
    Publish $payload
  }

  Start-Sleep -Milliseconds 400
}



<#
  browser-pool.ps1 — Agent 专用浏览器池（fork 自 AgentBrowser 1.3.0）
  按名字管理浏览器实例：一个实例一个 profile 一个调试端口，登录态长期复用。
  池子版加的三件事：强制收纳（任意 farm 命令自动拉起守护，外部带端口浏览器 3 秒纳管）、
  空闲回收（实例/标签页空闲自动关，有连接或有活动的不杀）、白名单跳过。
  零安装：Windows 自带 PowerShell 5.1 即可，不需要 Node / Python / npm。
  数据目录：%USERPROFILE%\BrowserPool（可用环境变量 BROWSER_POOL_HOME 覆盖，旧变量 AGENTBROWSER_HOME 仍认）
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Cmd = 'help',
    [Parameter(Position = 1)][AllowNull()][object]$Arg1,
    [Parameter(Position = 2)][AllowNull()][object]$Arg2,
    [Parameter(Position = 3)][AllowNull()][object]$Arg3,
    [Parameter(Position = 4, ValueFromRemainingArguments = $true)][string[]]$Rest,
    [switch]$DryRun,
    [switch]$Agent,
    [int]$Port = 0,
    [switch]$Bg,
    [switch]$Headful,
    [int]$Tail = 40,
    [string]$At = '08:30',
    [string]$Days,
    [string]$Desc,
    [string]$From,
    [string]$Source,
    [switch]$Logon,
    [switch]$Alert,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Script:SkillDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:HomeDir = if ($env:BROWSER_POOL_HOME) { $env:BROWSER_POOL_HOME } elseif ($env:AGENTBROWSER_HOME) { $env:AGENTBROWSER_HOME } else { Join-Path $env:USERPROFILE 'BrowserPool' }
$Script:LogDir = Join-Path $Script:HomeDir 'logs'
$Script:DfPath = $PSCommandPath   # HttpListener 请求处理里 $MyInvocation.MyCommand.Path 会是空，统一用这个
$Script:PanelPidFile = Join-Path $Script:HomeDir 'panel.pid'
$Script:PanelPort = 9410
# 面板端口可配置：环境变量 AGENTBROWSER_PANEL_PORT > farm.json 的 panelPort > 9410
if ($env:AGENTBROWSER_PANEL_PORT -match '^\d+$') { $Script:PanelPort = [int]$env:AGENTBROWSER_PANEL_PORT }
try {
    $fjTmp = Join-Path $Script:HomeDir 'farm.json'
    if (Test-Path -LiteralPath $fjTmp) {
        $cfgTmp = [System.IO.File]::ReadAllText($fjTmp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($cfgTmp.panelPort) { $Script:PanelPort = [int]$cfgTmp.panelPort }
    }
} catch { }
$Script:PidDir = Join-Path $Script:LogDir 'pids'
$Script:BrowserPortBase = 9330
$Script:BrowserPortMax = 9399
$Script:BrowserDir = Join-Path $Script:HomeDir 'browser'
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# HTTP 探活连接的空闲存活压到 0.5 秒（默认 100 秒）：不压的话 keep-alive 残留连接会把空闲实例
# 误判成「有客户端在用」，回收永远不触发；0.5 秒够单次请求用完，也够下一轮回收判定前消散
try { [System.Net.ServicePointManager]::MaxServicePointIdleTime = 500 } catch { }

# ---------- 输出 ----------
function W-Info([string]$m) { Write-Host ("  " + $m) -ForegroundColor DarkGray }
function W-Ok([string]$m) { Write-Host ("  [OK] " + $m) -ForegroundColor Green }
function W-Warn([string]$m) { Write-Host ("  [!!] " + $m) -ForegroundColor Yellow }
function W-Bad([string]$m) { Write-Host ("  [XX] " + $m) -ForegroundColor Red }
function W-Title([string]$m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }

# ---------- 基础 ----------
function Ensure-Dir([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function Initialize-Store {
    foreach ($d in @($Script:HomeDir, $Script:LogDir, $Script:PidDir, $Script:BrowserDir)) {
        Ensure-Dir $d
    }
}


function Read-JsonFile([string]$path) {
    $txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    return ($txt | ConvertFrom-Json)
}

function Write-JsonFile([string]$path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, $Script:Utf8NoBom)
}

function Send-Response($stream, [int]$status, [string]$ctype, [string]$content) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $reason = switch ($status) { 200 { 'OK' } 400 { 'Bad Request' } 404 { 'Not Found' } default { 'Error' } }
    $head = "HTTP/1.1 $status $reason`r`nContent-Type: $ctype; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Get-PanelHtml {
    $f = Join-Path $Script:SkillDir 'panel.html'
    if (Test-Path -LiteralPath $f) { return [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) }
    return '<h1>panel.html 缺失</h1>'
}

function Handle-Client($client) {
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $requestLine = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($requestLine)) { return }
    $parts = $requestLine.Split(' ')
    $rawPath = if ($parts.Count -ge 2) { $parts[1] } else { '/' }
    while ($true) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrEmpty($line)) { break }
    }

    $path = $rawPath
    $q = @{}
    $qi = $rawPath.IndexOf('?')
    if ($qi -ge 0) {
        $path = $rawPath.Substring(0, $qi)
        foreach ($kv in $rawPath.Substring($qi + 1).Split('&')) {
            if (-not $kv) { continue }
            $p = $kv.Split('=', 2)
            if ($p.Count -eq 2) {
                $q[[System.Uri]::UnescapeDataString($p[0])] = [System.Uri]::UnescapeDataString($p[1])
            }
        }
    }

    try {
        if ($path -eq '/' -or $path -eq '/index.html') {
            Send-Response $stream 200 'text/html; charset=utf-8' (Get-PanelHtml)
        }
        elseif ($path -eq '/api/health') {
            Send-Response $stream 200 'application/json' '{"ok":true}'
        }
        elseif ($path -eq '/api/heartbeat') {
            # 面板页面每 15 秒打一次；Ensure-Panel 靠它判断窗口是不是已经开着
            try { [System.IO.File]::WriteAllText((Join-Path $Script:HomeDir 'logs\panel_alive.txt'), (Get-Date).ToString('o'), $Script:Utf8NoBom) } catch { }
            Send-Response $stream 200 'application/json' '{"ok":true}'
        }
        elseif ($path -eq '/api/apps') {
            $items = @(Get-AppsPayload)
            $body = @{ ok = $true; items = $items }
            Send-Response $stream 200 'application/json' ($body | ConvertTo-Json -Depth 6 -Compress)
        }
        elseif ($path -eq '/api/activity') {
            $actA = [string]$q['act']
            # 节流 + 轮转：每次请求最多 drain 一个实例，面板不再被"一次遍历全部实例"卡住
            $nowA = Get-Date
            $lastA = $Script:LastDrainAt
            if ((-not $lastA) -or (($nowA - $lastA).TotalSeconds -ge 2)) {
                $Script:LastDrainAt = $nowA
                try {
                    $instsA = @(Get-FarmInstances)
                    if ($instsA.Count -gt 0) {
                        if ($Script:DrainCursor -ge $instsA.Count) { $Script:DrainCursor = 0 }
                        $nmDr = [string]$instsA[$Script:DrainCursor].name
                        $Script:DrainCursor = $Script:DrainCursor + 1
                        $null = Drain-FarmActivity -OnlyName $nmDr
                    }
                } catch { }
            }
            if ($actA -eq 'drain') {
                $drained = 0
                Send-Response $stream 200 'application/json' (@{ ok = $true; drained = $drained; mode = 'rotating' } | ConvertTo-Json -Compress)
            }
            else {
                # 按任务分组返回：一个任务 = 一个浏览器会话 = 一叠日志
                $limA = 800
                if (([string]$q['limit']) -match '^\d+$') { $limA = [int]$q['limit'] }
                $fA = Join-Path $Script:HomeDir 'logs\activity.jsonl'
                $itemsA = @()
                if (Test-Path -LiteralPath $fA) {
                    $tailA = @(Get-Content -LiteralPath $fA -Tail $limA -Encoding UTF8)
                    foreach ($lnA in $tailA) {
                        if (-not $lnA) { continue }
                        try { $itemsA += ($lnA | ConvertFrom-Json) } catch { }
                    }
                    [array]::Reverse($itemsA)
                }
                $orderA = New-Object System.Collections.ArrayList
                $buckets = @{}
                foreach ($itA in $itemsA) {
                    $kA = ''
                    try { $kA = [string]$itA.taskId } catch { }
                    if (-not $kA) { $kA = ('_none_#' + [string]$itA.name) }
                    if (-not $buckets.ContainsKey($kA)) { $buckets[$kA] = New-Object System.Collections.ArrayList; [void]$orderA.Add($kA) }
                    [void]$buckets[$kA].Add($itA)
                }
                $tasksA = @()
                $todayA = (Get-Date).ToString('yyyy-MM-dd')
                foreach ($kA in $orderA) {
                    $arrA = @($buckets[$kA])
                    if ($arrA.Count -eq 0) { continue }
                    $headA = $arrA[0]
                    # 只看当天：昨天的任务段不再占面板（2026-11-20）
                    if (-not ([string]$headA.ts).StartsWith($todayA)) { continue }
                    $nmA = ''
                    try { $nmA = [string]$headA.task } catch { }
                    if (-not $nmA) { $nmA = '未命名任务' }
                    $tasksA += [ordered]@{
                        id       = $kA
                        name     = $nmA
                        instance = [string]$headA.name
                        lastTs   = [string]$headA.ts
                        firstTs  = [string]$arrA[$arrA.Count - 1].ts
                        count    = $arrA.Count
                        items    = @($arrA | Select-Object -First 40)
                    }
                }
                $runA = @()
                foreach ($itA in @(Get-FarmInstances)) {
                    $okA = $false
                    try { $okA = [bool](Test-CdpReady ([int]$itA.port)) } catch { }
                    $runA += [ordered]@{
                        name = [string]$itA.name; port = [int]$itA.port; headless = [bool]$itA.headless; alive = $okA
                        task = (Get-FarmTaskName $itA); taskId = (Get-FarmTaskId $itA)
                    }
                }
                $pidA = ''
                try { $pidA = ((Get-Content -LiteralPath $Script:PanelPidFile -Raw) -replace '\s', '') } catch { }
                # 指挥中心条要的状态：守护在不在 / 收收参数 / 白名单端口数（面板顶部总览）
                $rcA = @{ idleMin = 30; tabIdleMin = 15 }
                try { $rcA = Get-FarmRecycleConfig } catch { }
                $watchA = @{ alive = $false; adopt = $true; idleMin = [int]$rcA.idleMin; tabIdleMin = [int]$rcA.tabIdleMin }
                try { $watchA.alive = ((Test-WatchAlive) -gt 0); $watchA.adopt = [bool](Get-FarmWatchAdopt) } catch { }
                $wlNA = 0
                try { $wlNA = @(Get-FarmExcludePorts).Count } catch { }
                Send-Response $stream 200 'application/json' (@{ ok = $true; tasks = $tasksA; running = $runA; panelPid = $pidA; watch = $watchA; whitelistN = $wlNA } | ConvertTo-Json -Depth 7 -Compress)
            }
        }
        elseif ($path -eq '/api/farm') {
            $act = $q['act']; $nm = $q['name']; $u = $q['url']; $ap = $q['app']
            if (-not $act) { $act = 'list' }
            try {
                if ($act -eq 'list') {
                    $rows = @(Get-FarmRows)
                    $lim = $null
                    try { $lim = Get-FarmLimits } catch { }
                    Send-Response $stream 200 'application/json' (@{ ok = $true; items = $rows; limits = $lim } | ConvertTo-Json -Depth 6 -Compress)
                }
                elseif ($act -eq 'openapp' -and $ap) {
                    $r = Open-WebApp $ap
                    Send-Response $stream 200 'application/json' ($r | ConvertTo-Json -Depth 6 -Compress)
                }
                else {
                    $r = Invoke-Farm $act $nm $(if ($u) { $u } else { $Arg3 })
                    Send-Response $stream 200 'application/json' ($r | ConvertTo-Json -Depth 6 -Compress)
                }
            }
            catch {
                Send-Response $stream 500 'application/json' (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
            }
        }
        else {
            Send-Response $stream 404 'text/plain; charset=utf-8' ('not found: ' + $path)
        }
    }
    catch {
        try { Send-Response $stream 500 'text/plain; charset=utf-8' $_.Exception.Message } catch { }
    }
}


function Start-Panel([int]$port) {
    Initialize-Store
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
    try { $listener.Start() }
    catch { W-Bad ('端口 ' + $port + ' 起不来：' + $_.Exception.Message); return 1 }
    W-Title 'BrowserPool 浏览器池 · 面板'
    W-Ok ('已启动 http://127.0.0.1:' + $port + '/')
    W-Info ('数据目录 ' + $Script:HomeDir + '    Ctrl+C 停止')
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try { Handle-Client $client } catch { } finally { $client.Close() }
    }
}

function Start-PanelBackground([int]$port) {
    Initialize-Store
    if (Test-Path -LiteralPath $Script:PanelPidFile) {
        $old = (Get-Content -LiteralPath $Script:PanelPidFile -Raw).Trim()
        if ($old) {
            $proc = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
            if ($proc) { W-Warn ('面板已经在跑（PID ' + $old + '），先 stop'); return 1 }
        }
    }
    # 路径必须内嵌引号：Start-Process 的 -ArgumentList 数组不自动加引号，路径带空格/括号会被截断（底版潜伏 bug）
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'), 'panel', '-Port', $port)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
    [System.IO.File]::WriteAllText($Script:PanelPidFile, $p.Id.ToString(), $Script:Utf8NoBom)
    Start-Sleep -Milliseconds 1200
    $alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if ($alive) {
        W-Ok ('面板已在后台启动 PID ' + $p.Id)
        W-Info ('打开 http://127.0.0.1:' + $port + '/    停止用：stop')
        return 0
    }
    W-Bad '面板启动后立刻退出，看日志排查'
    return 2
}

function Stop-Panel {
    if (-not (Test-Path -LiteralPath $Script:PanelPidFile)) { W-Info '没有后台面板在跑'; return 0 }
    $pidTxt = (Get-Content -LiteralPath $Script:PanelPidFile -Raw).Trim()
    if ($pidTxt) {
        $proc = Get-Process -Id ([int]$pidTxt) -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $proc.Id -Force
            W-Ok ('已停止面板 PID ' + $pidTxt)
        }
        else { W-Info ('面板进程已不在（PID ' + $pidTxt + '）') }
    }
    Remove-Item -LiteralPath $Script:PanelPidFile -Force -ErrorAction SilentlyContinue
    return 0
}

# ---------- 任务 ID · 一座一端口 · 高效模式 ----------
# 实例 = 一个固定端口 + 一个独立 profile（登录态留在这里）
# agent 只认端口号调用；要看就在那个端口上开 /watch，不抢焦点、不串任务。

function Get-BrowserDownloadDir([string]$id) {
    $d = Join-Path $Script:HomeDir 'downloads'
    return (Join-Path $d ($id -replace '[^\w.-]', '_'))
}

# 下载目录写进 profile 的 Preferences（Chrome 启动前写，比 CDP 更早生效、更稳）
function Set-ChromeDownloadPref([string]$prof, [string]$dir) {
    try {
        $def = Join-Path $prof 'Default'
        Ensure-Dir $def
        $f = Join-Path $def 'Preferences'
        $obj = $null
        if (Test-Path -LiteralPath $f) {
            try { $raw = [System.IO.File]::ReadAllText($f); if ($raw.Trim()) { $obj = $raw | ConvertFrom-Json } } catch { $obj = $null }
        }
        if (-not $obj) { $obj = New-Object psobject }
        $dl = $null
        if ($obj.PSObject.Properties.Name -contains 'download') { $dl = $obj.download } else { $dl = New-Object psobject; $obj | Add-Member -NotePropertyName 'download' -NotePropertyValue $dl }
        $pairs = @{ default_directory = $dir; prompt_for_download = $false; directory_upgrade = $true }
        foreach ($k in $pairs.Keys) {
            if ($dl.PSObject.Properties.Name -contains $k) { $dl.$k = $pairs[$k] } else { $dl | Add-Member -NotePropertyName $k -NotePropertyValue $pairs[$k] }
        }
        $json = $obj | ConvertTo-Json -Depth 12 -Compress
        [System.IO.File]::WriteAllText($f, $json, $Script:Utf8NoBom)
        return $true
    }
    catch { return $false }
}

# 把这条任务的下载目录钉死：浏览器级 + 页面级都设一遍（两种 CDP 都在不同版本上生效过）
function Set-DownloadDir([int]$port, [string]$dir) {
    Ensure-Dir $dir
    $okBrowser = $false
    $okPage = $false
    try {
        $vv = Get-CdpJson ('http://127.0.0.1:' + $port + '/json/version')
        $null = Invoke-CdpWs $vv.webSocketDebuggerUrl 'Browser.setDownloadBehavior' @{ behavior = 'allow'; downloadPath = $dir; eventsEnabled = $true }
        $okBrowser = $true
    }
    catch { }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $pg = Get-CdpPage $port
            $null = Invoke-CdpWs $pg.webSocketDebuggerUrl 'Page.setDownloadBehavior' @{ behavior = 'allow'; downloadPath = $dir }
            $okPage = $true
            break
        }
        catch { Start-Sleep -Milliseconds 300 }
    }
    return @{ browser = $okBrowser; page = $okPage }
}

function Get-ProfileDir([string]$id) { return (Join-Path $Script:BrowserDir ($id -replace '[^\w.-]', '_')) }

function Find-BrowserExe {
    $cands = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Get-CdpJson([string]$url) {
    $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3
    return ($r.Content | ConvertFrom-Json)
}

function Test-PortOpen([int]$port, [int]$ms = 300) {
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($ms)) { return $false }
        $c.EndConnect($iar); return $true
    } catch { return $false }
    finally { if ($c) { try { $c.Close() } catch { } } }
}

function Test-PortFree([int]$port) {
    $l = $null
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
        $l.Start()
        return $true
    }
    catch { return $false }
    finally { if ($l) { try { $l.Stop() } catch { } } }
}


function Test-CdpReady([int]$port) {
    # 先探端口：没监听就别发 HTTP（否则要等连接超时，面板会被拖慢）
    if (-not (Test-PortOpen $port 300)) { return $false }
    try { $null = Get-CdpJson ('http://127.0.0.1:' + $port + '/json/version'); return $true } catch { return $false }
}

function Invoke-CdpWs([string]$wsUrl, [string]$method, $params = @{}, [int]$timeoutSec = 30) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    try {
        $ws.ConnectAsync([Uri]$wsUrl, $ct).Wait($timeoutSec * 1000) | Out-Null
        if ($ws.State -ne 'Open') { throw ('CDP 连不上（' + $ws.State + '）') }
        $mid = 1
        $payload = @{ id = $mid; method = $method; params = $params } | ConvertTo-Json -Depth 12 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait($timeoutSec * 1000) | Out-Null

        $buf = New-Object byte[] 8388608
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
        $sb = New-Object System.Text.StringBuilder
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        $task = $null
        while ((Get-Date) -lt $deadline) {
            if (-not $task) { $task = $ws.ReceiveAsync($seg, $ct) }
            if (-not $task.Wait(1000)) { continue }
            $r = $task.Result
            $task = $null
            if ($r.Count -gt 0) { [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)) }
            if (-not $r.EndOfMessage) { continue }
            $txt = $sb.ToString()
            [void]$sb.Clear()
            if (-not $txt) { continue }
            $o = $txt | ConvertFrom-Json
            if ($o.id -ne $mid) { continue }
            if ($o.PSObject.Properties['error'] -and $o.error) { throw ('CDP ' + $method + ' 报错：' + $o.error.message) }
            return $o.result
        }
        throw ('CDP 超时：' + $method)
    }
    finally {
        try {
            if ($ws.State -eq 'Open') { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $ct).Wait(2000) | Out-Null }
        }
        catch { }
        try { $ws.Dispose() } catch { }
    }
}

function Get-CdpPages([int]$port) {
    # 一个实例下的所有 page（业务常常开好几个 tab，只装第一个会漏）
    try {
        $list = @(Get-CdpJson ('http://127.0.0.1:' + $port + '/json/list'))
        return @($list | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
    } catch { return @() }
}

function Get-CdpPage([int]$port) {
    $list = @(Get-CdpJson ('http://127.0.0.1:' + $port + '/json/list'))
    $page = $list | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
    if (-not $page) {
        $v = Get-CdpJson ('http://127.0.0.1:' + $port + '/json/version')
        $null = Invoke-CdpWs $v.webSocketDebuggerUrl 'Target.createTarget' @{ url = 'about:blank' }
        Start-Sleep -Milliseconds 500
        $list = @(Get-CdpJson ('http://127.0.0.1:' + $port + '/json/list'))
        $page = $list | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
    }
    return $page
}

function Get-BrowserMainProc([int]$port) {
    $pat = '--remote-debugging-port=' + $port + '(\s|$)'
    return Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $pat -and $_.CommandLine -notmatch '--type=' } |
        Select-Object -First 1
}

function Get-BrowserMode([int]$port) {
    $p = Get-BrowserMainProc $port
    if (-not $p) { return '' }
    if ($p.CommandLine -match '--headless') { return 'headless' }
    return 'headful'
}

# 只关「自己这个浏览器端口」的实例：先按 pid 文件精确杀，再按端口命令行兜底；禁按进程名全杀
function Stop-BrowserByPort([int]$port, [string]$id) {
    $pidf = Join-Path $Script:PidDir (($id -replace '[^\w.-]', '_') + '.chrome.pid')
    $killed = 0
    if (Test-Path -LiteralPath $pidf) {
        $v = (Get-Content -LiteralPath $pidf -Raw).Trim()
        if ($v) {
            Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $v) -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            $pp = Get-Process -Id ([int]$v) -ErrorAction SilentlyContinue
            if ($pp) { Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue; $killed++ }
        }
        Remove-Item -LiteralPath $pidf -Force -ErrorAction SilentlyContinue
    }
    if (Test-CdpReady $port) {
        $mp = Get-BrowserMainProc $port
        if ($mp) {
            Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $mp.ProcessId) -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $mp.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    for ($i = 0; $i -lt 25; $i++) { if (-not (Test-CdpReady $port)) { break }; Start-Sleep -Milliseconds 200 }
    return $killed
}

# ---------- 冻结状态：记住每个任务「最后停在哪」（网址 / 标题 / 滚动位置 / 模式） ----------
function Hide-BrowserWindow([int]$port) {
    # 把有头窗口挪到屏幕外：进程还在、页面照跑，只是不占屏幕。给「一次性任务跑完但先别关」的场景用。
    try {
        $v = Get-CdpJson ('http://127.0.0.1:' + $port + '/json/version')
        $page = Get-CdpPage $port
        $win = Invoke-CdpWs $v.webSocketDebuggerUrl 'Browser.getWindowForTarget' @{ targetId = $page.id }
        if (-not $win.windowId) { return $false }
        $null = Invoke-CdpWs $v.webSocketDebuggerUrl 'Browser.setWindowBounds' @{ windowId = $win.windowId; bounds = @{ left = -3000; top = -3000; width = 1280; height = 800; windowState = 'normal' } }
        return $true
    }
    catch { return $false }
}

function Show-BrowserWindow([int]$port) {
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $v = Get-CdpJson ('http://127.0.0.1:' + $port + '/json/version')
            $page = Get-CdpPage $port
            $win = Invoke-CdpWs $v.webSocketDebuggerUrl 'Browser.getWindowForTarget' @{ targetId = $page.id }
            if ($win.windowId) {
                $null = Invoke-CdpWs $v.webSocketDebuggerUrl 'Browser.setWindowBounds' @{ windowId = $win.windowId; bounds = @{ left = 100; top = 80; width = 1280; height = 900; windowState = 'normal' } }
                $null = Invoke-CdpWs $page.webSocketDebuggerUrl 'Page.bringToFront' @{}
                # CDP 的 bringToFront 只是「请求」，被其他窗口盖住时还得用 Win32 真提到最前
                try {
                    if (-not ('AgentBrowserWin.Win' -as [type])) {
                        Add-Type -Namespace AgentBrowserWin -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern void keybd_event(byte b, byte s, uint f, UIntPtr e);'
                    }
                    $mp = Get-BrowserMainProc $port
                    if ($mp) {
                        $h = (Get-Process -Id $mp.ProcessId -ErrorAction SilentlyContinue).MainWindowHandle
                        if ($h -and $h -ne [IntPtr]::Zero) {
                            $null = [AgentBrowserWin.Win]::ShowWindow($h, 9)
                            $null = [AgentBrowserWin.Win]::BringWindowToTop($h)
                            $null = [AgentBrowserWin.Win]::SetForegroundWindow($h)
                            Start-Sleep -Milliseconds 250
                            # 前台锁没放开时，轻点一下 ALT 再抢一次（只发生在用户点「打开页面」时，不是自动跑任务）
                            if ([AgentBrowserWin.Win]::GetForegroundWindow() -ne $h) {
                                [AgentBrowserWin.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
                                Start-Sleep -Milliseconds 80
                                [AgentBrowserWin.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
                                Start-Sleep -Milliseconds 120
                                $null = [AgentBrowserWin.Win]::BringWindowToTop($h)
                                $null = [AgentBrowserWin.Win]::SetForegroundWindow($h)
                            }
                        }
                    }
                }
                catch { }
                return $true
            }
        }
        catch { }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Get-FarmFile { return (Join-Path $Script:HomeDir 'farm.json') }
function Get-FarmSlug([string]$name) { return (($name -replace '[^\w\.\-]', '_')) }
function Get-FarmId([string]$name) { return ('farm_' + (Get-FarmSlug $name)) }

# farm.json 唯一写入口：读旧 JSON 为底，只覆盖传入的键，其余键原样保留。
# 底版 bug：Farm-Touch / Farm-Stop / Farm-Start 各自用硬编码字段表整写，excludePorts / autoAdoptPorts /
# idleMin 等配置会被 routine 操作静默洗掉（farm watch 设的名单，一次 farm open 就没了）。
function Update-FarmFile([hashtable]$Set, $Instances = $null) {
    $f = Get-FarmFile
    Ensure-Dir $Script:HomeDir
    $obj = $null
    if (Test-Path -LiteralPath $f) {
        try { $obj = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $obj = $null }
        if (-not $obj) {
            # 手改坏的 farm.json：先把坏文件改名留证再重建，绝不无声洗掉（登记+配置都在里面）
            try { Move-Item -LiteralPath $f -Destination ($f + '.bad-' + (Get-Date).ToString('yyyyMMddHHmmss')) -Force } catch { }
        }
    }
    if (-not $obj) { $obj = New-Object psobject }
    if ($null -ne $Instances) {
        if ($obj.PSObject.Properties['instances']) { $obj.instances = @($Instances) }
        else { $obj | Add-Member -NotePropertyName instances -NotePropertyValue @($Instances) }
    }
    if ($Set) {
        foreach ($k in @($Set.Keys)) {
            if ($obj.PSObject.Properties[$k]) { $obj.$k = $Set[$k] }
            else { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Set[$k] }
        }
    }
    [System.IO.File]::WriteAllText($f, ($obj | ConvertTo-Json -Depth 8), $Script:Utf8NoBom)
}

function Get-FarmInstances {
    $f = Get-FarmFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try {
        $d = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($d.PSObject.Properties['instances'] -and $d.instances) {
            # 过滤 null：farm.json 曾出现 [null, {...}]（写配置先于开实例时 instances 键缺失，
            # @($null) 展开成单元素 null 数组混进来），null 条目会让遍历方处处踩空
            return @($d.instances | Where-Object { $_ })
        }
        return @()
    }
    catch { return @() }
}

function Save-FarmInstances($list) {
    Update-FarmFile @{} -Instances $list
}

function Get-FarmItem([string]$name) {
    foreach ($i in (Get-FarmInstances)) {
        if ([string]$i.name -eq $name) { return $i }
    }
    return $null
}

# ---------- 端口唯一映射：名字确定性派生（同名同端口，跨机器一致） ----------
# 派生段 9360-9399（40 个）：避开本机其它工具常用的 9330-9339 段，两套永不打架。
# 哈希用 MD5 前四字节（.NET 内建、跨机跨版本稳定）；撞车或被占就按序后探，实际端口记进 farm.json，
# 以 farm open 输出 / farm port 查询为准——派生只是「首选」，不是硬保证。
$Script:DerivedPortBase = 9360
$Script:DerivedPortSpan = 40

function Get-DerivedPort([string]$name) {
    try {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try {
            $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($name))
            $v = [BitConverter]::ToUInt32($bytes, 0)
            return ($Script:DerivedPortBase + [int]($v % $Script:DerivedPortSpan))
        }
        finally { $md5.Dispose() }
    } catch { return 0 }
}

function Get-ProcSnapshot {
    # 一次请求内多个实例共用一份进程表；3 秒内重复请求直接用缓存
    $now = Get-Date
    if ($Script:ProcSnapCache -and $Script:ProcSnapAt -and (($now - $Script:ProcSnapAt).TotalSeconds -lt 3)) {
        return $Script:ProcSnapCache
    }
    $Script:ProcSnapCache = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue)
    $Script:ProcSnapAt = $now
    return $Script:ProcSnapCache
}

function Get-FarmMemMB([int]$port) {
    # 按进程树算：主进程带 --remote-debugging-port=<port>，renderer/gpu 是它的子孙
    try {
        $all = @(Get-ProcSnapshot)
        if ($all.Count -eq 0) { return 0 }
        $pat = 'remote-debugging-port=' + $port + '(\s|$|")'
        $roots = @($all | Where-Object { $_.CommandLine -and ($_.CommandLine -match $pat) })
        if ($roots.Count -eq 0) { return 0 }
        $ids = @{}
        foreach ($r in $roots) { $ids[[int]$r.ProcessId] = $true }
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($c in $all) {
                $cid = [int]$c.ProcessId
                if ($ids.ContainsKey($cid)) { continue }
                if ($ids.ContainsKey([int]$c.ParentProcessId)) { $ids[$cid] = $true; $changed = $true }
            }
        }
        $mb = 0
        foreach ($k in @($ids.Keys)) {
            $gp = Get-Process -Id $k -ErrorAction SilentlyContinue
            if ($gp) { $mb += [int]($gp.WorkingSet64 / 1MB) }
        }
        return $mb
    }
    catch { return 0 }
}

function Get-FarmTabs([int]$port) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/list') -TimeoutSec 3
        $n = 0
        foreach ($t in @(Convert-JsonArray $r.Content)) { if ($t.type -eq 'page') { $n++ } }
        return $n
    }
    catch { return 0 }
}

function Get-FarmRows {
    $rows = @()
    foreach ($i in (Get-FarmInstances)) {
        $name = [string]$i.name
        $port = [int]$i.port
        $live = Test-CdpReady $port
        $mode = ''
        if ($live) { $mode = Get-BrowserMode $port }
        $idle = 0
        if ($i.lastUsedAt) { try { $idle = [int]((Get-Date) - [datetime]$i.lastUsedAt).TotalMinutes } catch { } }
        $rows += [pscustomobject]@{
            名称 = $name; 端口 = $port; 运行 = $(if ($live) { '是' } else { '否' }); 模式 = $mode
            内存MB = $(if ($live) { Get-FarmMemMB $port } else { 0 }); 标签页 = $(if ($live) { Get-FarmTabs $port } else { 0 })
            空闲分钟 = $idle; 网址 = [string]$i.url
        }
    }
    return $rows
}

function Get-FarmLimits {
    $lim = @{ maxInstances = 8 }
    $f = Join-Path $Script:HomeDir 'farm.json'
    if (Test-Path -LiteralPath $f) {
        try {
            $d = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $d.maxInstances) { $lim.maxInstances = [int]$d.maxInstances }
        }
        catch { }
    }
    return $lim
}

function Save-FarmLimits([int]$maxInstances) {
    Update-FarmFile @{ maxInstances = $maxInstances }
}

function Farm-Start([string]$name, [string]$url = '', $headless = $null) {
    if (-not $name) { return @{ ok = $false; error = '缺名字' } }
    Initialize-Store
    $item = Get-FarmItem $name
    # 没显式指定模式时按实例配置走：有头实例（要人看/要弹登录窗）不能被 open 静默改成无头
    if ($null -eq $headless) {
        if ($item -and $null -ne $item.headless) { $headless = [bool]$item.headless } else { $headless = $true }
    } else { $headless = [bool]$headless }
    if ($item -and (Test-CdpReady ([int]$item.port))) {
        $port = [int]$item.port
        if ($url) { try { $null = Farm-Goto $name $url } catch { } }
        Farm-Touch $name
        Ensure-FarmTask $name
        $null = Install-ActivityHook $port
        Ensure-Panel ((Get-BrowserMode $port) -ne 'headless')
        return @{ ok = $true; name = $name; port = $port; reused = $true; mode = (Get-BrowserMode $port) }
    }
    $lim = Get-FarmLimits
    # 上限只数池子亲生的实例：外部纳管的浏览器只是「被看见」，不能占池子的名额（实测踩过：
    # 同机 8 个真实浏览器被纳管后，池子一个实例都开不出来）
    $liveCount = 0
    foreach ($ix in @(Get-FarmInstances)) {
        $isExtL = $false
        try { $isExtL = [bool]$ix.external } catch { }
        if ($isExtL) { continue }
        try { if (Test-CdpReady ([int]$ix.port)) { $liveCount++ } } catch { }
    }
    if ($liveCount -ge $lim.maxInstances) {
        return @{ ok = $false; error = ('实例数已达上限 ' + $lim.maxInstances + '（可 farm close 关掉不用的实例，或改 farm.json 的 maxInstances）') }
    }
    $id = Get-FarmId $name
    $exe = Find-BrowserExe
    if (-not $exe) { return @{ ok = $false; error = '没找到 Chrome / Edge' } }
    if ($item -and [string]$item.dir) { $prof = [string]$item.dir } else { $prof = Get-ProfileDir $id }
    Ensure-Dir $prof
    $dlDir = Get-BrowserDownloadDir $id
    Ensure-Dir $dlDir
    if (-not ($item -and $item.keepDownloads)) { $null = Set-ChromeDownloadPref $prof $dlDir }
    $noFeatures = 'Translate'
    if ($item -and $item.lean) { $noFeatures += ',CalculateNativeWinOcclusion' }
    $firstUrl = $url
    if (-not $firstUrl -and $item -and $item.url) { $firstUrl = [string]$item.url }
    if (-not $firstUrl) { $firstUrl = 'about:blank' }
    # 端口与启动（带重试）：同机可能有别的工具也在 9330-9399 段起浏览器，选好的端口可能被抢先占，
    # 起不来就杀掉半启动进程换下一个端口再试，最多 3 次（登记过的实例端口固定，不参与换端口）
    $tried = @()
    $ready = $false
    $p = $null
    for ($attempt = 0; $attempt -lt 3 -and -not $ready; $attempt++) {
        if ($item -and ([int]$item.port -gt 0)) {
            $port = [int]$item.port
        }
        else {
            $port = 0
            $usedP = @()
            foreach ($i in (Get-FarmInstances)) { if ($i.port) { $usedP += [int]$i.port } }
            $usedP += $tried
            # 候选顺序：名字派生端口优先（同名跨机器同端口），派生段内按序后探，最后才动 9330-9359 余量段
            $der = Get-DerivedPort $name
            $cands = @()
            if ($der -ge $Script:DerivedPortBase) {
                for ($d = 0; $d -lt $Script:DerivedPortSpan; $d++) {
                    $cands += ($Script:DerivedPortBase + ((($der - $Script:DerivedPortBase) + $d) % $Script:DerivedPortSpan))
                }
            }
            for ($c = $Script:BrowserPortBase; $c -lt $Script:DerivedPortBase; $c++) { $cands += $c }
            foreach ($cand in $cands) {
                if (($cand -le $Script:BrowserPortMax) -and ($usedP -notcontains $cand) -and (Test-PortFree $cand)) { $port = $cand; break }
            }
            if ($port -eq 0) { return @{ ok = $false; error = ('浏览器端口池 ' + $Script:BrowserPortBase + '-' + $Script:BrowserPortMax + ' 用完了，先 farm close 关掉不用的实例') } }
        }
        # 登记过的实例端口固定：清完同 profile 僵尸后要能用原端口重试（独立审查揪出：这里 break 会让
        # 固定端口实例清完僵尸直接报失败，用户得再跑一次 open）；新实例换端口靠 $usedP 含 $tried 保证不回头
        $tried += $port
        $a = @(
            ('--remote-debugging-port=' + $port),
            ('--user-data-dir="' + $prof + '"'),
            '--no-first-run', '--no-default-browser-check',
            '--disable-extensions', '--disable-background-networking', '--disable-sync',
            '--mute-audio', '--metrics-recording-only',
            '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding', '--disable-background-timer-throttling',
            '--window-size=1280,900'
        )
        if ($item -and $item.lean) {
            # 瘦身模式（实例级 lean:true）：只给不需要人眼看的抓数实例开
            $a += @('--disable-gpu', '--disable-software-rasterizer', '--renderer-process-limit=1')
        }
        if ($item -and $item.noImages) { $a += '--blink-settings=imagesEnabled=false' }
        if ($item -and $item.jsHeapMB) { $a += ('--js-flags=--max-old-space-size=' + [int]$item.jsHeapMB) }
        $a += ('--disable-features=' + $noFeatures)
        if ($headless) { $a += '--headless=new' } else { $a += '--window-position=100,80' }
        # 实例级额外参数（farm.json 的 extraArgs，数组）：原样追加在最后，同名参数以这里为准
        # 用途：某些站点有特殊要求（如企业统一代理、后台页面降频），参数仍只在一处定义
        if ($item -and $item.extraArgs) {
            foreach ($ea in @($item.extraArgs)) { if ($ea) { $a += [string]$ea } }
        }
        $a += $firstUrl
        $p = Start-Process -FilePath $exe -ArgumentList $a -PassThru
        Start-Sleep -Milliseconds 400
        if ($p.HasExited) {
            # 新进程秒退 ≈ 同 profile 已有僵尸 Chrome（单例转交后自杀）：按 profile 路径清掉再重试
            try {
                Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and ($_.CommandLine -match [regex]::Escape($prof)) } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 600
            } catch { }
            continue
        }
        for ($i = 0; $i -lt 80; $i++) {
            if (Test-CdpReady $port) { $ready = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $ready) { $null = Stop-BrowserByPort $port $id }
    }
    if (-not $ready) { return @{ ok = $false; error = ('浏览器起来了但端口 ' + ($tried -join '/') + ' 没响应') } }
    if (-not ($item -and $item.keepDownloads)) { Set-DownloadDir $port $dlDir }
    $now = (Get-Date).ToString('s')
    $list = @(Get-FarmInstances | Where-Object { [string]$_.name -ne $name })
    # 保留实例原有字段（lean / keepDownloads / noGc 等），只覆盖运行时字段
    $newItem = [ordered]@{}
    # 注意循环变量名：这里不能用 $p（外层 $p 是刚 Start-Process 的浏览器进程，遮蔽会让返回值 pid 丢成 null）
    if ($item) { foreach ($pr in $item.PSObject.Properties) { $newItem[$pr.Name] = $pr.Value } }
    $newItem.name = $name
    $newItem.id = $id
    $newItem.port = $port
    $newItem.url = $firstUrl
    $newItem.dir = $prof
    $newItem.headless = $headless
    if (-not $newItem.createdAt) { $newItem.createdAt = $now }
    $newItem.lastUsedAt = $now
    $list += [pscustomobject]$newItem
    $lim2 = Get-FarmLimits
    Update-FarmFile @{} -Instances @($list)
    Ensure-FarmTask $name
    $null = Install-ActivityHook $port
    Ensure-Panel (-not $headless)
    return @{ ok = $true; name = $name; port = $port; pid = $p.Id; reused = $false; mode = $(if ($headless) { 'headless' } else { 'headful' }); profile = $prof; downloads = $dlDir }
}

function Farm-Touch([string]$name) {
    $list = @()
    $now = (Get-Date).ToString('s')
    foreach ($i in (Get-FarmInstances)) {
        if ([string]$i.name -eq $name) { $i | Add-Member -NotePropertyName lastUsedAt -NotePropertyValue $now -Force }
        $list += $i
    }
    Update-FarmFile @{} -Instances @($list)
}

function Farm-Goto([string]$name, [string]$url) {
    $item = Get-FarmItem $name
    if (-not $item) { return @{ ok = $false; error = ('没有这个实例：' + $name + '（先 farm open）') } }
    $port = [int]$item.port
    if (-not (Test-CdpReady $port)) { return @{ ok = $false; error = '实例没在跑（先 farm open ' + $name + '）' } }
    $pg = Get-CdpPage $port
    $null = Invoke-CdpWs $pg.webSocketDebuggerUrl 'Page.navigate' @{ url = $url }
    Farm-Touch $name
    return @{ ok = $true; name = $name; port = $port; url = $url }
}

function Farm-TabNew([string]$name, [string]$url) {
    $item = Get-FarmItem $name
    if (-not $item) { return @{ ok = $false; error = ('没有这个实例：' + $name + '（先 farm open）') } }
    $port = [int]$item.port
    if (-not (Test-CdpReady $port)) { return @{ ok = $false; error = '实例没在跑（先 farm open ' + $name + '）' } }
    if (-not $url) { $url = 'about:blank' }
    $v = Get-CdpJson ('http://127.0.0.1:' + $port + '/json/version')
    $r = Invoke-CdpWs $v.webSocketDebuggerUrl 'Target.createTarget' @{ url = $url }
    Farm-Touch $name
    return @{ ok = $true; name = $name; port = $port; url = $url; targetId = [string]$r.targetId }
}

function Get-WebAppFile { return (Join-Path $Script:HomeDir 'webapps.json') }

function Get-WebApps {
    $f = Get-WebAppFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try {
        $d = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return @($d.apps)
    }
    catch { return @() }
}

function Test-UrlSameSite([string]$tabUrl, [string]$wantUrl) {
    # 平台常把深链重定向到首页（如 /a/b/c/detail → /），所以同域 + 路径互为前缀就算同一后台
    if (-not $tabUrl -or -not $wantUrl) { return $false }
    try { $a = [uri]$tabUrl; $b = [uri]$wantUrl } catch { return $false }
    if ($a.Host -ne $b.Host) { return $false }
    $pa = $a.AbsolutePath; $pb = $b.AbsolutePath
    if ($pa -eq $pb) { return $true }
    if ($pa -eq '/' -or $pb -eq '/') { return $true }
    if ($pa.StartsWith($pb) -or $pb.StartsWith($pa)) { return $true }
    return $false
}

function Get-AppsPayload {
    # 后台入口表 + 每个后台当前状态（实例在不在跑 / 页签是不是已经开着）
    $farmRows = @()
    foreach ($i in (Get-FarmInstances)) {
        $port = [int]$i.port
        $live = Test-CdpReady $port
        $tabs = @()
        if ($live) { $tabs = @(Get-FarmTabList $port) }
        $farmRows += [pscustomobject]@{ name = [string]$i.name; port = $port; live = $live; tabs = $tabs }
    }
    $out = @()
    foreach ($a in (Get-WebApps)) {
        $inst = [string]$a.instance
        $url = [string]$a.url
        $row = @($farmRows | Where-Object { $_.name -eq $inst }) | Select-Object -First 1
        $isOpen = $false
        if ($row -and $row.live) {
            foreach ($t in @($row.tabs)) {
                if (Test-UrlSameSite ([string]$t.网址) $url) { $isOpen = $true; break }
            }
        }
        $out += [pscustomobject]@{
            app = [string]$a.app; skill = [string]$a.skill; instance = $inst; url = $url
            port = $(if ($row) { [int]$row.port } else { 0 })
            live = $(if ($row) { [bool]$row.live } else { $false })
            open = $isOpen
            tabs = $(if ($row -and $row.live) { @($row.tabs | ForEach-Object { [string]$_.网址 }) } else { @() })
        }
    }
    return $out
}

function Open-WebApp([string]$appName) {
    $a = @(Get-WebApps | Where-Object { [string]$_.app -eq $appName }) | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = ('入口表里没有：' + $appName) } }
    $inst = [string]$a.instance
    $url = [string]$a.url
    $item = Get-FarmItem $inst
    if (-not $item) { return @{ ok = $false; error = ('浏览器实例没登记：' + $inst + '（先 farm open ' + $inst + '）') } }
    if (-not (Test-CdpReady ([int]$item.port))) {
        $st = Farm-Start $inst $url
        if (-not $st.ok) { return @{ ok = $false; error = $st.error } }
        Start-Sleep -Milliseconds 800
        $null = Farm-TabNew $inst $url
        return @{ ok = $true; app = $appName; instance = $inst; port = [int]$st.port; url = $url; started = $true }
    }
    $r = Farm-TabNew $inst $url
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    return @{ ok = $true; app = $appName; instance = $inst; port = [int]$r.port; url = $url; started = $false }
}

function Farm-Stop([string]$name) {
    $item = Get-FarmItem $name
    if (-not $item) { W-Warn ('没有登记过这个实例：' + $name); return 4 }
    $port = [int]$item.port
    $killed = Stop-BrowserByPort $port (Get-FarmId $name)
    $list = @(Get-FarmInstances)   # 保留登记（端口不变，下次还用它）
    Update-FarmFile @{} -Instances @($list)
    if ($killed -gt 0) { W-Ok ('已关 ' + $name + '（端口 ' + $port + '）') } else { W-Info ($name + ' 本来就没在跑（端口 ' + $port + '）') }
    return 0
}

function Farm-Forget([string]$name) {
    $list = @(Get-FarmInstances | Where-Object { [string]$_.name -ne $name })
    Update-FarmFile @{} -Instances @($list)
    W-Ok ('已从登记表移除：' + $name + '（profile 目录还留着，登录态不丢）')
    return 0
}

# ---------- 自动收编开关：只对明确列入名单的端口生效（2026-11-20） ----------
function Get-FarmAutoAdoptPorts {
    $d = @()
    $f = Get-FarmFile
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.PSObject.Properties['autoAdoptPorts'] -and $j.autoAdoptPorts) { $d = @($j.autoAdoptPorts | ForEach-Object { [int]$_ }) }
        } catch { }
    }
    return $d
}

function Save-FarmAutoAdoptPorts($ports) {
    Update-FarmFile @{ autoAdoptPorts = @($ports | ForEach-Object { [int]$_ }) }
}

# ---------- 收纳守护：强制开启（watchEnabled），白名单跳过，空闲回收 ----------
function Get-FarmWatchEnabled {
    # 默认 true：Agent 版强制收纳，关掉要显式 farm watch off
    $f = Get-FarmFile
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.PSObject.Properties['watchEnabled'] -and $null -ne $j.watchEnabled) { return [bool]$j.watchEnabled }
        } catch { }
    }
    return $true
}

function Set-FarmWatchEnabled([bool]$on) {
    Update-FarmFile @{ watchEnabled = $on }
}

function Test-WatchAlive {
    $pf = Join-Path $Script:HomeDir 'logs\watch.pid'
    if (-not (Test-Path -LiteralPath $pf)) { return 0 }
    $oldPid = 0
    try { $oldPid = [int](([System.IO.File]::ReadAllText($pf)).Trim()) } catch { }
    if ($oldPid -gt 0) {
        try { if (Get-Process -Id $oldPid -ErrorAction Stop) { return $oldPid } } catch { }
    }
    return 0
}

function Start-WatchDaemon {
    # 起后台守护（已有一个在跑就不重复起）
    Ensure-Dir (Join-Path $Script:HomeDir 'logs')
    $alive = Test-WatchAlive
    if ($alive -gt 0) { return $alive }
    $stopF = Join-Path $Script:HomeDir 'logs\watch.stop'
    if (Test-Path -LiteralPath $stopF) { Remove-Item -LiteralPath $stopF -Force -ErrorAction SilentlyContinue }
    # 路径内嵌引号，防路径带空格被截断
    $pa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $Script:DfPath + '"'), 'farm', 'watch', 'run')
    $pr = Start-Process -FilePath 'powershell.exe' -ArgumentList $pa -WindowStyle Hidden -PassThru
    [System.IO.File]::WriteAllText((Join-Path $Script:HomeDir 'logs\watch.pid'), ([string]$pr.Id), $Script:Utf8NoBom)
    return $pr.Id
}

function Ensure-Watch {
    # 强制收纳的入口：任何 farm 操作都确保守护在跑（除非 farm watch off 显式关了总开关）
    # 静默失败：收纳是保障能力，不能因为它起不来挡住业务命令
    try {
        if (-not (Get-FarmWatchEnabled)) { return }
        $null = Start-WatchDaemon
    } catch { }
}

function Get-FarmWatchAdopt {
    # 收纳模式（watchAdopt）三态：
    #   see    = 默认：非白名单的外部浏览器纳管（看得见、不杀、面板能管）
    #   strong = 非白名单的外部浏览器出现就强收编转正（kill 自起 → 池子 profile 同端口重起 → 带回首页）
    #            给 Agent 专机用；共机上会误杀其它工具的长驻浏览器，慎开
    #   off    = 守护只做回收+清理，不收纳（测试环境/纯自用模式）
    # 兼容：老配置里的 true→see、false→off
    $v = 'see'
    $f = Get-FarmFile
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.PSObject.Properties['watchAdopt'] -and $null -ne $j.watchAdopt) {
                $raw = ([string]$j.watchAdopt).ToLower()
                if ($raw -eq 'true') { $v = 'see' }
                elseif ($raw -eq 'false') { $v = 'off' }
                elseif (@('see', 'strong', 'off') -contains $raw) { $v = $raw }
            }
        } catch { }
    }
    return $v
}

function Farm-Watch([string]$mode) {
    $stopF = Join-Path $Script:HomeDir 'logs\watch.stop'
    if ($mode -eq 'off' -or $mode -eq 'stop') {
        Ensure-Dir (Join-Path $Script:HomeDir 'logs')
        Set-FarmWatchEnabled $false
        [System.IO.File]::WriteAllText($stopF, (Get-Date).ToString('o'), $Script:Utf8NoBom)
        W-Ok '收纳守护已关（总开关 watchEnabled=false，之后的 farm 命令不会再拉起）'
        W-Info '重新开：farm watch on'
        return 0
    }
    if ($mode -eq 'on' -or $mode -eq '' -or $mode -eq 'start') {
        Set-FarmWatchEnabled $true
        $pidNew = Start-WatchDaemon
        $ports = @(Get-FarmAutoAdoptPorts)
        W-Ok ('收纳守护已开（PID ' + $pidNew + '），强制纳管名单外的带端口浏览器；强收编名单：' + ($(if ($ports.Count) { $ports -join ',' } else { '空（只纳管不杀）' })))
        W-Info '白名单跳过：farm whitelist 9333,9444    停止：farm watch off'
        return 0
    }
    if ($mode -and $mode -match '^[\d,]+$') {
        Save-FarmAutoAdoptPorts @($mode -split ',' )
        Set-FarmWatchEnabled $true
        $null = Start-WatchDaemon
        W-Ok ('强收编名单已保存并生效：' + $mode + '（名单内的端口出现就整份收编，需重登一次）')
        return 0
    }
    if ($mode -eq 'run') {
        # 守护本体（被后台调起时走这里）：纳管外部浏览器 + 回收空闲实例/标签页
        Ensure-Dir (Join-Path $Script:HomeDir 'logs')
        if (Test-Path -LiteralPath $stopF) { Remove-Item -LiteralPath $stopF -Force -ErrorAction SilentlyContinue }
        $log = Join-Path $Script:HomeDir 'logs\watch.log'
        Add-Content -Path $log -Value ('[' + (Get-Date).ToString('s') + '] 守护启动，收纳模式：' + (Get-FarmWatchAdopt) + '，强收编名单：' + ($(if (@(Get-FarmAutoAdoptPorts).Count) { @(Get-FarmAutoAdoptPorts) -join ',' } else { '空' }))) -Encoding UTF8
        while (-not (Test-Path -LiteralPath $stopF)) {
            $adoptMode = Get-FarmWatchAdopt
            if ($adoptMode -ne 'off') {
                $pl = @(Get-FarmAutoAdoptPorts)
                foreach ($r in @(Get-ExternalBrowsers)) {
                    if ($r.excluded -or $r.managed) { continue }
                    if ($adoptMode -eq 'strong' -or ($pl -contains $r.port)) {
                        # strong 模式或命中强收编名单：整份收编转正（关掉自起 → 池子 profile 同端口重起，要重登一次）
                        Add-Content -Path $log -Value ('[' + (Get-Date).ToString('s') + '] ' + $(if ($adoptMode -eq 'strong') { 'strong 模式' } else { '命中名单' }) + '，收编端口 ' + $r.port) -Encoding UTF8
                        $null = Farm-Adopt ([string]$r.port)
                    } else {
                        # 名单外（see 模式）：直接纳管（不杀、不换 profile，登录态保留，立刻能 park/关）
                        $att = Farm-Attach ([int]$r.port)
                        if ($att) {
                            Add-Content -Path $log -Value ('[' + (Get-Date).ToString('s') + '] 已纳管端口 ' + $r.port + ' → ' + $att.name + '（可 park / 关闭）') -Encoding UTF8
                        }
                    }
                }
            }
            $null = Farm-DetachStale
            $null = Invoke-FarmRecycleSweep $true
            Start-Sleep -Seconds 3
        }
        Add-Content -Path $log -Value ('[' + (Get-Date).ToString('s') + '] 守护停止') -Encoding UTF8
        return 0
    }
    W-Bad ('不认识的 watch 参数：' + $mode + '（on / off / 端口名单）')
    return 4
}

function Farm-Attach([int]$port) {
    # 纳管：把外部浏览器直接登记进池子，不杀进程、不换 profile，登录态原样保留
    $info = @(Get-ExternalBrowsers) | Where-Object { [int]$_.port -eq $port } | Select-Object -First 1
    if (-not $info) { return $null }
    $list = @(Get-FarmInstances)
    if (@($list | Where-Object { [int]$_.port -eq $port }).Count -gt 0) { return $null }
    $nm = '外部' + $port
    try {
        $pg = @(Get-CdpPages $port | Where-Object { $_.url -and $_.url -notmatch '^(devtools|chrome|about|edge)' } | Select-Object -First 1)
        if ($pg.Count -gt 0) {
            $t = [string]$pg[0].title
            if ($t) {
                $t = ($t -replace '[\\/:*?"<>|]', ' ').Trim()
                if ($t.Length -gt 16) { $t = $t.Substring(0, 16) }
                $t = $t.Trim()
                if ($t) { $nm = $t }
            }
        }
    } catch { }
    $base = $nm
    $i = 2
    while (@($list | Where-Object { [string]$_.name -eq $nm }).Count -gt 0) { $nm = $base + $i; $i = $i + 1 }
    $item = [pscustomobject]@{ name = $nm; port = $port; headless = $false; lean = $false; external = $true; profile = [string]$info.profile; pid = [int]$info.pid; attachedAt = (Get-Date).ToString('s') }
    $list += $item
    Save-FarmInstances $list
    try {
        $rec = @{ ts = (Get-Date).ToString('s'); name = $nm; task = ('纳管 · ' + $nm); taskId = ($nm + '#attach'); act = 'attach'; text = ('纳管外部实例 端口 ' + $port + '（登录态保留，可 park / 关闭）'); url = '' }
        Add-Content -Path (Join-Path $Script:HomeDir 'logs\activity.jsonl') -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8
    } catch { }
    return $item
}

function Farm-DetachStale {
    # 外部实例被关掉后自动从登记表移除（只在端口不通时动手）
    $list = @(Get-FarmInstances)
    $keep = @()
    $dropped = 0
    foreach ($it in $list) {
        $isExt = $false
        try { $isExt = [bool]$it.external } catch { }
        if ($isExt) {
            $okD = $false
            try { $okD = [bool](Test-CdpReady ([int]$it.port)) } catch { }
            if (-not $okD) { $dropped = $dropped + 1; continue }
        }
        $keep += $it
    }
    if ($dropped -gt 0) { Save-FarmInstances $keep }
    return $dropped
}

# ---------- 空闲回收：实例超时关（保 profile），死 tab 超时关（保底留 1 页） ----------
function Get-FarmRecycleConfig {
    # idleMin：实例空闲几分钟关（0=关掉这层回收）；tabIdleMin：标签页几分钟没动静关（0=关掉）
    $cfg = @{ idleMin = 30; tabIdleMin = 15 }
    $f = Get-FarmFile
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.PSObject.Properties['idleMin'] -and $null -ne $j.idleMin) { $cfg.idleMin = [int]$j.idleMin }
            if ($j.PSObject.Properties['tabIdleMin'] -and $null -ne $j.tabIdleMin) { $cfg.tabIdleMin = [int]$j.tabIdleMin }
        } catch { }
    }
    return $cfg
}

function Set-FarmRecycleConfig([int]$idleMin, [int]$tabIdleMin) {
    Update-FarmFile @{ idleMin = $idleMin; tabIdleMin = $tabIdleMin }
}

function Get-InstanceIdleMinutes {
    # 每个实例「几分钟没动静」= 距上次 lastUsedAt / 上次页面活动事件 的较大者
    # 活动日志只在面板服务活着时采集；所以 lastUsedAt（每次 open/goto/tabnew/task 都刷新）是兜底信号
    $map = @{}
    foreach ($it in @(Get-FarmInstances)) {
        $nm = [string]$it.name
        # 时间戳按优先级取，不是取最大：lastUsedAt 是「最后使用」信号（open/goto/tabnew/task 都刷新），
        # attachedAt / createdAt 只是它缺失时的兜底。取最大会让 backdate 的 lastUsedAt 被 createdAt 盖掉，
        # idle 永远≈0、回收永远不触发（实测踩过）
        $last = $null
        foreach ($k in @('lastUsedAt', 'attachedAt', 'createdAt')) {
            try {
                $v = [string]$it.$k
                if ($v) { $last = [datetime]::Parse($v); break }
            } catch { }
        }
        if ($last) { $map[$nm] = ((Get-Date) - $last).TotalMinutes } else { $map[$nm] = -1 }   # -1 = 没时间戳可判，保守不回收
    }
    $f = Join-Path $Script:HomeDir 'logs\activity.jsonl'
    if (Test-Path -LiteralPath $f) {
        try {
            foreach ($ln in @(Get-Content -LiteralPath $f -Tail 400 -Encoding UTF8)) {
                if (-not $ln) { continue }
                try {
                    $e = $ln | ConvertFrom-Json
                    $nm = [string]$e.name
                    if (-not $nm) { continue }
                    $t = [datetime]::Parse([string]$e.ts)
                    $idleMin = ((Get-Date) - $t).TotalMinutes
                    if ($idleMin -lt 0) { $idleMin = 0 }
                    if (-not $map.ContainsKey($nm) -or ($map[$nm] -gt $idleMin)) { $map[$nm] = $idleMin }
                } catch { }
            }
        } catch { }
    }
    return $map
}

function Test-PortClients([int]$port) {
    # 这个调试端口上有没有「别的进程」连着（CDP WebSocket / HTTP 客户端）——连着 = 任务正在驱动，绝不回收
    # 必须查 RemotePort 侧（客户端行，OwningProcess=连它的进程）并排除自己：
    # 查 LocalPort 会查到 Chrome 服务端行（无意义）；不排除自己则 sweep 前一步 Test-CdpReady
    # 留下的 HTTP keep-alive 连接会把实例永远误判成「忙碌」（实测踩过：回收从来没生效过）
    try {
        $rows = @(Get-NetTCPConnection -RemotePort $port -State Established -ErrorAction SilentlyContinue |
            Where-Object { [int]$_.OwningProcess -ne $PID })
        return ($rows.Count -gt 0)
    } catch { return $false }
}

function Write-FarmActivity([string]$name, [string]$taskName, [string]$taskId, [string]$act, [string]$text, [string]$url = '') {
    try {
        $dir = Join-Path $Script:HomeDir 'logs'
        Ensure-Dir $dir
        $rec = @{ ts = (Get-Date).ToString('s'); name = $name; task = $taskName; taskId = $taskId; act = $act; text = $text; url = $url }
        [System.IO.File]::AppendAllText((Join-Path $dir 'activity.jsonl'), (($rec | ConvertTo-Json -Compress) + "`n"), $Script:Utf8NoBom)
    } catch { }
}

function Invoke-FarmRecycleSweep([bool]$Quiet = $false) {
    # 回收一轮：先清死 tab（实例还活着），再关空闲实例。两个保底：有客户端连接的不动、没时间戳可判的不动
    $cfg = Get-FarmRecycleConfig
    $r = @{ closedInstances = @(); closedTabs = @(); skippedBusy = @() }
    $log = Join-Path $Script:HomeDir 'logs\watch.log'
    $idleMap = Get-InstanceIdleMinutes

    # ---- 标签页级回收：URL 在近 tabIdleMin 分钟没出现在活动日志里 → 关（about:blank / 内置页不关，保底留 1 页）----
    if ($cfg.tabIdleMin -gt 0) {
        $cut = (Get-Date).AddMinutes(-1 * $cfg.tabIdleMin)
        $recentUrls = @()       # 窗口内出现过的 (name → url集合)
        $recentByInst = @{}
        $f = Join-Path $Script:HomeDir 'logs\activity.jsonl'
        if (Test-Path -LiteralPath $f) {
            try {
                foreach ($ln in @(Get-Content -LiteralPath $f -Tail 400 -Encoding UTF8)) {
                    if (-not $ln) { continue }
                    try {
                        $e = $ln | ConvertFrom-Json
                        $t = [datetime]::Parse([string]$e.ts)
                        if ($t -lt $cut) { continue }
                        $nm = [string]$e.name; $u = [string]$e.url
                        if ($u -and $u -notmatch '^(about:|devtools|chrome|edge:)') {
                            if (-not $recentByInst.ContainsKey($nm)) { $recentByInst[$nm] = New-Object System.Collections.ArrayList }
                            [void]$recentByInst[$nm].Add($u)
                        }
                    } catch { }
                }
            } catch { }
        }
        foreach ($it in @(Get-FarmInstances)) {
            $isExtT = $false
            try { $isExtT = [bool]$it.external } catch { }
            if ($isExtT) { continue }   # 外部纳管的浏览器不是池子起的，自动关它的 tab = 赌它没用；要纳入生命周期先 farm adopt 转正
            $port = [int]$it.port
            if (-not (Test-CdpReady $port)) { continue }
            # 保底一：端口上有客户端连接（任务正纯 CDP 驱动、不碰 farm 命令、页面也无事件）→ 一个 tab 都不动。
            # 没这道闸门时正被驱动的 tab 也会被当死页关掉，任务直接断（独立审查揪出）
            if (Test-PortClients $port) { $r.skippedBusy += [string]$it.name; continue }
            # 保底二（闸门）：实例整体近 tabIdleMin 分钟内被动过（open/goto/tabnew/task 或任何页面事件）就不清 tab
            # 没这个闸门的话，刚开出来还没产生事件的 tab（登录页、慢加载页）会被立刻误收
            $idleInst = -1.0
            if ($idleMap.ContainsKey([string]$it.name)) { $idleInst = [double]$idleMap[[string]$it.name] }
            if ($idleInst -lt $cfg.tabIdleMin) { continue }
            $tabs = @(Get-FarmTabList $port)
            if ($tabs.Count -le 1) { continue }
            $seen = @()
            if ($recentByInst.ContainsKey([string]$it.name)) { $seen = @($recentByInst[[string]$it.name]) }
            $kill = @()
            foreach ($tb in $tabs) {
                if ($tb.网址 -match '^(about:|devtools|chrome://|edge://)') { continue }
                $hot = $false
                foreach ($u in $seen) { if ((Test-UrlSameSite $u $tb.网址) -or ($u -eq $tb.网址)) { $hot = $true; break } }
                if (-not $hot) { $kill += $tb }
            }
            # 保底留 1 页：全都没动静时只关到剩 1 个
            if ((@($tabs).Count - @($kill).Count) -lt 1) { $kill = @($kill | Select-Object -First (@($tabs).Count - 1)) }
            $closedN = 0
            foreach ($tb in $kill) {
                try {
                    $null = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/close/' + $tb.id) -TimeoutSec 5
                    $closedN++
                } catch { }
            }
            if ($closedN -gt 0) {
                Write-FarmActivity ([string]$it.name) (Get-FarmTaskName $it) (Get-FarmTaskId $it) 'recycle-tab' ('回收 ' + $closedN + ' 个空闲标签页（' + $cfg.tabIdleMin + ' 分钟没动静）') ''
                $r.closedTabs += ('' + $it.name + '×' + $closedN)
                Add-Content -Path $log -Value ('[' + (Get-Date).ToString('s') + '] 回收标签页：' + $it.name + ' 关 ' + $closedN + ' 个（剩 ' + (@(Get-FarmTabList $port).Count) + '）') -Encoding UTF8
            }
        }
    }

    # ---- 实例级回收：池子亲生的实例空闲超 idleMin 分钟且没有客户端连接 → 关进程（登记与 profile 都保留）----
    # 外部纳管的实例不自动回收：它不是池子起的，关了可能砸了别的工具的长驻任务；要纳入生命周期先 farm adopt 转正
    if ($cfg.idleMin -gt 0) {
        foreach ($it in @(Get-FarmInstances)) {
            $isExtI = $false
            try { $isExtI = [bool]$it.external } catch { }
            if ($isExtI) { continue }
            $nm = [string]$it.name
            $port = [int]$it.port
            if (-not (Test-CdpReady $port)) { continue }
            if (Test-PortClients $port) { $r.skippedBusy += $nm; continue }
            $idle = 0.0
            if ($idleMap.ContainsKey($nm)) { $idle = [double]$idleMap[$nm] } else { continue }
            if ($idle -lt 0) { continue }             # 没时间戳可判，保守不动
            if ($idle -lt $cfg.idleMin) { continue }
            $killed = Stop-BrowserByPort $port (Get-FarmId $nm)
            if ($killed -gt 0) {
                Write-FarmActivity $nm (Get-FarmTaskName $it) (Get-FarmTaskId $it) 'recycle' ('空闲 ' + [int]$idle + ' 分钟，实例已回收（登录态保留在 profile）') ''
                $r.closedInstances += $nm
                Add-Content -Path $log -Value ('[' + (Get-Date).ToString('s') + '] 回收实例：' + $nm + ' 空闲 ' + [int]$idle + ' 分钟已关（profile 保留）') -Encoding UTF8
            }
        }
    }

    if (-not $Quiet) {
        if ($r.closedInstances.Count -gt 0) { W-Ok ('已关空闲实例：' + ($r.closedInstances -join '、')) }
        if ($r.closedTabs.Count -gt 0) { W-Ok ('已关空闲标签页：' + ($r.closedTabs -join '、')) }
        if (($r.closedInstances.Count -eq 0) -and ($r.closedTabs.Count -eq 0)) { W-Info ('这轮没得回收（忙碌跳过 ' + $r.skippedBusy.Count + ' 个）') }
    }
    return $r
}

# ---------- 自动收编：扫本机带调试端口的浏览器，可一键收进池子（2026-11-20 定） ----------
function Get-FarmExcludePorts {
    # 工具浏览器白名单：这些端口属于 agent 自身或其它系统，不收编、不杀
    $d = @(9222, 9223)
    $f = Get-FarmFile
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.PSObject.Properties['excludePorts'] -and $j.excludePorts) { $d = @($j.excludePorts | ForEach-Object { [int]$_ }) }
        } catch { }
    }
    return $d
}

function Get-BrowsersFromProcs($procs, $registeredPorts, $excludePorts) {
    # 纯函数：从 Win32_Process 快照里解析带调试端口的浏览器（拆出来是为了能拿假进程对象做测试）
    # 放宽：没带 --user-data-dir 的也看得见（Agent 技能开法五花八门，profile 记空、纳管不杀不需要它）
    $reg = @{}
    foreach ($k in @($registeredPorts.Keys)) { try { $reg[[int]$k] = $true } catch { } }
    $ex = @($excludePorts)
    $out = @()
    foreach ($p in @($procs)) {
        $cl = [string]$p.CommandLine
        if (-not $cl) { continue }
        if ($cl -notmatch '--remote-debugging-port=(\d+)') { continue }
        if ($cl -match '--type=') { continue }
        $port = [int]$Matches[1]
        $prof = ''
        if ($cl -match '--user-data-dir=(?:"([^"]+)"|(\S+))') { $prof = if ($Matches[1]) { $Matches[1] } else { $Matches[2] } }
        if (@($out | Where-Object { $_.port -eq $port }).Count -gt 0) { continue }
        $isReg = $reg.ContainsKey($port)
        $out += [pscustomobject]@{
            port     = $port
            pid      = [int]$p.ProcessId
            profile  = $prof
            managed  = $isReg
            name     = $(if ($isReg) { [string]$registeredPorts[[int]$port] } else { '' })
            excluded = ($ex -contains $port)
        }
    }
    return $out
}

function Get-ExternalBrowsers {
    $regH = @{}
    foreach ($i in (Get-FarmInstances)) { $regH[[int]$i.port] = [string]$i.name }
    try { $procs = @(Get-ProcSnapshot) } catch { return @() }
    if (@($procs).Count -eq 0) { return @() }
    return (Get-BrowsersFromProcs $procs $regH @(Get-FarmExcludePorts))
}

function Farm-Scan {
    $rows = @(Get-ExternalBrowsers)
    W-Title '扫本机带调试端口的浏览器'
    if ($rows.Count -eq 0) { W-Info '一个也没扫到'; return 0 }
    foreach ($r in $rows) {
        $tag = if ($r.excluded) { '工具·不动' } elseif ($r.managed) { ('已登记:' + $r.name) } else { '未登记·可收编' }
        W-Info (('{0,5}  PID {1,-7} {2,16}  {3}' -f $r.port, $r.pid, $tag, $r.profile))
    }
    W-Info '收编：farm adopt <端口> [新名字]'
    return 0
}

function Farm-Adopt([string]$target, [string]$newName = '') {
    if (-not $target) { W-Bad '用法：farm adopt <端口|PID> [新名字]'; return 4 }
    $rows = @(Get-ExternalBrowsers)
    $hit = @()
    if ($target -match '^\d+$') {
        $n = [int]$target
        $hit = @($rows | Where-Object { $_.port -eq $n })
        if ($hit.Count -eq 0) { $hit = @($rows | Where-Object { $_.pid -eq $n }) }
    } else {
        $hit = @($rows | Where-Object { $_.name -eq $target })
    }
    if ($hit.Count -eq 0) { W-Bad ('没找到这个实例：' + $target + '（先 farm scan 看有哪些）'); return 4 }
    $r = $hit[0]
    if ($r.excluded) { W-Bad ('端口 ' + $r.port + ' 在工具白名单里，不收编也不杀'); return 3 }
    if ($r.managed) { W-Bad ('端口 ' + $r.port + ' 已经登记成 ' + $r.name + '，不用收编'); return 3 }
    $urls = @()
    try { $urls = @(Get-CdpPages $r.port | Where-Object { $_.url -and ($_.url -notmatch '^(devtools|chrome|chrome-extension|about|edge)') } | ForEach-Object { [string]$_.url }) } catch { }
    $page = if ($urls.Count -gt 0) { $urls[0] } else { 'about:blank' }
    if (-not $newName) { $newName = ('收编' + $r.port) }
    W-Info ('收编端口 ' + $r.port + ' → 名字 ' + $newName + '，带过去首页 ' + $page)
    if ($urls.Count -gt 1) { W-Warn ('另有 ' + ($urls.Count - 1) + ' 个标签页不会带过去') }
    W-Warn '这一步会关掉原浏览器；原 profile 的登录态留在原处，池子用新 profile，需要重登一次'
    try { $null = & taskkill /PID $r.pid /T /F 2>&1 } catch { }
    Start-Sleep -Milliseconds 1200
    if (Test-CdpReady $r.port) { W-Bad '原实例还活着，收编中止（没有强杀成功）'; return 5 }
    # 预登记原端口再重起：Farm-Start 对已登记端口不换号——技能侧认的端口不变，收编后无感直连
    # （底版这里实际会换端口，与文档「同一个端口重起」不符，技能侧会断线找不到——2026-11-20 修）
    $listAd = @(Get-FarmInstances)
    if (@($listAd | Where-Object { [string]$_.name -eq $newName }).Count -eq 0) {
        $listAd += [pscustomobject]@{ name = $newName; port = [int]$r.port }
        Update-FarmFile @{} -Instances @($listAd)
    }
    $g = Farm-Start $newName $page
    if (-not $g.ok) { W-Bad ('重起失败：' + $g.error); return 5 }
    W-Ok ('已收编：' + $newName + ' 端口 ' + $g.port + '，profile 归池子，登录一次之后长期有效')
    return 0
}

# ---------- 任务分段：日志按任务分开 ----------
function Get-FarmTaskName($it) {
    $n = ''
    try { if ($it -and $it.PSObject.Properties['task'] -and $it.task) { $n = [string]$it.task.name } } catch { }
    return $n
}
function Get-FarmTaskId($it) {
    $n = ''
    try { if ($it -and $it.PSObject.Properties['task'] -and $it.task) { $n = [string]$it.task.id } } catch { }
    return $n
}

function New-FarmTask([string]$name, [string]$taskName = '') {
    # 开一个新的任务段：之后的浏览器操作全归到这个任务下，直到下次开新段
    $list = @(Get-FarmInstances)
    $target = $null
    foreach ($it in $list) { if ([string]$it.name -eq $name) { $target = $it; break } }
    if (-not $target) { return $null }
    $now = Get-Date
    $id = ($name + '#' + $now.ToString('yyyyMMddHHmmss'))
    if (-not $taskName) { $taskName = ($name + ' ' + $now.ToString('HH:mm')) }
    $obj = [ordered]@{ id = $id; name = $taskName; startedAt = $now.ToString('s') }
    $target | Add-Member -NotePropertyName task -NotePropertyValue $obj -Force
    Save-FarmInstances $list
    return $id
}

function Ensure-FarmTask([string]$name) {
    # 没有任务段就开一个；已有但超过 30 分钟也换新段（业务脚本可以调 farm task 自己命名）
    $it = Get-FarmItem $name
    if (-not $it) { return }
    $tid = Get-FarmTaskId $it
    if ($tid) {
        $st = ''
        try { $st = [string]$it.task.startedAt } catch { }
        if ($st) {
            $age = 0.0
            try { $age = ((Get-Date) - [datetime]::Parse($st)).TotalMinutes } catch { $age = 0 }
            if ($age -lt 30) { return }
            $null = New-FarmTask $name
            return
        }
        return
    }
    $null = New-FarmTask $name
}

# ---------- 唯一浏览器：面板自动调起 ----------
function Test-PanelAlive {
    if (-not (Test-Path -LiteralPath $Script:PanelPidFile)) { return $false }
    try {
        $p = [int]((Get-Content -LiteralPath $Script:PanelPidFile -Raw).Trim())
        if ($p -le 0) { return $false }
        return [bool](Get-Process -Id $p -ErrorAction SilentlyContinue)
    } catch { return $false }
}

function Ensure-Panel([bool]$openWindow = $false) {
    # 有浏览器在用，面板就必须在；不在就拉起来（这是"存在感"的来源）
    if (-not (Test-PanelAlive)) {
        try {
            Ensure-Dir (Join-Path $Script:HomeDir 'logs')
            $pa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $Script:DfPath + '"'), 'panel', '-Bg')
            Start-Process -FilePath 'powershell.exe' -ArgumentList $pa -WindowStyle Hidden | Out-Null
            Add-Content -Path (Join-Path $Script:HomeDir 'logs\panel_auto.log') -Value ('[' + (Get-Date).ToString('s') + '] 面板不在，已自动调起') -Encoding UTF8
            Start-Sleep -Milliseconds 900
        } catch { }
    }
    if (-not $openWindow) { return }
    # 窗口开着就不再开第二个：面板页面每 15 秒写心跳，40 秒内有心跳 = 有人正看着它
    $alive = Join-Path $Script:HomeDir 'logs\panel_alive.txt'
    if (Test-Path -LiteralPath $alive) {
        try {
            $txt = ([System.IO.File]::ReadAllText($alive)).Trim()
            if ($txt) {
                $t = [datetime]::Parse($txt)
                if (((Get-Date) - $t).TotalSeconds -lt 40) {
                    try { Add-Content -Path (Join-Path $Script:HomeDir 'logs\panel_auto.log') -Value ('[' + (Get-Date).ToString('s') + '] 面板窗口开着（心跳 ' + [int](((Get-Date) - $t).TotalSeconds) + 's），不再开新窗') -Encoding UTF8 } catch { }
                    return
                }
            }
        } catch { }
    }
    try {
        Start-Process ('http://127.0.0.1:' + $Script:PanelPort + '/') | Out-Null
        try { Add-Content -Path (Join-Path $Script:HomeDir 'logs\panel_auto.log') -Value ('[' + (Get-Date).ToString('s') + '] 没有开着的面板窗口，已打开') -Encoding UTF8 } catch { }
    } catch { }
}

# ---------- 活动日志：页面内埋点（copy / paste / 日期选择 / 点击 / 跳转） ----------
function Get-ActivityHookJs {
    return @'
(function () {
  if (window.__dfHook) { return 'already'; }
  window.__dfHook = 1;
  window.__dfq = window.__dfq || [];
  function push(k, v) {
    try {
      window.__dfq.push({ t: Date.now(), k: k, v: String(v == null ? '' : v).replace(/\s+/g, ' ').slice(0, 140) });
      if (window.__dfq.length > 400) { window.__dfq.splice(0, 200); }
    } catch (e) { }
  }
  ['copy', 'paste', 'cut'].forEach(function (ev) {
    document.addEventListener(ev, function (e) {
      var v = '';
      try {
        if (ev !== 'paste' && window.getSelection) { v = String(window.getSelection()); }
        if (!v && e.target && e.target.value !== undefined) { v = e.target.value; }
      } catch (_) { }
      push(ev, v);
    }, true);
  });
  document.addEventListener('change', function (e) {
    var el = e.target; if (!el) { return; }
    var ty = String(el.type || '').toLowerCase();
    var tag = String(el.tagName || '').toLowerCase();
    if (ty === 'date' || ty === 'datetime-local' || ty === 'month' || ty === 'week') { push('date', el.value); }
    else if (tag === 'select') { push('select', el.value); }
    else if (tag === 'input' || tag === 'textarea') { push('input', el.value); }
  }, true);
  document.addEventListener('click', function (e) {
    var el = e.target; if (!el) { return; }
    try {
      var path = e.composedPath ? e.composedPath() : [el];
      var pick = el;
      for (var i = 0; i < path.length; i++) {
        var t = String(path[i].tagName || '').toLowerCase();
        if (t === 'button' || t === 'a' || t === 'input') { pick = path[i]; break; }
      }
      var txt = pick.innerText || pick.value || pick.getAttribute('aria-label') || pick.getAttribute('placeholder') || '';
      var ty = String(pick.type || '').toLowerCase();
      if (ty === 'date' || ty === 'datetime-local') { push('open-date', txt || 'date-picker'); return; }
      if (String(pick.tagName || '').toLowerCase() === 'input' && ty === 'checkbox') { push('check', pick.checked); return; }
      push('click', txt || String(pick.tagName || ''));
    } catch (_) { }
  }, true);
  window.addEventListener('pagehide', function () { push('leave', location.href); });
  push('load', location.href);
  return 'installed';
})();
'@
}

function Install-ActivityHook([int]$port) {
    try {
        $js = Get-ActivityHookJs
        $pages = @(Get-CdpPages $port)
        if ($pages.Count -eq 0) { return $false }
        foreach ($page in $pages) {
            try {
                $null = Invoke-CdpWs $page.webSocketDebuggerUrl 'Page.addScriptToEvaluateOnNewDocument' @{ source = $js } 8
                $null = Invoke-CdpWs $page.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = $js; returnByValue = $true } 8
            } catch { }
        }
        return $true
    } catch { return $false }
}

function Rotate-ActivityLog([string]$f) {
    try {
        if (-not (Test-Path -LiteralPath $f)) { return }
        if ((Get-Item -LiteralPath $f).Length -lt 3145728) { return }
        $tail = @(Get-Content -LiteralPath $f -Tail 2000 -Encoding UTF8)
        [System.IO.File]::WriteAllText($f, (($tail -join "`n") + "`n"), $Script:Utf8NoBom)
    } catch { }
}

function Drain-FarmActivity([string]$OnlyName = '') {
    # 把各实例页面里攒的操作事件取出来，写 logs\activity.jsonl；顺手补埋点
    # -OnlyName 只处理一个实例：面板按请求轮转调用，避免一次遍历全部实例把面板卡住
    $f = Join-Path $Script:HomeDir 'logs\activity.jsonl'
    Ensure-Dir (Split-Path $f)
    $n = 0
    foreach ($it in @(Get-FarmInstances)) {
        if ($OnlyName -and ([string]$it.name -ne $OnlyName)) { continue }
        $port = [int]$it.port
        if (-not (Test-CdpReady $port)) { continue }
        try {
            $pages = @(Get-CdpPages $port)
            if ($pages.Count -eq 0) { continue }
            $jsHook = $null
            foreach ($page in $pages) {
                try {
                    $probe = Invoke-CdpWs $page.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = 'String(window.__dfHook||0)'; returnByValue = $true } 8
                    if ([string]$probe.result.value -ne '1') {
                        if (-not $jsHook) { $jsHook = Get-ActivityHookJs }
                        $null = Invoke-CdpWs $page.webSocketDebuggerUrl 'Page.addScriptToEvaluateOnNewDocument' @{ source = $jsHook } 8
                        $null = Invoke-CdpWs $page.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = $jsHook; returnByValue = $true } 8
                    }
                    $r = Invoke-CdpWs $page.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = 'JSON.stringify((window.__dfq||[]).splice(0,500))'; returnByValue = $true } 8
                    $txt = [string]$r.result.value
                    if (-not $txt -or $txt -eq '[]') { continue }
                    $parsed = $txt | ConvertFrom-Json
                    $evs = @($parsed)
                    if ($evs.Count -eq 1 -and ($evs[0] -is [System.Array])) { $evs = @($evs[0]) }
                    $lines = @()
                    foreach ($e in $evs) {
                        $t = [long]0
                        try { $t = [long]$e.t } catch { }
                        if ($t -le 0) { continue }
                        if ([string]$e.k -eq 'load' -and -not [string]$e.v) { $e.v = $page.title }
                        $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($t).LocalDateTime
                        $lines += ([ordered]@{ ts = $dt.ToString('s'); name = [string]$it.name; task = (Get-FarmTaskName $it); taskId = (Get-FarmTaskId $it); act = [string]$e.k; text = [string]$e.v; url = [string]$page.url } | ConvertTo-Json -Compress)
                    }
                    if ($lines.Count -gt 0) {
                        [System.IO.File]::AppendAllText($f, (($lines -join "`n") + "`n"), $Script:Utf8NoBom)
                        $n += $lines.Count
                    }
                } catch { }
            }
        } catch { }
    }
    Rotate-ActivityLog $f
    return $n
}

function Add-Alert([string]$name, [string]$level, [string]$msg) {
    # 告警通道：业务脚本往这里写，外部定时任务扫 logs\alerts.jsonl 里 pushed=false 的发消息
    $dir = Join-Path $Script:HomeDir 'logs'
    Ensure-Dir $dir
    $f = Join-Path $dir 'alerts.jsonl'
    $o = [ordered]@{ ts = (Get-Date).ToString('s'); name = $name; level = $level; msg = $msg; pushed = $false }
    [System.IO.File]::AppendAllText($f, (($o | ConvertTo-Json -Compress) + "`n"), $Script:Utf8NoBom)
    return @{ ok = $true; file = $f }
}

function Convert-JsonArray([string]$text) {
    # PS 5.1 的 ConvertFrom-Json 遇到数组根会把整个数组当成 1 个对象（后续 Where-Object 会误判），这里手动摊平
    $parsed = $text | ConvertFrom-Json
    $list = @()
    foreach ($x in $parsed) { $list += $x }
    return $list
}

function Get-FarmTabList([int]$port) {
    $out = @()
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/list') -TimeoutSec 3
        $all = @(Convert-JsonArray $r.Content)
        $i = 0
        foreach ($t in $all) {
            if ($t.type -ne 'page') { continue }
            $i++
            $out += [pscustomobject]@{ 序号 = $i; 标题 = [string]$t.title; 网址 = [string]$t.url; id = [string]$t.id }
        }
    }
    catch { }
    return $out
}

function Farm-TabClose([string]$name, [string]$which) {
    $item = Get-FarmItem $name
    if (-not $item) { W-Bad ('没有这个实例：' + $name); return 4 }
    $port = [int]$item.port
    if (-not (Test-CdpReady $port)) { W-Bad ($name + ' 没在跑（先 farm open）'); return 4 }
    $tabs = @(Get-FarmTabList $port)
    if ($tabs.Count -eq 0) { W-Info ($name + ' 没有可关的标签页'); return 0 }
    $targets = @()
    if ($which -eq 'all' -or $which -eq '') {
        # 只留一个：优先留「不是 about:blank 的最后那个」（一般是你正在看的那页），否则留第 1 个
        if ($tabs.Count -le 1) { W-Info ($name + ' 只有 1 个标签页，不用关'); return 0 }
        $keep = @($tabs | Where-Object { $_.网址 -ne 'about:blank' }) | Select-Object -Last 1
        if (-not $keep) { $keep = $tabs[0] }
        $targets = @($tabs | Where-Object { $_.id -ne $keep.id })
    }
    elseif ($which -match '^\d+$') {
        $n = [int]$which
        $hit = @($tabs | Where-Object { $_.序号 -eq $n })
        if (-not $hit) { W-Bad ('没有第 ' + $n + ' 个标签页（共 ' + $tabs.Count + ' 个）'); return 4 }
        $targets = @($hit)
    }
    else { W-Bad ('要关哪个？给序号，或 all = 只留第一个'); return 1 }
    $closed = 0
    foreach ($t in $targets) {
        try {
            $null = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/close/' + $t.id) -TimeoutSec 5
            $closed++
        }
        catch { }
    }
    Farm-Touch $name
    W-Ok ('关了 ' + $closed + ' 个标签页，' + $name + ' 还剩 ' + (@(Get-FarmTabList $port).Count) + ' 个')
    return 0
}

function Get-FarmVisibleTabs([int]$port, $item) {
    # 切换无头↔有头要重启进程，先把标签页按序记全（底版只记一页，其余全丢）
    $urls = @()
    try { $urls = @(Get-FarmTabList $port | ForEach-Object { [string]$_.网址 } | Where-Object { $_ -and ($_ -notmatch '^(about:blank|devtools|chrome://|edge://)$') }) } catch { }
    if ($urls.Count -eq 0) {
        try { $u = [string](Get-CdpPage $port).url; if ($u) { $urls = @($u) } } catch { }
    }
    if ($urls.Count -eq 0) { $urls = @([string]$item.url) }
    return @($urls | Where-Object { $_ })
}

function Restore-FarmTabs([string]$name, [string[]]$urls) {
    # 第 1 个网址是重启时的启动页，其余按序补开回来
    $n = 0
    foreach ($u in @($urls | Select-Object -Skip 1)) {
        try { $null = Farm-TabNew $name ([string]$u); $n++ } catch { }
    }
    return $n
}

function Set-FarmVisible([string]$name, [bool]$visible) {
    $item = Get-FarmItem $name
    if (-not $item) { return @{ ok = $false; error = ('没有这个实例：' + $name + '（先 farm open）') } }
    $port = [int]$item.port
    $running = Test-CdpReady $port
    $mode = $(if ($running) { Get-BrowserMode $port } else { '' })
    $tabUrls = @(Get-FarmVisibleTabs $port $item)
    $url = [string]$tabUrls[0]
    if (-not $url) { $url = [string]$item.url }
    if ($visible) {
        if ($running -and $mode -eq 'headful') {
            $okShow = Show-BrowserWindow $port
            if ($okShow) { Farm-Touch $name; return @{ ok = $true; name = $name; port = $port; mode = 'headful'; switched = $false } }
            return @{ ok = $false; error = '有头窗口没响应，试试 farm close 再 open' }
        }
        if ($running) { $null = Stop-BrowserByPort $port (Get-FarmId $name) }
        $st = Farm-Start $name $url $false
        if (-not $st.ok) { return @{ ok = $false; error = $st.error } }
        $restored = Restore-FarmTabs $name $tabUrls
        $null = Show-BrowserWindow $port
        return @{ ok = $true; name = $name; port = $port; mode = 'headful'; switched = $true; url = $url; tabsRestored = $restored }
    }
    else {
        if (-not $running) { return @{ ok = $true; name = $name; port = $port; mode = ''; switched = $false; msg = '本来就没开着' } }
        if ($mode -eq 'headless') { Farm-Touch $name; return @{ ok = $true; name = $name; port = $port; mode = 'headless'; switched = $false; msg = '本来就是无头在后台' } }
        $null = Stop-BrowserByPort $port (Get-FarmId $name)
        $st = Farm-Start $name $url $true
        if (-not $st.ok) { return @{ ok = $false; error = $st.error } }
        $restored = Restore-FarmTabs $name $tabUrls
        return @{ ok = $true; name = $name; port = $port; mode = 'headless'; switched = $true; url = $url; tabsRestored = $restored }
    }
}

function Invoke-Farm([string]$act, [string]$name, [string]$url) {
    Initialize-Store
    if (-not $act) { $act = 'list' }
    # 强制收纳：任何 farm 操作都确保守护在跑（watch 自身除外——off/run 不能被自己拉起）
    if ($act -ne 'watch') { Ensure-Watch }
    switch ($act) {
        'list' {
            $rows = @(Get-FarmRows)
            W-Title ('BrowserPool 浏览器池（' + $rows.Count + ' 个实例 · 上限 ' + (Get-FarmLimits).maxInstances + '）')
            if ($rows.Count -eq 0) { W-Info '还没登记任何实例：farm open <名字> [网址]'; return 0 }
            $rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
            return 0
        }
        { $_ -in @('open', 'start') } {
            $wantHeadless = $null
            if ($Headful) { $wantHeadless = $false }
            $r = Farm-Start $name $url $wantHeadless
            if (-not $r.ok) { W-Bad $r.error; return 2 }
            if ($r.reused) { W-Ok ($name + ' 已经在跑，端口 ' + $r.port + '（' + $r.mode + '）') }
            else { W-Ok ($name + ' 已启动，端口 ' + $r.port + '（' + $r.mode + '，profile ' + $r.profile + '）') }
            W-Info ('agent 调：http://127.0.0.1:' + $r.port + '   下载目录：' + $r.downloads)
            return 0
        }
        'show' {
            $r = Set-FarmVisible $name $true
            if (-not $r.ok) { W-Bad $r.error; return 2 }
            W-Ok ($name + ' 已挪到前台（端口 ' + $r.port + '，' + $r.mode + '）')
            return 0
        }
        'hide' {
            $r = Set-FarmVisible $name $false
            if (-not $r.ok) { W-Bad $r.error; return 2 }
            W-Ok ($name + ' 已收回后台（端口 ' + $r.port + '，' + $r.mode + '）')
            return 0
        }
        'park' {
            # 有头窗口挪到屏幕外：进程和页面都留着，只是不占屏幕（一次性任务预热用）
            $item = Get-FarmItem $name
            if (-not $item) { W-Bad ('没有这个实例：' + $name); return 4 }
            $port = [int]$item.port
            if (-not (Test-CdpReady $port)) { W-Warn ($name + ' 没在跑（先 farm open）'); return 0 }
            if ((Get-BrowserMode $port) -ne 'headful') { W-Info ($name + ' 本来就没窗口（无头），不用 park'); return 0 }
            if (Hide-BrowserWindow $port) { Farm-Touch $name; W-Ok ($name + ' 窗口已挪到屏幕外（端口 ' + $port + '，仍在后台跑）'); return 0 }
            W-Bad ($name + ' 挪窗口失败'); return 2
        }
        { $_ -in @('close', 'stop') } { return (Farm-Stop $name) }
        'tabs' {
            $item = Get-FarmItem $name
            if (-not $item) { W-Bad ('没有这个实例：' + $name); return 4 }
            $tabs = @(Get-FarmTabList ([int]$item.port))
            W-Title ($name + ' 的标签页（' + $tabs.Count + ' 个）')
            if ($tabs.Count -eq 0) { W-Info '实例没在跑，或没有网页标签'; return 0 }
            $tabs | Select-Object 序号, 标题, 网址 | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
            return 0
        }
        'tabclose' { return (Farm-TabClose $name $url) }
        'task' {
            if (-not $name) { W-Bad '用法：farm task <实例> [任务名]'; return 4 }
            $tid = New-FarmTask $name $url
            if (-not $tid) { W-Bad ('没有这个实例：' + $name); return 4 }
            W-Ok ('已开新任务段：' + $(if ($url) { $url } else { '默认名' }) + '  (' + $tid + ')')
            return 0
        }
        'alert' {
            # farm alert <名字> <级别>|<消息>  —— 级别 info / warn / error，缺省 info
            $raw = [string]$url
            $level = 'info'
            $msg = $raw
            # 两种写法都支持：farm alert <名字> 'warn|消息'   或   farm alert <名字> warn 消息
            if ($Rest -and @($Rest).Count -gt 0) {
                $level = ([string]$raw).ToLower()
                $msg = (@($Rest) -join ' ')
            } elseif ($raw -match '^([a-zA-Z]+)[\|:](.+)$') { $level = $Matches[1].ToLower(); $msg = $Matches[2] }
            if (@('info','warn','error') -notcontains $level) { $level = 'info' }
            if (-not $name -or -not $msg) { W-Bad '用法：farm alert <名字> <info|warn|error> 消息   （或 <名字> ''warn|消息''）'; return 4 }
            $null = Add-Alert $name $level $msg
            W-Ok ('已记录告警：' + $name + ' [' + $level + '] ' + $msg)
            return 0
        }
        'apps' {
            $rows = @(Get-AppsPayload)
            if ($rows.Count -eq 0) { W-Warn 'webapps.json 里还没有后台'; return 0 }
            foreach ($r in $rows) {
                $st = '实例没起'
                if ($r.open) { $st = '已打开' } elseif ($r.live) { $st = '实例在跑·页面没开' }
                W-Ok ('{0}  [:{1}]  {2}  实例={3}  {4}' -f $r.app, $r.port, $st, $r.instance, $r.url)
            }
            return 0
        }
        'tabnew' {
            $r = Farm-TabNew $name $url
            if (-not $r.ok) { W-Bad $r.error; return 2 }
            W-Ok ($name + ' 新标签页 → ' + $r.url + '（端口 ' + $r.port + '）')
            return 0
        }
        'forget' { return (Farm-Forget $name) }
        'scan' { return (Farm-Scan) }
        'port' {
            # 端口唯一映射查询：实例名 ↔ 端口（派生规则：MD5 前四字节 mod 40 → 9360-9399）
            if (-not $name) { W-Bad '用法：farm port <名字>（查这个实例的端口）'; return 4 }
            $itP = Get-FarmItem $name
            $derP = Get-DerivedPort $name
            if ($itP -and [int]$itP.port -gt 0) {
                $tagP = $(if ([int]$itP.port -eq $derP) { '（=派生值，同名跨机器一致）' } else { '（派生值 ' + $derP + ' 被占/撞车后探过，以这个为准）' })
                W-Ok ($name + ' 端口 ' + [int]$itP.port + $tagP)
            }
            else {
                W-Info ($name + ' 还没登记；派生端口 ' + $derP + '（farm open 后以输出为准）')
            }
            W-Info 'agent 拿端口请以 farm open 输出 / farm port 查询为准，别自己算'
            return 0
        }
        'watch' {
            if ($name -eq 'adopt') {
                # farm watch adopt see|strong|off：收纳模式三态（on 是 see 的别名，兼容老写法）
                $md = ([string]$url).ToLower()
                if ($md -eq 'off') { Update-FarmFile @{ watchAdopt = 'off' }; W-Ok '收纳模式=off：守护只回收+清理，不碰外部浏览器'; return 0 }
                if ($md -eq 'see' -or $md -eq 'on') { Update-FarmFile @{ watchAdopt = 'see' }; W-Ok '收纳模式=see：非白名单的外部浏览器纳管（看得见、不杀）'; return 0 }
                if ($md -eq 'strong') {
                    Update-FarmFile @{ watchAdopt = 'strong' }
                    W-Ok '收纳模式=strong：非白名单的外部浏览器出现就强收编转正（kill 自起 → 池子 profile 同端口重起）'
                    W-Warn 'strong 适合 Agent 专机；本机若有其它工具的长驻浏览器（带调试端口），先 farm whitelist 加白，否则会被收编（要重登）'
                    return 0
                }
                $curAd = Get-FarmWatchAdopt
                $curTxt = $(if ($curAd -eq 'strong') { 'strong（非白名单一律强收编转正）' } elseif ($curAd -eq 'off') { 'off（只回收不收纳）' } else { 'see（纳管：看得见、不杀）' })
                W-Info ('当前收纳模式：' + $curTxt + '。改：farm watch adopt see|strong|off')
                return 0
            }
            return (Farm-Watch $name)
        }
        'adopt' { return (Farm-Adopt $name $url) }
        'openapp' {
            if (-not $name) { W-Bad '用法：farm openapp <入口名>'; return 4 }
            $r = Open-WebApp $name
            if (-not $r.ok) { W-Bad $r.error; return 2 }
            W-Ok ('已打开：' + $name + ' → 端口 ' + $r.port + ($(if ($r.started) { '（实例是刚起的）' } else { '' })))
            return 0
        }
        'goto' {
            $r = Farm-Goto $name $url
            if (-not $r.ok) { W-Bad $r.error; return 2 }
            W-Ok ($name + ' → ' + $url)
            return 0
        }
        'status' {
            $r = @(Get-FarmRows) | Where-Object { $_.名称 -eq $name }
            if (-not $r) { W-Bad ('没有登记：' + $name); return 4 }
            $r | Format-List | Out-String -Width 200 | Write-Host
            return 0
        }
        'limits' {
            $lim = Get-FarmLimits
            if ($name -and [int]$name -gt 0) { $lim.maxInstances = [int]$name }
            Save-FarmLimits $lim.maxInstances
            W-Ok ('上限 ' + $lim.maxInstances + ' 个实例')
            return 0
        }
        'whitelist' {
            # 白名单：这些端口的浏览器不收纳、不收编（自己日常用的调试浏览器放这里）
            if ($name -eq 'reset') {
                Update-FarmFile @{ excludePorts = @(9222, 9223) }
                W-Ok '白名单已重置为默认：9222、9223'
                return 0
            }
            if ($name -and $name -match '^[\d,]+$') {
                $ports = @($name -split ',' | Where-Object { $_ } | ForEach-Object { [int]$_ })
                Update-FarmFile @{ excludePorts = $ports }
                W-Ok ('白名单已保存：' + ($ports -join '、') + '（这些端口不收纳不收编，正在跑的守护 3 秒内自动认）')
                return 0
            }
            $cur = @(Get-FarmExcludePorts)
            W-Title ('收纳白名单（' + $cur.Count + ' 个端口，命中即跳过）')
            if ($cur.Count -eq 0) { W-Info '（空——所有带调试端口的浏览器都会被纳管）' }
            else { foreach ($p in $cur) { W-Info ('端口 ' + $p) } }
            W-Info '改：farm whitelist 9333,9444    重置：farm whitelist reset'
            return 0
        }
        'recycle' {
            # 空闲回收配置 / 手动扫一轮
            $cfg = Get-FarmRecycleConfig
            if ($name -eq 'sweep') {
                $null = Invoke-FarmRecycleSweep $false
                return 0
            }
            if ($name -eq 'off') {
                Set-FarmRecycleConfig 0 0
                W-Ok '空闲回收已关（实例和标签页都不再自动关）'
                return 0
            }
            if ($name -and $name -match '^\d+$') {
                $inst = [int]$name
                $tab = $cfg.tabIdleMin
                if ($url -and $url -match '^\d+$') { $tab = [int]$url }
                Set-FarmRecycleConfig $inst $tab
                W-Ok ('回收参数已保存：实例空闲 ' + $inst + ' 分钟关、标签页空闲 ' + $tab + ' 分钟关（0=这层关掉）')
                return 0
            }
            W-Title '空闲回收'
            W-Info ('实例空闲 ' + $cfg.idleMin + ' 分钟关进程（profile 和登录态保留）' + $(if ($cfg.idleMin -eq 0) { '【已关】' } else { '' }))
            W-Info ('标签页空闲 ' + $cfg.tabIdleMin + ' 分钟关（保底留 1 页）' + $(if ($cfg.tabIdleMin -eq 0) { '【已关】' } else { '' }))
            W-Info '保底：有客户端连接（任务正在驱动）的不动；没时间戳可判的不动'
            W-Info '改：farm recycle 30 15    关：farm recycle off    立即扫一轮：farm recycle sweep'
            return 0
        }
        default { W-Bad ('farm 不认识这个动作：' + $act + '（可用 list/open/close/show/hide/goto/tabs/tabnew/tabclose/status/forget/scan/adopt/port/watch/whitelist/recycle/limits/alert/park/task）'); return 1 }
    }
}

function Show-Help {
    Write-Host ''
    Write-Host 'BrowserPool 浏览器池· Agent 的唯一浏览器入口' -ForegroundColor Cyan
    Write-Host '  全部网页任务在这里起浏览器：一任务一端口一 profile；强制收纳外部浏览器；空闲自动回收。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '用法：powershell -File browser-pool.ps1 <命令> [参数]'
    Write-Host ''
    Write-Host '  panel [-Port 9410] [-Bg]    起网页控制台（-Bg 后台跑）'
    Write-Host '  stop                        停后台面板'
    Write-Host ''
    Write-Host '  farm list                   列全部实例（端口 / 页数 / 内存 / 状态）'
    Write-Host '  farm open <名字> [网址]      起实例；已经在跑就直接用（默认无头）'
    Write-Host '  farm close <名字>            关实例（profile 和登录态保留）'
    Write-Host '  farm show <名字>             挪到前台（要扫码时用；无头切有头，标签页会还原）'
    Write-Host '  farm hide <名字>             收回无头后台（标签页会还原）'
    Write-Host '  farm tabs <名字>             列这个实例的标签页'
    Write-Host '  farm tabnew <名字> <网址>    同实例新开标签页（不重登）'
    Write-Host '  farm tabclose <名字> <序号|all>  关标签页'
    Write-Host '  farm apps                   后台入口清单 + 打开状态'
    Write-Host '  farm openapp <后台名>        打开后台入口（实例没起会自动起）'
    Write-Host '  farm park <名字>             有头窗口挪到屏幕外（不抢焦点，仍在跑）'
    Write-Host '  farm task <名字> [任务名]     开一个新任务段（之后的浏览器操作归它）'
    Write-Host '  farm alert <名字> <级别>|<消息>  写告警（info/warn/error）'
    Write-Host '  farm forget <名字>           移除登记（不删 profile 和登录态）'
    Write-Host '  farm scan                   扫本机带调试端口的浏览器'
    Write-Host '  farm adopt <端口> [名字]     收编：关掉外部实例，用池子 profile 重起（需重登一次）'
    Write-Host '  farm port <名字>             查实例端口（派生规则：同名跨机器同端口，9360-9399 段）'
    Write-Host '  farm limits [上限]           改实例数上限'
    Write-Host ''
    Write-Host '收纳与回收（池子版核心）：' -ForegroundColor Yellow
    Write-Host '  farm watch on/off             收纳守护总开关（默认开：任何 farm 命令自动拉起守护）'
    Write-Host '  farm watch adopt see|strong|off  收纳模式：纳管不杀(see,默认)/非白名单一律强收编转正(strong)/不收纳(off)'
    Write-Host '  farm whitelist [端口,...]     白名单：这些端口不收纳不收编；reset 回默认 9222,9223'
    Write-Host '  farm recycle [实例分] [tab分]  空闲回收参数（默认 30/15；off 关掉；sweep 立即扫一轮）'
    Write-Host ''
    Write-Host '运行日志面板：面板默认自动挑一个空闲端口（-Port 可指定），有任务用浏览器时自动调起' -ForegroundColor DarkGray
    Write-Host ('数据目录：' + $Script:HomeDir) -ForegroundColor DarkGray
    Write-Host ''
}


# ---------- 主入口 ----------
# 位置参数归一化：& 调用时 9555,9666 会绑成数组（-File 调用是字符串），统一摊平成 "9555,9666"
function Convert-ArgToText($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [System.Array]) { return (@($v) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join ',' }
    return ([string]$v)
}
$Arg1 = Convert-ArgToText $Arg1
$Arg2 = Convert-ArgToText $Arg2
$Arg3 = Convert-ArgToText $Arg3
$code = 0
try {
    switch ($Cmd.ToLower()) {
        'help' { Show-Help }
        '' { Show-Help }
        'panel' {
            $panelPort = if ($Port -gt 0) { $Port } else { $Script:PanelPort }
            if ($Bg) { $code = Start-PanelBackground $panelPort }
            else { $code = Start-Panel $panelPort }
        }
        'stop' { $code = Stop-Panel }
        'farm' { $code = Invoke-Farm $Arg1 $Arg2 $Arg3 }
        default {
            W-Bad ('不认识的命令：' + $Cmd)
            Show-Help
            $code = 1
        }
    }
}
catch {
    W-Bad ('出错：' + $_.Exception.Message)
    W-Info $_.ScriptStackTrace
    $code = 2
}
exit $code

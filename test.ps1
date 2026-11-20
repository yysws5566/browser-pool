<#
  test.ps1 — BrowserPool 浏览器池自检（离线、真跑、不碰用户真实目录）
  覆盖：命令面 / 实例池 / 端口隔离 / 标签页 / 面板接口 / 任务分段 / 告警 /
        有头无头切换保页 / 强制收纳（Ensure-Watch）/ 白名单 / 空闲回收（含「有连接不杀」反例）
  用法：powershell -NoProfile -ExecutionPolicy Bypass -File test.ps1
  全部通过 → exit 0，否则 exit 1
#>
[CmdletBinding()]
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:Df = Join-Path $Root 'browser-pool.ps1'
$Script:Pass = 0
$Script:Fail = 0
$Script:Port = 9433

function Test-Ok([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) {
        $Script:Pass++
        Write-Host ('  PASS  ' + $label) -ForegroundColor Green
    }
    else {
        $Script:Fail++
        Write-Host ('  FAIL  ' + $label + $(if ($detail) { '  <- ' + $detail } else { '' })) -ForegroundColor Red
    }
}

function Invoke-Df([string[]]$a) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:Df @a 2>&1 | Out-String
    return @{ code = $LASTEXITCODE; out = $out }
}

function Get-Http([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        return @{ ok = $true; body = $wc.DownloadString($url) }
    }
    catch { return @{ ok = $false; body = $_.Exception.Message } }
}

Write-Host ''
Write-Host 'BrowserPool 浏览器池 · 自检（浏览器池 + 收纳 + 回收）' -ForegroundColor Cyan
Write-Host ('  脚本：' + $Script:Df) -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $Script:Df)) {
    Write-Host '  FAIL  找不到 browser-pool.ps1' -ForegroundColor Red
    exit 1
}

# 隔离数据目录（用新变量名 BROWSER_POOL_HOME，与用户真实目录彻底分家）
$tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) ('browser-pool-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $tmpHome -Force | Out-Null
$env:BROWSER_POOL_HOME = $tmpHome
$env:AGENTBROWSER_HOME = $null
Write-Host ('  隔离数据目录：' + $tmpHome) -ForegroundColor DarkGray
Write-Host ''

$panelStarted = $false
try {
    # ---- T1 命令面：只剩 farm / panel / stop ----
    $rh = Invoke-Df @('help')
    Test-Ok 'T1 help 退出码 0' ($rh.code -eq 0) ('code=' + $rh.code)
    Test-Ok 'T1 help 写明定位「浏览器池」' ($rh.out -match '浏览器池') $rh.out
    Test-Ok 'T1 help 有 farm list' ($rh.out -match 'farm list')
    Test-Ok 'T1 help 不再提场景' (-not ($rh.out -match '场景')) $rh.out

    # 测试环境关掉守护的「收纳」：测试机上有真实浏览器在跑（带调试端口），纳管会污染登记表、
    # 挤占上限、并发重写 farm.json 打架。守护的回收语义照常测。
    $wao = Invoke-Df @('farm', 'watch', 'adopt', 'off')
    Test-Ok 'T1 测试环境关收纳（watchAdopt=off）' (($wao.code -eq 0) -and ($wao.out -match '收纳模式=off')) $wao.out

    $rr = Invoke-Df @('run', 'x')
    Test-Ok 'T1 老命令 run 已删除（exit 1）' ($rr.code -eq 1) ('code=' + $rr.code + ' ' + $rr.out)
    $rn = Invoke-Df @('new', 'x')
    Test-Ok 'T1 老命令 new 已删除（exit 1）' ($rn.code -eq 1) ('code=' + $rn.code)
    $rs = Invoke-Df @('schedule', 'x')
    Test-Ok 'T1 老命令 schedule（建计划任务）已删除（exit 1）' ($rs.code -eq 1) ('code=' + $rs.code)

    # ---- T2 浏览器池：开 / 列 / 状态 / 复用 / 关 ----
    $fo = Invoke-Df @('farm', 'open', 't2-farm', 'about:blank')
    Test-Ok 'T2 能按名字开一个实例' (($fo.code -eq 0) -and ($fo.out -match '端口')) $fo.out
    $fl = Invoke-Df @('farm', 'list')
    Test-Ok 'T2 list 里有这个实例' ($fl.out -match 't2-farm') $fl.out
    $fs = Invoke-Df @('farm', 'status', 't2-farm')
    Test-Ok 'T2 status 报出端口和模式' (($fs.out -match '端口') -and ($fs.out -match 'headless')) $fs.out
    $f2 = Invoke-Df @('farm', 'open', 't2-farm')
    Test-Ok 'T2 同名再开是复用不重开' ($f2.out -match '已经在跑') $f2.out
    $fg = Invoke-Df @('farm', 'close', 't2-farm')
    Test-Ok 'T2 close 能关掉实例' (($fg.code -eq 0) -and ($fg.out -match '已关')) $fg.out
    $fo2 = Invoke-Df @('farm', 'open', 't2-farm2', 'about:blank')
    $null = Invoke-Df @('farm', 'close', 't2-farm2')
    Test-Ok 'T2 关掉再开能再起（端口以输出为准）' (($fo2.code -eq 0) -and ($fo2.out -match '端口')) $fo2.out

    # ---- T2b alert 两种写法 + openapp（文档写法必须真能跑）----
    $al1 = Invoke-Df @('farm', 'alert', 't2-farm', 'warn', '登录失效需要人工扫码')
    Test-Ok 'T2b alert 三参数写法可用' (($al1.code -eq 0) -and ($al1.out -match 'warn')) $al1.out
    $al2 = Invoke-Df @('farm', 'alert', 't2-farm', 'error|接口超时')
    Test-Ok 'T2b alert 管道写法可用' (($al2.code -eq 0) -and ($al2.out -match 'error')) $al2.out
    $oa = Invoke-Df @('farm', 'openapp', '__no_such_app__')
    Test-Ok 'T2b openapp 未知入口给明确报错' (($oa.code -eq 2) -or ($oa.code -eq 4)) $oa.out

    # ---- T3 两实例互不干扰 + 标签页 ----
    $a = Invoke-Df @('farm', 'open', 't3A', 'http://127.0.0.1:1/')
    $b = Invoke-Df @('farm', 'open', 't3B', 'http://127.0.0.1:1/')
    $pa = [regex]::Match($a.out, '端口 (\d+)').Groups[1].Value
    $pb = [regex]::Match($b.out, '端口 (\d+)').Groups[1].Value
    Test-Ok 'T3 两个实例拿到不同端口' (($pa -ne '') -and ($pb -ne '') -and ($pa -ne $pb)) ('A=' + $pa + ' B=' + $pb)
    $la = Invoke-Df @('farm', 'list')
    Test-Ok 'T3 两个实例各占一行（不串）' (($la.out -match 't3A') -and ($la.out -match 't3B')) $la.out
    $dt = Invoke-Df @('farm', 'tabs', 't3A')
    Test-Ok 'T3 能列出某实例的标签页' (($dt.code -eq 0) -and ($dt.out -match '标签页')) $dt.out

    # ---- T4 同实例新开标签页（不重登、不新增实例）----
    $tn = Invoke-Df @('farm', 'tabnew', 't3A', 'http://127.0.0.1:2/')
    Test-Ok 'T4 tabnew 能在同实例开新标签页' (($tn.code -eq 0) -and ($tn.out -match '(已开|标签页)')) $tn.out
    $dt2 = Invoke-Df @('farm', 'tabs', 't3A')
    Test-Ok 'T4 开完能读到这个标签页' ($dt2.out -match '127\.0\.0\.1:2') $dt2.out
    $null = Invoke-Df @('farm', 'close', 't3A')
    $null = Invoke-Df @('farm', 'close', 't3B')

    # ---- T5 后台入口表：webapps.json → CLI 能列出来（app/端口/状态/实例/网址）----
    $appFile = Join-Path $tmpHome 'webapps.json'
    [System.IO.File]::WriteAllText($appFile, '{"apps":[{"app":"Demo App","skill":"x","instance":"没有这个实例","url":"https://example.com/"}]}', (New-Object System.Text.UTF8Encoding($false)))
    $ap = Invoke-Df @('farm', 'apps')
    Test-Ok 'T5 apps 能列后台入口表' (($ap.code -eq 0) -and ($ap.out -match 'Demo App') -and ($ap.out -match ':\d+')) $ap.out
    Test-Ok 'T5 每行带实例名与状态' (($ap.out -match '实例=') -and ($ap.out -match '(已打开|实例在跑|实例没起)')) $ap.out

    # ---- T9 告警通道：farm alert 写 logs\alerts.jsonl ----
    $al = Invoke-Df @('farm', 'alert', 't9-alert', 'warn|测试告警-告警通道')
    Test-Ok 'T9 farm alert 能写告警（exit 0）' (($al.code -eq 0) -and ($al.out -match '已记录告警')) $al.out
    $af = Join-Path $tmpHome 'logs\alerts.jsonl'
    $ac = $(if (Test-Path $af) { Get-Content $af -Raw -Encoding UTF8 } else { '' })
    Test-Ok 'T9 alerts.jsonl 落了记录且 pushed=false' (($ac -match '测试告警-告警通道') -and ($ac -match '"pushed":false')) ''
    $al2 = Invoke-Df @('farm', 'alert', 't7-tidy')
    Test-Ok 'T9 farm alert 缺消息时报错（exit 4）' ($al2.code -eq 4) $al2.out

    # ---- T10 实例级 extraArgs + 模式按 farm.json 配置（open 不传第三参数时） ----
    $fj = Join-Path $tmpHome 'farm.json'
    $j = Get-Content $fj -Raw -Encoding UTF8 | ConvertFrom-Json
    $j.instances += [pscustomobject]@{ name = 't10-args'; headless = $false; lean = $false; extraArgs = @('--window-size=1111,777') }
    ($j | ConvertTo-Json -Depth 8) | Set-Content -Path $fj -Encoding UTF8
    $null = Invoke-Df @('farm', 'open', 't10-args')
    $j2 = Get-Content $fj -Raw -Encoding UTF8 | ConvertFrom-Json
    $p10 = [int](($j2.instances | Where-Object { $_.name -eq 't10-args' } | Select-Object -First 1).port)
    $cmd10 = ''
    for ($i = 0; $i -lt 12; $i++) {
        $cmd10 = (Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -match ('remote-debugging-port=' + $p10) -and $_.CommandLine -notmatch '--type=' } | Select-Object -First 1).CommandLine
        if ($cmd10) { break }
        Start-Sleep -Milliseconds 400
    }
    Test-Ok 'T10 extraArgs 进了 Chrome 命令行' ($cmd10 -match '1111,777') ''
    Test-Ok 'T10 配置 headless:false 时 open 起有头' (($cmd10 -ne '') -and (-not ($cmd10 -match '--headless'))) ''
    $null = Invoke-Df @('farm', 'close', 't10-args')

    # ---- T8 park：有头窗口挪屏幕外 / 无头直接跳过 ----
    $null = Invoke-Df @('farm', 'open', 't8-park', 'about:blank')
    $pk = Invoke-Df @('farm', 'park', 't8-park')
    Test-Ok 'T8 无头实例 park 直接跳过（exit 0）' (($pk.code -eq 0) -and ($pk.out -match '不用 park|本来就没窗口')) $pk.out
    $pkx = Invoke-Df @('farm', 'park', 'no-such-instance')
    Test-Ok 'T8 park 不存在的实例报错（exit 4）' ($pkx.code -eq 4) ('code=' + $pkx.code + ' ' + $pkx.out)
    $null = Invoke-Df @('farm', 'close', 't8-park')

    # ---- T6 面板：起 → 首页 / api/health / api/apps / api/activity → 停 ----
    $null = Invoke-Df @('stop')
    Start-Sleep -Milliseconds 700
    $rp = Invoke-Df @('panel', '-Port', ([string]$Script:Port), '-Bg')
    Test-Ok 'T6 面板能后台起' (($rp.code -eq 0) -and ($rp.out -match '已启动|已在后台启动')) $rp.out
    $panelStarted = $true
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 400
        $h = Get-Http ('http://127.0.0.1:' + $Script:Port + '/api/health')
        if ($h.ok) { $ok = $true; break }
    }
    Test-Ok 'T6 /api/health 能通' $ok $h.body
    $idx = Get-Http ('http://127.0.0.1:' + $Script:Port + '/')
    Test-Ok 'T6 首页标题是「浏览器池」' (($idx.ok) -and ($idx.body -match '浏览器池')) $idx.body.Substring(0, [Math]::Min(120, $idx.body.Length))
    Test-Ok 'T6 首页已无场景卡片' (-not ($idx.body -match '新建场景|试跑')) ''
    $ia = Get-Http ('http://127.0.0.1:' + $Script:Port + '/api/apps')
    Test-Ok 'T6 /api/apps 返回后台入口' (($ia.ok) -and ($ia.body -match '"app":"Demo App"')) $ia.body
    $is = Get-Http ('http://127.0.0.1:' + $Script:Port + '/api/schedule')
    Test-Ok 'T6 /api/schedule 死接口已删（不该再返回 200）' (-not $is.ok) ('ok=' + $is.ok)
    $iact = Get-Http ('http://127.0.0.1:' + $Script:Port + '/api/activity?limit=5')
    Test-Ok 'T6 /api/activity 返回任务分组与实例状态' (($iact.ok) -and ($iact.body -match '"running"') -and ($iact.body -match '"tasks"')) $iact.body.Substring(0, [Math]::Min(160, $iact.body.Length))
    $iact2 = Get-Http ('http://127.0.0.1:' + $Script:Port + '/api/activity?act=drain')
    Test-Ok 'T6 /api/activity drain 能跑' (($iact2.ok) -and ($iact2.body -match 'drained')) $iact2.body
    $ir = Get-Http ('http://127.0.0.1:' + $Script:Port + '/api/old-route')
    Test-Ok 'T6 旧路由已删（404）' (-not $ir.ok) $ir.body
    $st = Invoke-Df @('stop')
    Test-Ok 'T6 stop 能停面板' ($st.code -eq 0) $st.out
    $panelStarted = $false

    # ---- T13 任务分段：farm task 开新段，日志按任务分开 ----
    $null = Invoke-Df @('farm', 'open', 't13-task', 'about:blank')
    $tk1 = Invoke-Df @('farm', 'task', 't13-task', 'T13 任务甲')
    Test-Ok 'T13 farm task 能开新任务段' (($tk1.code -eq 0) -and ($tk1.out -match '已开新任务段')) $tk1.out
    Start-Sleep -Milliseconds 800
    $tk2 = Invoke-Df @('farm', 'task', 't13-task', 'T13 任务乙')
    Test-Ok 'T13 再开一个任务段 id 不同' (($tk2.code -eq 0) -and ($tk2.out -match '任务乙')) $tk2.out
    $raw13 = ''
    try { $raw13 = [System.IO.File]::ReadAllText((Join-Path $tmpHome 'farm.json')) } catch { }
    Test-Ok 'T13 farm.json 里记了任务名' ($raw13 -match 'T13 任务乙') ('len=' + $raw13.Length)
    $null = Invoke-Df @('farm', 'close', 't13-task')

    # ---- T14 扫端口与收编防护 ----
    $sc = Invoke-Df @('farm', 'scan')
    Test-Ok 'T14 farm scan 能跑' (($sc.code -eq 0) -and ($sc.out -match '带调试端口')) $sc.out
    $a0 = Invoke-Df @('farm', 'adopt')
    Test-Ok 'T14 adopt 不带参数被拒（exit 4）' ($a0.code -eq 4) ('exit=' + $a0.code + ' ' + $a0.out)
    $a1 = Invoke-Df @('farm', 'adopt', '99999')
    Test-Ok 'T14 adopt 端口不存在被拒（exit 4）' ($a1.code -eq 4) ('exit=' + $a1.code + ' ' + $a1.out)

    # ---- T15 收纳守护：开 / 不重复起 / 关总开关 ----
    $w1 = Invoke-Df @('farm', 'watch', 'on')
    $pid1 = [regex]::Match($w1.out, 'PID (\d+)').Groups[1].Value
    Test-Ok 'T15 farm watch on 能起守护' (($w1.code -eq 0) -and ($w1.out -match '收纳守护已开') -and ($pid1 -ne '')) $w1.out
    Start-Sleep -Milliseconds 800
    $w2 = Invoke-Df @('farm', 'watch', 'on')
    $pid2 = [regex]::Match($w2.out, 'PID (\d+)').Groups[1].Value
    Test-Ok 'T15 已在跑时不重复起（PID 不变）' (($w2.code -eq 0) -and ($pid2 -eq $pid1)) ($w2.out)
    $w3 = Invoke-Df @('farm', 'watch', 'off')
    Test-Ok 'T15 farm watch off 关总开关' (($w3.code -eq 0) -and ($w3.out -match '收纳守护已关') -and ($w3.out -match 'watchEnabled')) $w3.out

    # ---- T15b 强制收纳：off 之后 farm 命令不得再拉起；on 之后自动在 ----
    # 轮询等守护退出（一轮 = 3 秒 sleep + sweep 时长，实例多时退出要 10 秒+，固定 sleep 会抖）
    $aliveAfterOff = $true
    for ($i15 = 0; $i15 -lt 10; $i15++) {
        Start-Sleep -Seconds 2
        $aliveAfterOff = $false
        try { if ($pid1 -and (Get-Process -Id ([int]$pid1) -ErrorAction Stop)) { $aliveAfterOff = $true } } catch { }
        if (-not $aliveAfterOff) { break }
    }
    Test-Ok 'T15b off 后守护进程真退了（20 秒内）' (-not $aliveAfterOff) ('pid=' + $pid1)
    $null = Invoke-Df @('farm', 'list')
    Start-Sleep -Seconds 2
    $aliveAfterList = $false
    try { if ($pid1 -and (Get-Process -Id ([int]$pid1) -ErrorAction Stop)) { $aliveAfterList = $true } } catch { }
    Test-Ok 'T15b off 后 farm list 不再拉起守护（总开关生效）' (-not $aliveAfterList) ''
    $wOn = Invoke-Df @('farm', 'watch', 'on')
    $pidOn = [regex]::Match($wOn.out, 'PID (\d+)').Groups[1].Value
    $null = Invoke-Df @('farm', 'list')   # 有总开关时这条不该再起第二个
    Start-Sleep -Milliseconds 900
    $daemonProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match ('watch.*run') -and $_.CommandLine -match [regex]::Escape($Script:Df) })
    Test-Ok 'T15b on 后守护在跑且只有一个' (($pidOn -ne '') -and ($daemonProcs.Count -eq 1)) ('procs=' + $daemonProcs.Count)

    # ---- T16 白名单：设 / 读回 / 重置 + 不被 routine 操作洗掉 ----
    $ws = Invoke-Df @('farm', 'whitelist', '9551,9552')
    $fj16 = Get-Content (Join-Path $tmpHome 'farm.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Ok 'T16 whitelist 能保存' (($ws.code -eq 0) -and (@($fj16.excludePorts) -contains 9551) -and (@($fj16.excludePorts) -contains 9552)) $ws.out
    $wv = Invoke-Df @('farm', 'whitelist')
    Test-Ok 'T16 whitelist 能查看' (($wv.code -eq 0) -and ($wv.out -match '9551') -and ($wv.out -match '9552')) $wv.out
    $wr = Invoke-Df @('farm', 'whitelist', 'reset')
    $fj16b = Get-Content (Join-Path $tmpHome 'farm.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Ok 'T16 whitelist reset 回默认' (($wr.code -eq 0) -and (@($fj16b.excludePorts) -contains 9222) -and (@($fj16b.excludePorts) -contains 9223)) $wr.out
    # 配置不被 routine 操作洗掉（底版 bug 的回归测试）
    $null = Invoke-Df @('farm', 'whitelist', '9551')
    $null = Invoke-Df @('farm', 'open', 't16-keep', 'about:blank')
    $null = Invoke-Df @('farm', 'goto', 't16-keep', 'about:blank')
    $null = Invoke-Df @('farm', 'close', 't16-keep')
    $fj16c = Get-Content (Join-Path $tmpHome 'farm.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Ok 'T16 open/goto/close 之后白名单还在（不被洗掉）' (@($fj16c.excludePorts) -contains 9551) ($fj16c | ConvertTo-Json -Compress -Depth 3)

    # ---- T17 回收参数：设 / 读回 ----
    $rc = Invoke-Df @('farm', 'recycle', '25', '12')
    Test-Ok 'T17 recycle 能设参数' (($rc.code -eq 0) -and ($rc.out -match '25')) $rc.out
    $fj17 = Get-Content (Join-Path $tmpHome 'farm.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Ok 'T17 参数落盘（idleMin/tabIdleMin）' (($fj17.idleMin -eq 25) -and ($fj17.tabIdleMin -eq 12)) ($fj17 | ConvertTo-Json -Compress -Depth 3)
    $rv = Invoke-Df @('farm', 'recycle')
    Test-Ok 'T17 recycle 能查看' (($rv.code -eq 0) -and ($rv.out -match '25')) $rv.out

    # ---- T18 空闲回收真跑一轮：连着不杀 → 断开就收 → profile 还在 ----
    $fo18 = Invoke-Df @('farm', 'open', 't18-idle', 'about:blank')
    $p18 = [int][regex]::Match($fo18.out, '端口 (\d+)').Groups[1].Value
    Test-Ok 'T18 起一个实例准备回收' (($fo18.code -eq 0) -and ($p18 -gt 0)) $fo18.out
    # 反例准备先做：占住一个到调试端口的 TCP 连接（模拟任务正在 CDP 驱动），
    # 占稳了再把 lastUsedAt 改成 5 分钟前、阈值压到 1 分钟——防守护在窗口期抢先回收
    $cli18 = New-Object System.Net.Sockets.TcpClient
    $cli18.Connect('127.0.0.1', $p18)
    Start-Sleep -Milliseconds 500
    $fj18 = Join-Path $tmpHome 'farm.json'
    $j18 = Get-Content $fj18 -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($it18 in $j18.instances) { if ($it18.name -eq 't18-idle') { $it18.lastUsedAt = (Get-Date).AddMinutes(-5).ToString('s') } }
    ($j18 | ConvertTo-Json -Depth 8) | Set-Content -Path $fj18 -Encoding UTF8
    $null = Invoke-Df @('farm', 'recycle', '1', '0')
    $sw1 = Invoke-Df @('farm', 'recycle', 'sweep')
    $live18a = $false
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $p18); $c.Close(); $live18a = $true } catch { }
    Test-Ok 'T18 有客户端连接时空闲也不杀（不误杀保底）' ($live18a) ($sw1.out)
    $cli18.Close(); $cli18.Dispose()
    Start-Sleep -Seconds 2   # 给 TCP 关闭握手留窗口，防 Established 残影误判忙碌
    # 断开后应该被收掉：手动 sweep 或守护（每 3 秒也在扫）谁先干都算——只认结果
    $sw2 = Invoke-Df @('farm', 'recycle', 'sweep')
    $deadBy = 0
    for ($i18 = 0; $i18 -lt 5; $i18++) {
        $liveX = $false
        try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $p18); $c.Close(); $liveX = $true } catch { }
        if (-not $liveX) { $deadBy = $i18; break }
        Start-Sleep -Seconds 2
    }
    Test-Ok 'T18 断开后空闲实例被回收（手动或守护，10 秒内）' ($deadBy -ge 0 -and -not $liveX) ($sw2.out)
    $prof18 = Join-Path $tmpHome ('browser\farm_t18-idle')
    Test-Ok 'T18 实例关了但 profile 还在（登录态不丢）' (Test-Path -LiteralPath $prof18) $prof18
    # 日志行在端口死之后最多几秒才落笔（Stop 的确认循环），轮询等它出现而不是读一次就判
    $wl18 = ''
    $gotLine18 = $false
    for ($i18 = 0; $i18 -lt 6; $i18++) {
        try { $wl18 = Get-Content (Join-Path $tmpHome 'logs\watch.log') -Raw -Encoding UTF8 } catch { }
        if ($wl18 -match '回收实例.*t18-idle') { $gotLine18 = $true; break }
        Start-Sleep -Seconds 2
    }
    Test-Ok 'T18 watch.log 记了回收行' $gotLine18 ($wl18)
    $null = Invoke-Df @('farm', 'recycle', '30', '15')   # 参数还原，别影响后面

    # ---- T18b tab 级回收：有连接一个不收；断开后死 tab 收到剩 1（独立审查揪出的缺口补测）----
    $fb18b = Invoke-Df @('farm', 'open', 't18b-tabs', 'http://127.0.0.1:1/')
    $p18b = [int][regex]::Match($fb18b.out, '端口 (\d+)').Groups[1].Value
    $null = Invoke-Df @('farm', 'tabnew', 't18b-tabs', 'http://127.0.0.1:2/')
    $t18b0 = Invoke-Df @('farm', 'tabs', 't18b-tabs')
    Test-Ok 'T18b 起实例带 2 个非空 tab' (($p18b -gt 0) -and (([regex]::Matches($t18b0.out, '127\.0\.0\.1:[12]/')).Count -ge 2)) $t18b0.out
    $fjb = Join-Path $tmpHome 'farm.json'
    $jb = Get-Content $fjb -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($itb in $jb.instances) { if ($itb.name -eq 't18b-tabs') { $itb.lastUsedAt = (Get-Date).AddMinutes(-5).ToString('s') } }
    ($jb | ConvertTo-Json -Depth 8) | Set-Content -Path $fjb -Encoding UTF8
    $null = Invoke-Df @('farm', 'recycle', '0', '1')   # 实例层关掉，只测 tab 层
    # 占住到调试端口的连接（任务正纯 CDP 驱动、不碰 farm 命令）→ 一个 tab 都不许收
    $clib = New-Object System.Net.Sockets.TcpClient
    $clib.Connect('127.0.0.1', $p18b)
    Start-Sleep -Milliseconds 500
    $swb1 = Invoke-Df @('farm', 'recycle', 'sweep')
    $t18b1 = Invoke-Df @('farm', 'tabs', 't18b-tabs')
    Test-Ok 'T18b 有客户端连接时 tab 一个不收' (([regex]::Matches($t18b1.out, '127\.0\.0\.1:[12]/')).Count -ge 2) ($swb1.out + ' | ' + $t18b1.out)
    $clib.Close(); $clib.Dispose()
    Start-Sleep -Seconds 3
    # 轮询等「收到剩 1」：手动 sweep 可能撞上守护的瞬态探活连接被误判忙碌，单次断言会抖
    $t18b2 = @{ out = '' }
    $tabsLeft = -1
    for ($i18b = 0; $i18b -lt 5; $i18b++) {
        $null = Invoke-Df @('farm', 'recycle', 'sweep')
        $t18b2 = Invoke-Df @('farm', 'tabs', 't18b-tabs')
        $tabsLeft = ([regex]::Matches($t18b2.out, '127\.0\.0\.1:[12]/')).Count
        if ($tabsLeft -eq 1) { break }
        Start-Sleep -Seconds 2
    }
    Test-Ok 'T18b 断开后死 tab 收到剩 1' ($tabsLeft -eq 1) $t18b2.out
    $null = Invoke-Df @('farm', 'close', 't18b-tabs')
    $null = Invoke-Df @('farm', 'recycle', '30', '15')   # 参数还原

    # ---- T19 无头→有头→无头：标签页还原 ----
    $null = Invoke-Df @('farm', 'open', 't19-vis', 'http://127.0.0.1:1/')
    $null = Invoke-Df @('farm', 'tabnew', 't19-vis', 'http://127.0.0.1:2/')
    $null = Invoke-Df @('farm', 'tabnew', 't19-vis', 'http://127.0.0.1:3/')
    $t19a = Invoke-Df @('farm', 'tabs', 't19-vis')
    Test-Ok 'T19 切换前有 3 个标签页' (([regex]::Matches($t19a.out, '127\.0\.0\.1:[123]')).Count -ge 3) $t19a.out
    $sh = Invoke-Df @('farm', 'show', 't19-vis')
    Test-Ok 'T19 show 切有头成功' (($sh.code -eq 0) -and ($sh.out -match 'headful')) $sh.out
    $t19b = Invoke-Df @('farm', 'tabs', 't19-vis')
    Test-Ok 'T19 切有头后标签页还原（3 个都在）' (([regex]::Matches($t19b.out, '127\.0\.0\.1:[123]')).Count -ge 3) $t19b.out
    $hd = Invoke-Df @('farm', 'hide', 't19-vis')
    Test-Ok 'T19 hide 收回无头成功' (($hd.code -eq 0) -and ($hd.out -match 'headless')) $hd.out
    $t19c = Invoke-Df @('farm', 'tabs', 't19-vis')
    Test-Ok 'T19 收回无头后标签页还在' (([regex]::Matches($t19c.out, '127\.0\.0\.1:[123]')).Count -ge 3) $t19c.out
    $null = Invoke-Df @('farm', 'close', 't19-vis')

    # ---- T20 外部浏览器解析（纯函数，拿假进程对象测真代码）----
    # 从真文件里按 AST 抠出函数定义文本，先定义再调用——防「测的是拷贝」假绿
    $ast20 = [System.Management.Automation.Language.Parser]::ParseFile($Script:Df, [ref]$null, [ref]$null)
    $fn20 = @($ast20.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Get-BrowsersFromProcs' }, $true))
    Test-Ok 'T20 找到 Get-BrowsersFromProcs 函数' ($fn20.Count -eq 1) ('found=' + $fn20.Count)
    if ($fn20.Count -eq 1) {
        $null = Invoke-Expression $fn20[0].Extent.Text
        $fake20 = @(
            [pscustomobject]@{ ProcessId = 101; CommandLine = 'chrome.exe --remote-debugging-port=9701 --user-data-dir="C:\tmp\a"' }
            [pscustomobject]@{ ProcessId = 102; CommandLine = 'chrome.exe --remote-debugging-port=9702' }
            [pscustomobject]@{ ProcessId = 103; CommandLine = 'chrome.exe --type=renderer --remote-debugging-port=9703' }
            [pscustomobject]@{ ProcessId = 104; CommandLine = 'chrome.exe --no-debug' }
        )
        $reg20 = @{}
        $out20 = Get-BrowsersFromProcs $fake20 $reg20 @(9701)
        Test-Ok 'T20 带端口+带 profile 的能解析' (@($out20 | Where-Object { $_.port -eq 9701 }).Count -eq 1) ''
        Test-Ok 'T20 白名单端口标 excluded' ((@($out20 | Where-Object { $_.port -eq 9701 })[0]).excluded -eq $true) ''
        Test-Ok 'T20 没带 user-data-dir 的也看得见（Agent 放宽）' (@($out20 | Where-Object { $_.port -eq 9702 -and $_.profile -eq '' }).Count -eq 1) ''
        Test-Ok 'T20 子进程（--type=）不算' (@($out20 | Where-Object { $_.port -eq 9703 }).Count -eq 0) ''
        Test-Ok 'T20 没端口的看不见' (@($out20 | Where-Object { $_.pid -eq 104 }).Count -eq 0) ''
        $reg20b = @{ 9701 = '已登记的' }
        $out20b = Get-BrowsersFromProcs $fake20 $reg20b @(9222)
        $hit20b = @($out20b | Where-Object { $_.port -eq 9701 })[0]
        Test-Ok 'T20 已登记端口标 managed 且带名字' (($hit20b.managed -eq $true) -and ($hit20b.name -eq '已登记的')) ''
    }

    # ---- T21 端口唯一映射：同名派生同端口（9360-9399 段），forget 重开不变 ----
    # 先挑一个派生值不撞已登记端口的实例名：套件前面已登记十来个实例，撞上会触发后探、断言就抖了
    $fj21 = Join-Path $tmpHome 'farm.json'
    $used21 = @()
    if (Test-Path -LiteralPath $fj21) {
        try { foreach ($u21 in @(Get-Content $fj21 -Raw -Encoding UTF8 | ConvertFrom-Json).instances) { if ($u21 -and $u21.port) { $used21 += [int]$u21.port } } } catch { }
    }
    $name21 = ''
    $der21 = 0
    foreach ($try21 in @('t21-map', 't21-mapB', 't21-mapC', 't21-mapD', 't21-mapE')) {
        $pn21 = Invoke-Df @('farm', 'port', $try21)
        $d21 = [int][regex]::Match($pn21.out, '派生端口 (\d+)').Groups[1].Value
        if (($d21 -ge 9360) -and ($d21 -le 9399) -and ($used21 -notcontains $d21)) { $name21 = $try21; $der21 = $d21; break }
    }
    Test-Ok 'T21 farm port 能查派生端口且落在 9360-9399 段' (($name21 -ne '') -and ($der21 -ge 9360)) ('name=' + $name21 + ' der=' + $der21)
    $fo21 = Invoke-Df @('farm', 'open', $name21, 'about:blank')
    $p21 = [int][regex]::Match($fo21.out, '端口 (\d+)').Groups[1].Value
    Test-Ok 'T21 open 直接拿到派生端口（同名跨机器一致）' ($p21 -eq $der21) ('open=' + $p21 + ' der=' + $der21)
    $pn22 = Invoke-Df @('farm', 'port', $name21)
    Test-Ok 'T21 登记后 farm port 报同端口（=派生值）' (([int][regex]::Match($pn22.out, '端口 (\d+)').Groups[1].Value) -eq $p21) $pn22.out
    $null = Invoke-Df @('farm', 'close', $name21)
    $null = Invoke-Df @('farm', 'forget', $name21)   # 删登记模拟重装：派生值必须不变
    $fo21b = Invoke-Df @('farm', 'open', $name21, 'about:blank')
    $p21b = [int][regex]::Match($fo21b.out, '端口 (\d+)').Groups[1].Value
    Test-Ok 'T21 forget 后重开仍是同派生端口（跨重装一致）' ($p21b -eq $der21) ('re=' + $p21b + ' der=' + $der21)
    $null = Invoke-Df @('farm', 'close', $name21)
    $null = Invoke-Df @('farm', 'forget', $name21)

    # ---- T22 收纳模式三态：set/get/落盘 + 老布尔值归一 ----
    # 先把本机当前可见的带端口浏览器全部加白再开 strong：守护在 strong 下的几秒里也不许碰真实浏览器
    $extPorts22 = @()
    try {
        $extPorts22 = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match '--remote-debugging-port=(\d+)' } |
            ForEach-Object { [int]$Matches[1] } | Sort-Object -Unique)
    } catch { }
    if ($extPorts22.Count -gt 0) { $null = Invoke-Df @('farm', 'whitelist', (($extPorts22 -join ','))) }
    $s22 = Invoke-Df @('farm', 'watch', 'adopt', 'strong')
    $fj22 = Get-Content (Join-Path $tmpHome 'farm.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Ok 'T22 strong 能设置并落盘' (($s22.code -eq 0) -and ([string]$fj22.watchAdopt -eq 'strong')) ($s22.out)
    $v22 = Invoke-Df @('farm', 'watch', 'adopt')
    Test-Ok 'T22 查询显示 strong 含说明' (($v22.out -match 'strong') -and ($v22.out -match '强收编')) $v22.out
    $null = Invoke-Df @('farm', 'watch', 'adopt', 'on')   # on=see 别名
    $fj22b = Get-Content (Join-Path $tmpHome 'farm.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Ok 'T22 on 归一为 see（别名兼容）' ([string]$fj22b.watchAdopt -eq 'see') ('val=' + $fj22b.watchAdopt)
    # 老布尔值兼容：手改回 true/false，读取层必须归一
    $fj22b.watchAdopt = $true
    ($fj22b | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $tmpHome 'farm.json') -Encoding UTF8
    $v22b = Invoke-Df @('farm', 'watch', 'adopt')
    Test-Ok 'T22 老值 true 归一为 see' ($v22b.out -match '当前收纳模式：see') $v22b.out
    $null = Invoke-Df @('farm', 'watch', 'adopt', 'off')   # 还原成测试环境的安全模式
    $fj22c = Get-Content (Join-Path $tmpHome 'farm.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Ok 'T22 off 落盘（测试环境安全态）' ([string]$fj22c.watchAdopt -eq 'off') ''

    # ---- T12 有浏览器在用时面板必须在（farm open 会确保面板存活）----
    $null = Invoke-Df @('farm', 'open', 't12-auto', 'about:blank')
    $ok12 = $false
    for ($i12 = 0; $i12 -lt 24; $i12++) {
        Start-Sleep -Milliseconds 500
        $h12 = Get-Http ('http://127.0.0.1:9410/api/health')
        if ($h12.ok) { $ok12 = $true; break }
    }
    Test-Ok 'T12 有实例在跑时面板（9410）活着' $ok12 $h12.body
    $act12 = Invoke-Df @('farm', 'close', 't12-auto')
    Test-Ok 'T12 测试实例能关掉' ($act12.code -eq 0) $act12.out
}
finally {
    # 先关收纳守护再停面板（守护持有测试目录里的文件，不关的话删目录会留尾巴）
    try { $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:Df farm watch off 2>&1 } catch { }
    # 无条件停面板：T12 是 farm open 自动调起的面板（不走 panel -Bg，panelStarted 不会置 true），
    # 条件停会把它漏成孤儿——占着 9410 带着旧代码活着，坑下一轮验证（实测踩过）
    try { $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:Df stop 2>&1 } catch { }
    Start-Sleep -Milliseconds 800
    # 兜底杀漏网 Chrome：测试中失败路径起的实例（没登记的）不会走 farm close，
    # 留下僵尸会占端口+锁 profile，下一轮测试同 profile 再起会单例转交秒退（实测 72 个僵尸）
    try {
        Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match [regex]::Escape($tmpHome)) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
    $env:BROWSER_POOL_HOME = $null
    $env:AGENTBROWSER_HOME = $null
    if (-not $Keep) {
        try { Remove-Item -LiteralPath $tmpHome -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    else { Write-Host ('  测试目录保留：' + $tmpHome) -ForegroundColor DarkGray }
}

$total = $Script:Pass + $Script:Fail
Write-Host ''
if ($Script:Fail -eq 0) {
    Write-Host ('  全部通过 ' + $Script:Pass + '/' + $total) -ForegroundColor Green
    exit 0
}
else {
    Write-Host ('  通过 ' + $Script:Pass + '/' + $total + '，失败 ' + $Script:Fail) -ForegroundColor Red
    exit 1
}

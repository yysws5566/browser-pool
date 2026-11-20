# install.ps1 —— 把「所有网页任务都走 BrowserPool 浏览器池」装进 Agent（规则铁律 + skill 双保险）
#
# 做的事（幂等，重复跑不重复写）：
#   1) 找 Agent 的常驻规则文件（SOUL.md / AGENTS.md / workspace\AGENTS.md），插一段带标记的「唯一浏览器」铁律
#   2) 复制一份细则到旁边的 rules\ 目录
#   3) 打印 skill 安装指引（把整个 browser-pool 目录拷进 Agent 的 skill 目录即完成第二保险）
#
# 找家顺序（四级兜底）：
#   -AgentHome 参数 > AGENT_HOME 环境变量 > %USERPROFILE%\.openclaw > 从包目录向上找 8 层
# 找不到不报错——工具本身可以直接用，只是没有规则约束；文案会打印出来让人手贴。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-DryRun] [-AgentHome "C:\Agent的家"]

param(
    [switch]$DryRun,
    [string]$AgentHome = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDoc = Join-Path $here 'docs\唯一浏览器规则.md'

$BEGIN = '<!-- AB-RULE-BEGIN -->'
$END = '<!-- AB-RULE-END -->'

$block = @"
$BEGIN
- **唯一浏览器**：所有网页任务起浏览器必须走 BrowserPool 浏览器池 —— ``browser-pool.ps1 farm open <实例> [网址]`` 拿端口再连 CDP。**禁止自己 Start-Process chrome/edge、禁止自建 profile 和调试端口**。登录态与启动参数只有一份；起不来 / 登录失效走 ``farm alert`` 告警。要扫码登录时 ``farm show <实例>``，登完 ``farm hide <实例>`` 收回后台。
$END
"@ -replace "`r`n", "`n"

function Write-Info([string]$m) { Write-Host ("  " + $m) -ForegroundColor DarkGray }
function Write-Ok([string]$m) { Write-Host ("  [OK] " + $m) -ForegroundColor Green }
function Write-Skip([string]$m) { Write-Host ("  [--] " + $m) -ForegroundColor Yellow }
function Write-Warn2([string]$m) { Write-Host ("  [!!] " + $m) -ForegroundColor Yellow }

# ---------- 找 Agent 的家：返回 @{ home; rule } ----------
function Find-RuleFile([string]$home2) {
    # 在一个候选根目录里找常驻规则文件：SOUL.md 最优先（OpenClaw 系），其次 AGENTS.md、workspace\AGENTS.md
    $cands = @(
        (Join-Path $home2 'SOUL.md'),
        (Join-Path $home2 'AGENTS.md'),
        (Join-Path $home2 'workspace\SOUL.md'),
        (Join-Path $home2 'workspace\AGENTS.md')
    )
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { return @{ home = $home2; rule = $c } }
    }
    return $null
}

function Find-AgentHome([string]$start) {
    # 1) 显式指定
    if ($AgentHome) {
        $r = Find-RuleFile $AgentHome
        if ($r) { return $r }
        # 指定了家但没规则文件：也认这个家，规则文件直接建在根下
        return @{ home = $AgentHome; rule = (Join-Path $AgentHome 'AGENTS.md'); create = $true }
    }
    # 2) 环境变量
    foreach ($ev in @($env:AGENT_HOME)) {
        if ($ev -and (Test-Path -LiteralPath $ev)) {
            $r = Find-RuleFile $ev
            if ($r) { return $r }
            return @{ home = $ev; rule = (Join-Path $ev 'AGENTS.md'); create = $true }
        }
    }
    # 3) OpenClaw 默认位置
    $oc = Join-Path $env:USERPROFILE '.openclaw'
    if (Test-Path -LiteralPath $oc) {
        $r = Find-RuleFile $oc
        if ($r) { return $r }
        return @{ home = $oc; rule = (Join-Path $oc 'SOUL.md'); create = $true }
    }
    # 4) 从包目录向上找 8 层（开发机布局：agent 根就在附近）
    $cur = $start
    for ($i = 0; $i -lt 8; $i++) {
        if (-not $cur) { break }
        $r = Find-RuleFile $cur
        if ($r) { return $r }
        $parent = Split-Path $cur -Parent
        if ($parent -eq $cur) { break }
        $cur = $parent
    }
    return $null
}

Write-Host ""
Write-Host 'BrowserPool 浏览器池 · 安装（唯一浏览器规则 + skill 指引）' -ForegroundColor Cyan

$found = Find-AgentHome $here
if (-not $found) {
    Write-Host ""
    Write-Warn2 '没找到 Agent 的常驻规则文件（SOUL.md / AGENTS.md），规则没装。'
    Write-Info '这不影响使用：工具本身可以直接跑（browser-pool.ps1 farm open <名字>）。'
    Write-Info '想装规则，二选一：'
    Write-Info ('  1) 指定路径重跑：install.ps1 -AgentHome "C:\你的Agent根目录"')
    Write-Info '  2) 把下面这段贴进 Agent 的常驻规则文件（SOUL.md / AGENTS.md）：'
    Write-Host ""
    Write-Host $block -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

$ruleFile = [string]$found.rule
$ruleDir = Split-Path -Parent $ruleFile
$rulesDir = Join-Path $ruleDir 'rules'
$ruleDoc = Join-Path $rulesDir '05e-unique-browser.md'

Write-Info ('Agent 根目录：' + $found.home)
Write-Info ('常驻规则文件：' + $ruleFile + $(if ($found.create) { '（文件还没有，会新建）' } else { '' }))

# ---------- 1) 铁律（幂等：标记已存在就跳过） ----------
$needRule = $true
if ((Test-Path -LiteralPath $ruleFile)) {
    $txt = [System.IO.File]::ReadAllText($ruleFile, [System.Text.Encoding]::UTF8)
    if ($txt.Contains($BEGIN)) { Write-Skip '常驻规则里已有唯一浏览器铁律，跳过'; $needRule = $false }
} else {
    $txt = ''
}
if ($needRule) {
    if ($found.create -or $txt -eq '') {
        $txt2 = $txt.TrimEnd() + "`n`n" + $block + "`n"
        $where = '文件是新建的，规则直接写入'
    }
    else {
        $anchor = '- 批量提交 / 建计划 / 发消息：先 `-DryRun`'
        if ($txt.Contains($anchor)) {
            $txt2 = $txt.Replace($anchor, $block + "`n" + $anchor)
            $where = '规则插入到「硬约束」第一条之前'
        }
        else {
            $txt2 = $txt.TrimEnd() + "`n`n" + $block + "`n"
            $where = '没找到锚点，规则追加到文件末尾'
        }
    }
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $ruleDir)) { $null = New-Item -ItemType Directory -Path $ruleDir -Force }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ruleFile, $txt2, $utf8)
    }
    Write-Ok $where
}

# ---------- 2) 细则 ----------
if (-not (Test-Path -LiteralPath $rulesDir)) { if (-not $DryRun) { $null = New-Item -ItemType Directory -Path $rulesDir -Force } }
if (Test-Path -LiteralPath $srcDoc) {
    $need = $true
    if (Test-Path -LiteralPath $ruleDoc) {
        $a = [System.IO.File]::ReadAllText($ruleDoc, [System.Text.Encoding]::UTF8)
        $b = [System.IO.File]::ReadAllText($srcDoc, [System.Text.Encoding]::UTF8)
        if ($a -eq $b) { Write-Skip 'rules\05e-unique-browser.md 已是最新，跳过'; $need = $false }
    }
    if ($need) {
        if (-not $DryRun) { Copy-Item -LiteralPath $srcDoc -Destination $ruleDoc -Force }
        Write-Ok 'rules\05e-unique-browser.md 已写入'
    }
}
else { Write-Skip '包里没有 docs\唯一浏览器规则.md，跳过细则' }

# ---------- 3) skill 安装指引（第二保险） ----------
Write-Host ''
Write-Host '第二保险（把池子装成 Agent 的 skill，让它的任务起浏览器时直接想到它）：' -ForegroundColor Yellow
Write-Info ('把整个目录拷到 Agent 的 skill 目录：' + $here)
Write-Info 'OpenClaw 系通常是 %USERPROFILE%\openclaw-skills\ 或 ~/.openclaw/skills/，拷完即生效（SKILL.md 触发词已配好）'

# ---------- 4) 自检 ----------
if (-not $DryRun -and (Test-Path -LiteralPath $ruleFile)) {
    $after = [System.IO.File]::ReadAllText($ruleFile, [System.Text.Encoding]::UTF8)
    $n = ([regex]::Matches($after, [regex]::Escape($BEGIN))).Count
    Write-Host ''
    if ($n -eq 1) { Write-Ok '自检：规则标记 1 处（无重复）' }
    else { Write-Host ('  [XX] 自检失败：规则标记 ' + $n + ' 处') -ForegroundColor Red; exit 3 }
}
Write-Host ''
Write-Ok '装好了。以后 Agent 的网页任务起浏览器都走：browser-pool.ps1 farm open <实例> [网址]'
Write-Host ''
exit 0

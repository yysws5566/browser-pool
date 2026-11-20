# BrowserPool 浏览器池 · 给 AI Agent 用的唯一浏览器入口

> One browser pool for your agent. Zero dependencies on Windows.（内核 fork 自 AgentBrowser 1.3.0）

**名称说明 / Naming notice**：本项目与 GitHub 上同名的开源键鼠共享项目 `agentbrowser/agentbrowser`（原 Synergy 分支）**没有任何关系**，也不是 2026 年出现的开源项目 agent-browser.dev 的分支或衍生，不共享代码、商标或维护者；各技能平台上以 `agentbrowser` / `agent-browser` 为名的第三方作品均非本项目。本项目（browser-pool）是一个独立实现的、用于管理本机 Chrome/Edge 实例池的工具。

一句话：Agent 的所有网页任务共用一个浏览器池——**默认无头不抢焦点、一任务一端口互不干扰、外部浏览器强制收纳、空闲自动回收**，登录态只有一份、出错能立刻知道，而且你看得见它在浏览器里每一步干了什么。

零安装：只用 Windows 自带的 PowerShell 5.1 + 本机已有的 Chrome/Edge。不需要 Node、Python、Docker、Playwright。

## 解决的痛点（池子版加的三件事）

- **浏览器多到没法工作**：每个任务一个实例一个端口一个 profile，默认无头后台跑，窗口不来抢焦点
- **Agent 自己开的浏览器收不住**：收纳守护默认强制开启——任何带调试端口的浏览器出现 3 秒内纳管进池子（不杀进程、不换 profile、登录态原样），白名单端口可跳过
- **浏览器越积越卡**：空闲实例 30 分钟、空闲标签页 15 分钟自动回收；任务正在驱动（有 CDP 连接）或近期有操作的不动，登录态永不丢

---

## 它解决什么问题

AI Agent 做网页任务，通常每个技能自己起一个浏览器、自己配一套参数、自己维护登录态。结果：

- 每个技能各扫一次码，登录态维护 N 份
- 启动参数散落各处，某天某个技能少了一个参数就静默失败
- 任务跑挂了没人知道，第二天才发现数据没出
- Agent 说"我做完了"，但你不知道它到底在页面上点了什么

AgentBrowser 把这三件事收敛到一处：**启动、登录态、告警**。再加一个面板，让你看得见过程。

## 三个能力

**1. 实例池（启动）**

按名字分配浏览器实例，每个实例独立 profile + 独立调试端口。同一实例反复调用返回同一个端口，登录态自然复用。

```powershell
browser-pool.ps1 farm open 报表后台 https://example.com/
# [OK] 报表后台 已启动，端口 9330（headless，profile ...\AgentBrowser\browser\farm_报表后台）
#   agent 调：http://127.0.0.1:9330
```

拿到端口后，Agent 用标准 CDP 连接即可（WebSocket / HTTP `/json/list`）。

**2. 登录态（一份）**

每个实例一个持久化 user-data-dir。扫码一次，之后所有任务复用。有头实例可以把窗口挪到屏幕外继续跑（`farm park`），需要人操作时再拉回前台（`farm show`）。

**3. 告警（出错立刻知道）**

业务脚本用一行 `farm alert <实例> <级别> <消息>` 写告警；配合任意定时任务扫描 `logs\alerts.jsonl` 里未推送的条目，登录失效、跑挂、超成本都能主动通知到人。

## 看得见过程：任务日志面板

`browser-pool.ps1 panel` 起一个本地面板（默认 http://127.0.0.1:9410/）。**一个任务一张卡**，卡里是这个任务在浏览器里的操作流水：复制、粘贴、选日期、输入、下拉、勾选、点按钮、页面跳转。

```
┌─ 月度取数 · 报表后台 ──────────── 进行中 ┐
│ 开始 18:30   最近 18:34   共 32 条      │
│ 18:34:12  点击   账户                   │
│ 18:34:15  选日期 2026-11-01 ~ 11-18     │
│ 18:34:20  复制   消耗 12,483.50          │
└──────────────────────── 打开浏览器 ──────┘
```

日志区固定 3 行高、超出滚动，不占版面。有浏览器活动而面板没在跑时，`farm open` 会自动把它拉起来。

任务怎么划：

```powershell
browser-pool.ps1 farm task 报表后台 "月度取数"    # 开一个新任务段
```

不调也能用：`farm open` 时该实例没有任务段、或上一段超过 30 分钟，自动开一段。

## 环境要求

- Windows 10 / 11（自带 PowerShell 5.1，不用另装）
- Chrome 或 Edge **112 或更高**（用的 `--headless=new`；版本太低会起不来，报错是"端口没响应"）
- 解压后任意目录都能跑，不需要管理员权限

## 快速开始

```powershell
# 0. 自检：先确认环境没问题（会真起一个无头 Chrome，约 1-2 分钟）
powershell -NoProfile -ExecutionPolicy Bypass -File test.ps1

# 1. 起一个实例（默认无头。要扫码/看界面就加 -Headful）
powershell -NoProfile -ExecutionPolicy Bypass -File browser-pool.ps1 farm open demo https://example.com/

# 2. 开面板看日志
powershell -NoProfile -ExecutionPolicy Bypass -File browser-pool.ps1 panel
```

**第 3 步（可选）接 Agent**：把"所有网页任务都走这个浏览器池"写进你的 Agent 常驻规则。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

它会去找 Agent 的常驻规则文件（`AGENTS.md`）：设了 `AGENT_HOME`、或用 `-AgentHome` 指定、或从包目录向上 8 层内有 `workspace\AGENTS.md` 就能找到；**找不到也不会报错**，只打印一句提示并以 0 退出——技能本身不依赖它，直接命令行用就行。规则正文见 `docs/唯一浏览器规则.md`。

### 面板底部的"网页入口"

面板底部可以登记常用后台，点一下就在对应实例里打开。做法：把 `webapps.sample.json` 复制到数据目录并改名为 `webapps.json`，按里面的注释填入口名、所属实例、网址。

数据目录默认 `%USERPROFILE%\AgentBrowser`，设了环境变量 `AGENTBROWSER_HOME` 就用那个。**直接改包目录里的 `webapps.sample.json` 不会生效**——运行时只读数据目录下的 `webapps.json`。

## 已经有浏览器在跑，怎么并进来

```
powershell -File browser-pool.ps1 farm scan             # 先看本机有哪些（只读）
powershell -File browser-pool.ps1 farm adopt 9222 我的号  # 收编：关掉它，用池子的 profile 重起
```

收编会关掉原来那个浏览器，用池子的独立 profile 重新起，所以要重登一次；之后登录态就归池子管。工具自己的浏览器（默认 9222、9223）在不动名单里，不会被收编。

## 面板什么时候自己跳出来

有头实例（人能看到浏览器）一用浏览器就会检查一次：面板窗口开着就不动它，关掉了就自动打开；纯后台的无头任务只保证面板服务在跑，不弹窗打扰。

## 让新起的浏览器自动进池子（默认已开启）

**收纳守护默认强制开启**：任何 farm 命令都会自动确保守护在跑。本机任何带调试端口的浏览器一出现，3 秒内就被纳管进池子：不杀进程、不换 profile、登录态原样保留，立刻在面板能看到、能 park 到屏幕外、能关闭。

```
browser-pool.ps1 farm watch off      # 真不想收纳了再关（关的是总开关，之后的 farm 命令不再拉起）
browser-pool.ps1 farm watch on       # 重新开
```

**收纳模式三态**（`farm watch adopt see|strong|off`）：

| 模式 | 行为 | 适合 |
|---|---|---|
| `see`（默认） | 非白名单的纳管：看得见、不杀、面板能管 | 与其它工具共用一台机器 |
| `strong` | 非白名单的出现就**强收编转正**：kill 自起 → 池子 profile **同端口**重起 → 带回首页；登一次（show→hide）登录态锁进池子 | Agent 专机 |
| `off` | 守护只回收+清理，不碰外部浏览器 | 测试/纯自用 |

自己日常用的调试浏览器不想被纳管，加白名单：

```
browser-pool.ps1 farm whitelist 9333,9444    # 这些端口跳过
browser-pool.ps1 farm whitelist reset        # 回默认 9222,9223
```

要连 profile 也归池子管（登录态集中在池子里），把端口写进强收编名单——这些端口会被整份收编：关掉原浏览器、用池子 profile 重起，需要重登一次。

```
browser-pool.ps1 farm watch 9333,9444
```

纳管进来的实例，端口不通后会自动从登记表移除。

## 空闲回收（默认已开启）

浏览器积多了机器卡，但任务跑一半被杀更糟。回收的判定与保底：

| 层 | 默认 | 判定 | 保底 |
|---|---|---|---|
| 实例 | 空闲 30 分钟关进程 | `lastUsedAt`（每次 open/goto/tabnew/task 刷新）+ 操作事件，取最近的 | 端口上有 CDP 客户端连接 = 任务在驱动，不动；profile 和登录态永远保留，`farm open` 同名即复活 |
| 标签页 | 空闲 15 分钟关 | 实例整体 15 分钟没人动（无 open/goto/task、无页面事件），且该 URL 没出现在近期操作日志里 | 保底留 1 页；about:blank / 内置页不关 |

**自动回收只管池子亲生的实例**（`farm open` 起的）。外部纳管进来的浏览器只看得见、能手动关——它不是池子起的，自动关=赌它不是别的工具的长驻任务；要纳入回收生命周期先 `farm adopt` 转正。

```
browser-pool.ps1 farm recycle            # 看当前参数
browser-pool.ps1 farm recycle 10 5       # 改成实例 10 分钟 / tab 5 分钟
browser-pool.ps1 farm recycle off        # 全关
browser-pool.ps1 farm recycle sweep      # 立即扫一轮（不等守护）
```

回收记录在 `logs\watch.log` 和面板事件里（标签「回收 / 收页」）。

## 卡住了先看这三条

起不来先看报错里的第一行，最常见就三种：

浏览器没起来，报「找不到浏览器」——本机没装 Chromium 内核浏览器，或路径变了。装一个 Chrome 或 Edge 再跑。
端口起不来 —— 那个端口被别的程序占了。不加 -Port 会自己挑空闲端口，加了就换一个。
面板打不开 —— 面板没在跑，或端口被别人占了。先 `browser-pool.ps1 stop`，再 `browser-pool.ps1 panel` 重起。

实在查不出，跑 `powershell -File test.ps1`，45 项自检会把哪一环断了直接指出来。

## 命令一览

| 命令 | 干什么 |
|---|---|
| `farm open <名字> [网址] [-Headful]` | 起或复用实例，输出 CDP 端口；`-Headful` 强制有头（要扫码时用） |
| `farm list` | 列全部实例（端口/模式/内存/标签页/空闲分钟） |
| `farm close <名字>` | 关掉实例（保留 profile 与登录态） |
| `farm show/hide/park <名字>` | 拉前台 / 隐藏 / 挪到屏幕外；show/hide 无头↔有头切换时**标签页自动还原** |
| `farm goto <名字> <网址>` | 在实例里跳转 |
| `farm tabs / tabnew / tabclose` | 标签页操作 |
| `farm task <名字> [任务名]` | 开新任务段（面板一张卡） |
| `farm alert <名字> <级别> <消息>` | 写告警（info/warn/error）；也支持 `farm alert <名字> 'warn|消息'` |
| `farm watch on/off` | 收纳守护总开关（默认开：任何 farm 命令自动拉起） |
| `farm port <名字>` | 查端口：名字派生的唯一映射（同名跨机器同端口，9360-9399 段，避开其它工具的 9330-9339） |
| `farm whitelist [端口,...]` | 白名单：这些端口不收纳不收编；`reset` 回默认 |
| `farm recycle [实例分] [tab分]` | 空闲回收参数（默认 30/15）；`off` / `sweep` |
| `farm openapp <入口名>` | 打开 `webapps.json` 里登记的入口（实例没起会自动起） |
| `farm limits [上限]` | 实例数上限 |
| `farm forget <名字>` | 从登记表删掉（不删磁盘 profile） |
| `panel [-Port N] [-Bg]` / `stop` | 起面板 / 停面板 |

完整说明见 `docs/命令手册.md`。

## 环境要求

- Windows 10 / 11
- PowerShell 5.1（系统自带）
- Chrome 或 Edge（任一本机已安装的 Chromium 内核浏览器）
- 无需管理员权限；无需联网安装任何依赖

数据目录默认 `%USERPROFILE%\BrowserPool`（与其它浏览器池工具互不干扰），可用环境变量 `BROWSER_POOL_HOME` 改到别处（旧名 `AGENTBROWSER_HOME` 仍认）。要清干净：先 `farm close` 所有实例、`farm watch off`，再删这个目录。

## 安全边界

- 只监听 `127.0.0.1`，不对外网开放
- 浏览器由使用者本机安装、以本机身份运行，权限等同使用者本人
- 面板与调试端口无认证，**同一台机器上的其他程序也能连**——多用户机器请注意
- 不提供绕过验证码、反爬、登录墙的能力，也不应被用于此类用途

详见 `docs/安全与合规.md`。

## 设计借鉴

独立实现，零第三方代码。设计上参考了这些公开项目的公开文档与思路：

| 项目 | 许可 | 借鉴的点 |
|---|---|---|
| Playwright MCP (Microsoft) | Apache-2.0 | 持久 profile、空闲回收、域名允许/阻止清单、以无障碍树而非截图喂给模型 |
| Chrome DevTools MCP | Apache-2.0 | 以真实 Chrome 作后端、console 与网络可见性 |
| browser-use | MIT | 多后端抽象（本地 CDP 与远程服务可互换） |
| Steel Browser | Apache-2.0 | 会话语义：创建 / 释放 / 并发多会话 |
| Stagehand | MIT | 观测、动作、抽取三分离；cookies 持久化后免登录 |

本软件与上述项目及其作者、公司无任何隶属或背书关系。详见 `docs/架构.md`。

## 许可与免责

- 代码：MIT（全文见 `免责声明.md` 附录；原独立 LICENSE 文件因上传平台不接收该类文件而并入声明）
- 免责：使用前请读 [`免责声明.md`](免责声明.md)——现状提供、不担保、不担责、合规使用责任在用户。

## 贡献

欢迎提 issue 与 PR。提交即表示同意以 MIT 许可分发你的贡献。

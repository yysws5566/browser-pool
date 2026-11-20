---
name: browser-pool
displayName: 浏览器池 · AI Agent 的唯一浏览器入口
description: 你的 AI Agent 一跑网页任务就满屏弹浏览器、抢焦点没法干活？装它。所有网页任务统一从一个池子起浏览器：一任务一端口一 profile 互不干扰，默认无头后台跑不抢焦点；Agent 自己乱开的浏览器 3 秒强制收纳进池子统一看管（白名单可跳过）；空闲的实例和标签页自动回收不堆积（任务在跑的绝不误杀）；登录扫码一次永久复用；指挥中心面板实时看见它在页面上每一步干了什么。Windows 零依赖（自带 PowerShell + 本机 Chrome/Edge 即可，不需要 Node/Python/Docker）。触发词：起浏览器、开浏览器、浏览器池、多实例浏览器、登录态复用、网页任务要浏览器、抓数要登录、CDP 端口、操作日志、收纳浏览器、浏览器太多、浏览器抢焦点、回收浏览器、无头浏览器。
version: 1.4.0
---

# BrowserPool 浏览器池：AI Agent 的唯一浏览器入口

定位一句话：**Agent 的所有网页任务都在这里起浏览器、开出来的也全都归这里管**——不抢焦点（默认无头）、不串任务（一任务一端口一 profile）、不堆积（空闲自动回收）、看得见（面板一任务一卡）。

零依赖：Windows 自带 PowerShell 5.1 + 本机已装 Chrome/Edge。不需要 Node / Python / Docker / Playwright。

## 四个核心行为（装完即生效，不用背命令）

1. **入口前置**：起浏览器先 `farm open <实例> [网址]` 拿端口，再连 CDP。禁止自己 `Start-Process chrome`。
2. **端口唯一映射**：实例名 ↔ 端口按 MD5 派生（9360-9399 段，避开其它工具常用的 9330-9339）——**同名跨机器同端口**，登记后终身绑定；`farm port <名字>` 随时查。撞车/被占会按序后探，以 farm open 输出为准。
3. **强制收纳**：任何 farm 命令都会自动确保收纳守护在跑；Agent 技能自己开的带调试端口的浏览器，3 秒内被纳管（不杀进程、不换 profile、登录态原样），面板立刻能看到。白名单端口跳过：`farm whitelist`。**专机可开 strong**（`farm watch adopt strong`）：非白名单的浏览器出现就强收编转正——kill 自起 → 池子 profile **同端口**重起 → 带回首页，技能侧端口无感；登一次（`farm show` 扫码 → `farm hide`）登录态永久锁进池子。
4. **空闲回收**：实例空闲 30 分钟关进程（profile 和登录态保留）、标签页空闲 15 分钟关（保底留 1 页）。有客户端连接（任务正在驱动浏览器）或近期有操作的不动——不会误杀在跑的任务。参数：`farm recycle [实例分] [tab分]`。
5. **无头为主，登录有路**：默认无头后台跑。要扫码/人工操作时 `farm show <实例>` 切有头（标签页自动还原），登完 `farm hide <实例>` 收回后台。

## 30 秒上手

```powershell
cd <本技能目录>

# 起一个实例（返回 CDP 端口，默认无头）
powershell -NoProfile -ExecutionPolicy Bypass -File browser-pool.ps1 farm open 报表后台 https://example.com/

# 在它里面开一个新任务段（面板上一张卡）
powershell -NoProfile -ExecutionPolicy Bypass -File browser-pool.ps1 farm task 报表后台 "月度取数"

# 看日志面板（farm open 也会自动确保面板在跑）
powershell -NoProfile -ExecutionPolicy Bypass -File browser-pool.ps1 panel
```

Agent 侧拿到 `http://127.0.0.1:<端口>` 后用标准 CDP 连接：`GET /json/list` 拿页面，`webSocketDebuggerUrl` 走 WebSocket。

## 接进 Agent（双保险）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -AgentHome "C:\Agent根目录"
```

- 保险一：把「唯一浏览器」铁律幂等写进 Agent 常驻规则（SOUL.md / AGENTS.md 自动识别，四级探测：参数 > 环境变量 AGENT_HOME > `~/.openclaw` > 向上找）
- 保险二：把整个本目录拷进 Agent 的 skill 目录（OpenClaw 系通常 `~/openclaw-skills/`），SKILL.md 触发词已配好

## 命令面

| 命令 | 说明 |
|---|---|
| `farm open <名字> [网址] [-Headful]` | 起/复用实例，输出端口；自动确保面板与收纳守护在跑 |
| `farm list` | 实例总表（端口/模式/内存/标签页/空闲分钟） |
| `farm close <名字>` | 关实例，保留 profile（登录态不丢） |
| `farm show / hide <名字>` | 切有头/无头，**标签页自动还原**（扫码登录用 show，登完 hide） |
| `farm park <名字>` | 有头窗口挪屏幕外（不抢焦点，进程照跑） |
| `farm goto / tabs / tabnew / tabclose` | 导航与标签页 |
| `farm task <名字> [任务名]` | 开新任务段（面板一张卡） |
| `farm alert <名字> <info\|warn\|error> <消息>` | 写告警到 `logs\alerts.jsonl` |
| `farm scan` / `farm adopt <端口> [名字]` | 扫外部浏览器 / 手动强收编（关掉重起进池子 profile，需重登） |
| `farm port <名字>` | 查实例端口（同名跨机器一致的派生映射，9360-9399 段） |
| `farm watch on / off` | 收纳守护总开关（默认开；off 后 farm 命令不再拉起） |
| `farm watch adopt see\|strong\|off` | 收纳模式：see=纳管不杀（默认）/ strong=非白名单一律强收编转正（Agent 专机用）/ off=不收纳 |
| `farm whitelist [端口,...]` | 白名单：这些端口不收纳不收编；`reset` 回默认 9222,9223 |
| `farm recycle [实例分] [tab分]` | 回收参数（默认 30/15；`off` 全关；`sweep` 立即扫一轮） |
| `farm limits [N]` / `farm forget <名字>` | 实例数上限 / 移除登记 |
| `farm openapp <入口名>` / `farm apps` | webapps.json 后台入口 |
| `panel [-Port] [-Bg]` / `stop` | 面板 / 停面板 |

## 回收怎么判定「在用」（不误杀的三道保底）

1. 调试端口上有客户端连接（CDP WebSocket 连着 = 任务正在驱动）→ 不动
2. 近期有操作事件（面板每 3 秒采集页面活动）或 `lastUsedAt` 新鲜（每次 open/goto/tabnew/task 都刷新）→ 不动
3. 没时间戳可判 → 保守不动

回收动作：关进程但**永远保留 profile 和登录态**；下次 `farm open` 同名实例直接复活。**自动回收只管池子亲生的实例**（`farm open` 起的）；外部纳管的浏览器只看得见、能手动关，要纳入回收生命周期先 `farm adopt` 转正（关掉重起进池子 profile）。

## 面板 = 指挥中心

`http://127.0.0.1:9410/`（farm open 自动调起）

- 顶部指挥条：**在跑任务数**（大数字发光）、登记实例数、收纳守护在线状态、回收参数、白名单端口数
- **运行中区**：一任务一张发光卡片——任务名、实例、端口、步数、持续时长、最近动作时间，卡内 3 行滚动操作流水，「打开浏览器」一键拉窗口
- **已结束区**：默认收起变暗，展开看每段的步数与尾部流水
- 事件标签：复制/粘贴/选日期/输入/点击/收纳/回收 等全中文

## 数据在哪

默认 `%USERPROFILE%\BrowserPool`（独立于其它浏览器池工具，互不干扰）：

```
farm.json          实例登记表 + 配置（回收参数/白名单/守护开关都在这，改坏了可整份删掉重建）
browser\farm_<名>  各实例的 user-data-dir（登录态在这）
logs\activity.jsonl  操作流水（3MB 轮转，留 2000 行）
logs\watch.log       收纳与回收的执行记录（查「为什么被关」看这里）
logs\alerts.jsonl    告警队列
```

环境变量：`BROWSER_POOL_HOME`（数据目录，旧名 `AGENTBROWSER_HOME` 仍认）、`AGENTBROWSER_PANEL_PORT`（面板端口）。

## 坑（实测踩过的）

| 现象 | 原因 / 处理 |
|---|---|
| 日志一直空 | 实例是旧代码起的没埋点（等一次 drain 自动补）；页面在 iframe 里；CDP 连不上（`farm list` 看端口） |
| headless 实例关最后一个标签页就整个退出 | Chrome 的行为；任何关页逻辑必须保底留 1 页（回收已内置） |
| 面板整页打不开、接口全超时 | 在 HttpListener 请求线程里跑了长任务；长任务必须丢独立进程 |
| `farm open` 起了无头但我想要有头（要扫码） | `farm show <名字>`：无头切有头，标签页会自动还原 |
| 自己日常用的调试浏览器被纳管了 | `farm whitelist <端口>` 加白；默认白名单 9222、9223 |
| 实例被回收了但任务还要用 | 任务侧重新 `farm open` 同名实例即复活（登录态在）；或调大 `farm recycle` 分钟数 |

## 自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test.ps1
```

会真起无头 Chrome（约 2-3 分钟），覆盖命令面、实例池、端口隔离、标签页、面板接口、任务分段、告警、有头/无头切换保页、强制收纳、白名单、空闲回收。

## 许可与免责

- MIT（全文见 `免责声明.md` 附录），fork 自 AgentBrowser 1.3.0
- **使用前必读 `免责声明.md`**：现状提供、不担保、不担责；合规使用（目标网站条款、当地法律）责任完全在用户
- 不提供绕过验证码 / 反爬 / 登录墙的能力

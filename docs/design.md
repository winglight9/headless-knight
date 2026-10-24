# 无头骑士大师 · 设计文档 v1.0

> 出门前点一下，它关掉所有阻止睡眠的东西、断开蓝牙、拔线后自动睡眠；回来后告诉你期间有没有被偷偷唤醒。

- 目标平台：macOS 13+（Apple Silicon）
- 形态：菜单栏 App（`LSUIElement`，无 Dock 图标）
- 交付物：DMG 安装包，拖入"应用程序"即完成安装
- 文档日期：2026-10-23

---

## 1. 背景

用户使用拆掉屏幕（无 A 壳）的 M1 Pro MacBook，外接显示器当服务器。三个痛点：

1. **睡不着**——系统里有多层机制在阻止睡眠，市面工具只处理其中一层。
2. **被唤醒**——蓝牙外设、网络唤醒、定时维护等反复叫醒机器，带出门时掉电。
3. **不知道有没有被唤醒**——回来后无法判断机器在包里是否被扰动过。

### 1.1 实测基线（用户机器，2026-10-23）

```
System-wide power settings:
  SleepDisabled     1        ← 全局禁用睡眠
  sleep             0        ← 空闲睡眠定时器 = 永不
  womp              1        ← 网络唤醒
  powernap          1
  tcpkeepalive      1
阻止睡眠的进程：coreaudiod / powerd / UURemote(49小时) / ChatGPT / Electron / Chrome(音频)
内核断言：MAGICWAKE (en0)
```

近两日唤醒原因分布（34 次）：

| 次数 | 原因 | 归类 |
|---|---|---|
| 20 | `NUB.SPMISw3IRQ rtc/SleepService` | 系统维护（Power Nap） |
| 8 | `smc.70070000 USB-C_plug` | 供电/扩展坞插拔 |
| 3 | `UserActivity` | 真实唤醒 |
| 2 | `Notification` | 通知唤醒 |

---

## 2. 核心模型

### 2.1 三层阻止睡眠

| 层 | 机制 | 谁能改 | 优先级 |
|---|---|---|---|
| L1 系统策略 | `disablesleep` / `sleep` / `womp` / `powernap` / `tcpkeepalive` | `pmset`（需 root） | **最高** |
| L2 进程断言 | `IOPMAssertion`（`PreventUserIdleSystemSleep` 等） | 只能终止持有者 | 中 |
| L3 内核断言 | `MAGICWAKE`（网络唤醒） | 关 womp | 低 |

**L1 优先**：`SleepDisabled=1` + `sleep 0` 开着时，杀再多进程也睡不着。这是本产品与同类工具的核心差异。

### 2.2 外出模式 = 事务

```
进入：快照(蓝牙/pmset/TM/共享/断言/日志锚点) → 应用变更 → 写状态文件
停留：什么都不做          ← 关键：不轮询、不常驻计时
退出：读状态文件 → 审计日志 → 出报告 → 恢复快照 → 通知
```

**停留阶段不做事**是核心设计：App 在系统睡眠时会被挂起，任何基于 Timer 的累加都会失真。计时用墙钟差值，唤醒统计全部来自退出时的一次性日志审计。App 中途被杀、断电，只要状态文件在，回来仍能出准确报告。

### 2.3 唤醒三级分类

| 档位 | 日志特征 | 是否告警 |
|---|---|---|
| 暗唤醒 | 行首 `DarkWake` + `DarkWake from` | 否，仅计数 |
| 通知唤醒 | `Wake ... DarkWake to FullWake ... due to Notification` 且持续 < 5s | 否，仅计数 |
| 真实唤醒 | `due to UserActivity` / HID / 全唤醒持续 ≥ 5s | **是，重点提醒** |

主界面把"暗唤醒 + 通知唤醒"合并为**后台唤醒 N 次**，详情里才区分。

---

## 3. 功能清单

### 3.1 自动执行（9 项）

| # | 动作 | 实现 | 失败处理 |
|---|---|---|---|
| 1 | 检测并关闭阻止睡眠的程序 | `IOPMCopyAssertionsByProcess` → 解析 `Created for PID` → `NSRunningApplication.terminate()` → 失败则 `.forceTerminate()` | **中断流程并提示** |
| 2 | 关闭蓝牙 | `IOBluetoothPreferenceSetControllerPowerState(0)` | 降级 daemon 执行 `defaults write` + `killall bluetoothd`；仍失败则提示 |
| 3 | 关闭网络唤醒 `womp` | `pmset -a womp 0` | 提示（可能被 MDM 锁定） |
| 4 | 关闭 Power Nap | `pmset -a powernap 0` | 提示 |
| 5 | 关闭 TCP Keepalive | `pmset -a tcpkeepalive 0` | 提示 |
| 6 | 清空定时唤醒任务 | `pmset schedule cancelall` | 提示（**只取消不恢复**） |
| 7 | 暂停 Time Machine | `tmutil disable` | 提示 |
| 8 | 关闭共享服务 | `launchctl disable system/com.apple.smbd` 等 + `bootout` | 提示 |
| 9 | 拔线后强制睡眠 | 检测显示器数 = 0 → 倒计时 → `pmset sleepnow` | 重试一次 |

**连带效果**：关闭蓝牙后，接力 Handoff、AirDrop、Apple Watch 解锁、Sidecar、通用剪贴板、连续互通相机、即时热点、蓝牙键鼠、**离线查找** 全部同时失效，无需单独处理。

### 3.2 结束时恢复

按快照逐项还原 1–8 项。逐项独立恢复，单项失败不影响其他项，失败项汇总提示。

### 3.3 不做

| 项目 | 原因 |
|---|---|
| 外接键盘按键唤醒 | 硬件级，Apple Silicon 任意键都唤醒 |
| 触控板被压 | 硬件级 |
| 电源键 / Touch ID | 硬件级 |
| HDMI-CEC | 硬件级，少见 |
| 磁吸配件靠近 | 硬件级 |
| USB / 电源插入唤醒 | 用户希望插入时能唤醒（主动行为） |
| 关闭 Find My | 用户要求保留（但关蓝牙后离线查找实际失效） |
| 实时拦截唤醒 | 技术上不可行：睡眠时进程被挂起，暗唤醒仅持续 2–27 秒 |
| 演练模式 | 用户要求取消，不额外增加复杂度 |

---

## 4. 用户流程

### 4.1 首次引导（3 步，仅一次）

| 步 | 内容 | 主按钮 |
|---|---|---|
| 1 | 介绍：出门前点一下，它会关程序、关蓝牙、记录唤醒 | 继续 |
| 2 | 授权：修改系统设置需要管理员权限，授权后不再询问 | 授权并安装 |
| 3 | 清单：出门时会做 4 件事 + 关闭程序可能丢失未保存内容 | 开始使用 |

### 4.2 出门

```
点菜单栏公文包
  → 弹窗「在家 · 系统可以正常睡眠」
  → 点「开始外出模式」
  → 检测：列出阻止睡眠的程序（N 个，动态），每个写清「挡了什么、怎么关」
  → 20 秒倒计时（可点「现在就退出」或「取消」；只挡屏幕的不动）
  → 逐个关闭，失败则中断并提示（可「仍然继续」）
  → 关闭蓝牙 / 网络唤醒 / Power Nap / TCP Keepalive / TM / 共享
  → 显示「✓ 可以拔掉显示器了」+ 已完成清单
你拔线
  → 检测显示器数 = 0
  → 5 秒倒计时（插回线可取消）
  → pmset sleepnow
你装包走人
```

**「可以拔掉显示器了」是心理交付点**：主文案是动作指令而非状态汇报，清单打勾仅作佐证。用户不需要理解任何技术细节，只需相信这个信号。

### 4.3 回来

```
插上显示器（此动作本身会唤醒机器）
  → 图标为实心「外出中」
  → 若仍在外出模式，弹一次通知「欢迎回来，别忘了结束外出模式」
点图标
  → 触发统计（1–2 秒）
  → 有真唤醒 → 图标变红 + 红色报告
  → 无真唤醒 → 图标描边 + 干净报告
点「知道了」
  → 恢复现场（蓝牙/设置/TM/共享）
  → 图标回描边
```

### 4.4 状态机

```
        ┌───────── 点「知道了」─────────┐
        ↓                               │
     [描边·在家]                         │
        │                               │
   点「开始外出模式」                      │
        ↓                               │
     [实心·外出中] ──点图标→统计──┬─ 无异常 → [描边·报告干净] ─┘
                                  └─ 有异常 → [红点·报告异常] ─┘
```

---

## 5. 界面规格

**通用规则**

1. 所有数字均为运行时变量，无硬编码（`{blockerCount}`、`{duration}`、`{batteryDelta}`、`{wakeCount}`）。
2. 主文案是**动作指令**或**结论**，不是状态罗列。
3. 技术细节默认不可见，收在「查看详情」后。
4. 单窗口：`NSPopover` 挂在 `NSStatusItem` 上，宽 300，全程不出现第二个窗口。

| # | 视图 | 关键元素 |
|---|---|---|
| 1 | 引导 1/3 | 图标 + 三条能力说明 + 继续 + 页码 |
| 2 | 引导 2/3 | 锁图标 + 授权说明 + 授权并安装 + 「为什么要这个？」 |
| 3 | 引导 3/3 | 四项清单 + 风险提示 + 开始使用 |
| 4 | 在家 | 状态 + 「开始外出模式」+ 上次结果摘要 |
| 5 | 检测倒计时 | 「检测到 N 个程序」+ 程序列表（名字 + 挡了什么 + 怎么关）+ 20 秒倒计时 + 现在就退出/取消 |
| 6 | 阻塞提示 | 「有 N 项没能完成」+ 失败项 + 已完成项 + 我处理好了/仍然继续 |
| 7 | 可以拔线 | 大绿勾 + 「可以拔掉显示器了」+ 拔线后 5 秒睡眠 + 四项清单 + 取消 |
| 8 | 外出中 | 状态 + 时长 + 电量下降 + 「结束外出模式」 |
| 9 | 报告·干净 | 「这次很干净」+ 时长 + 电量 |
| 10 | 报告·异常 | 「被唤醒 N 次」+ 时间 + 时长 + 电量 + 建议 |
| 11 | 设置 | 开机自启 / 拔线后等待 / 后台服务状态 / 重新查看引导 |
| 12 | 菜单栏 | 描边（在家）/ 实心（外出中）/ 红点（有异常） |

### 5.1 报告建议的生成规则

**只给软件还能控制的事提建议，人类和硬件的事只陈述事实。**

| 唤醒原因 | 文案 |
|---|---|
| 键盘/触控板 | 只陈述「14:32 键盘被按下」，不给建议 |
| 扩展坞供电波动 | 「扩展坞供电波动唤醒了机器，走之前拔掉坞」 |
| 系统维护唤醒 | 「系统维护唤醒，可在设置里彻底关闭」 |
| 局域网设备 | 「已关闭网络唤醒，仍被局域网设备叫醒」 |
| 完全没睡 | 「这次没睡成，有程序一直在阻止睡眠」← 最高优先级 |

---

## 6. 技术架构

### 6.1 模块

```
HeadlessKnightMaster/
├── App/                 菜单栏、popover 宿主、通知
├── Views/               12 个视图
├── Core/
│   ├── AssertionScanner 断言枚举 + 代理关系解析 + 分类
│   ├── ProcessKiller    terminate → forceTerminate
│   ├── PowerSettings    pmset 读写 + 快照
│   ├── BluetoothControl 私有 API + 降级
│   ├── WakeAuditor      日志解析 + 分类 + 排除规则
│   ├── DisplayWatcher   显示器数量变化回调
│   ├── BatteryReader    IOPS 读电量
│   ├── SharingControl   共享服务开关
│   ├── TimeMachineControl
│   └── SessionStore     状态文件 / 快照 / 历史报告
└── Helper/              root daemon
```

### 6.2 关键 API

| 用途 | API |
|---|---|
| 读断言 | `IOPMCopyAssertionsByProcess()` |
| 枚举/退出应用 | `NSRunningApplication.runningApplications` / `.terminate()` / `.forceTerminate()` |
| 读电源设置 | `pmset -g custom` |
| 写电源设置 | `pmset -a <key> <value>`（root） |
| 睡眠日志 | `pmset -g log` |
| 定时任务 | `pmset -g sched` / `pmset schedule cancelall` |
| 立即睡眠 | `pmset sleepnow` |
| 电量 | `IOPSGetPowerSourceDescription()` |
| 显示器变化 | `CGDisplayRegisterReconfigurationCallback()` / `CGGetActiveDisplayList()` |
| 蓝牙开关 | `dlopen` + `dlsym("IOBluetoothPreferenceSetControllerPowerState")` |
| Time Machine | `tmutil disable` / `enable` |
| 共享服务 | `launchctl disable system/<label>` + `bootout` |
| 开机时间 | `sysctl kern.boottime` |
| 通知 | `UNUserNotificationCenter` |
| 自启动 | `~/Library/LaunchAgents/*.plist` + `launchctl bootstrap` |

### 6.3 权限（只有两项）

| 权限 | 何时 | 可拒绝？ |
|---|---|---|
| 管理员密码 | 首次安装 daemon | 否（否则无法改系统设置） |
| 通知 | 首次发通知 | 是（拒绝则无提醒，功能正常） |

**不需要**：辅助功能、自动化、完全磁盘访问、蓝牙权限。

> 关键取舍：用 `NSRunningApplication.terminate()` 而非 AppleScript，省掉"为每个 App 单独授权自动化"的灾难。代价是无法只让 Chrome 停音频而保留浏览器，只能整个关闭。

### 6.4 daemon 通信

- 二进制：`/Library/PrivilegedHelperTools/com.headlessknight.helper`
- 启动项：`/Library/LaunchDaemons/com.headlessknight.helper.plist`
- socket：`/var/run/com.headlessknight.sock`
- 协议：newline-delimited JSON
- 鉴权：`getpeereid()` 取对端 uid，与安装时记录的 uid 比对
- 签名：ad-hoc（`codesign -s -`）

> 不用 XPC：XPC 客户端校验依赖签名中的 team identifier，ad-hoc 签名没有 team id，校验会失败。Unix socket + uid 校验不依赖签名。

### 6.5 构建与打包

```bash
swift build -c release
# 组装 .app（Info.plist: LSUIElement=true, bundle id, 版本）
# 生成图标 icns
codesign -s - --deep HeadlessKnightMaster.app
# DMG 暂存：app + Applications 软链接
hdiutil create -srcfolder staging -format UDZO -volname "无头骑士大师" HeadlessKnightMaster.dmg
```

**Gatekeeper**：未公证的 app 首次打开会被拦，需右键 → 打开。DMG 内附说明图。

---

## 7. 数据结构

### 7.1 状态文件

`~/Library/Application Support/HeadlessKnightMaster/state.json`

```json
{
  "phase": "away",
  "startedAt": "2026-10-23T21:00:00+08:00",
  "timeZoneOffsetMinutes": 480,
  "logAnchor": "2026-10-23 21:00:00 +0800",
  "batteryStart": 78,
  "bootTimeAtStart": 1234567.0,
  "displayDetachedAt": "2026-10-23T21:02:11+08:00",
  "snapshot": {},
  "lastReport": {}
}
```

### 7.2 快照

```json
{
  "bluetoothPower": 1,
  "pmset": { "disablesleep": 1, "sleep": 0, "womp": 1, "powernap": 1, "tcpkeepalive": 1, "standby": 1 },
  "timeMachineEnabled": true,
  "sharing": ["com.apple.smbd", "com.apple.screensharing"],
  "terminatedApps": ["com.uu.remote", "com.google.Chrome"],
  "scheduledWake": ["repeat wakeorpoweron MTWRF 09:00:00"],
  "failedItems": []
}
```

### 7.3 报告

```json
{
  "startedAt": "...", "endedAt": "...",
  "durationSeconds": 19320,
  "batteryStart": 78, "batteryEnd": 74,
  "sleptAtAll": true,
  "darkWakeCount": 6, "notificationWakeCount": 2, "realWakeCount": 1,
  "realWakes": [{ "at": "2026-10-23T14:32:00+08:00", "reason": "UserActivity", "durationSeconds": 138 }],
  "rebooted": false,
  "failedItems": []
}
```

### 7.4 日志解析规则（基于真实样本）

```
行首 DarkWake + "DarkWake from"            → 暗唤醒
行首 Wake    + "DarkWake to FullWake"      → 全唤醒
行首 Wake    + "Wake from Normal Sleep"    → 全唤醒
行首 Sleep   + "Entering Sleep"            → 进入睡眠
行首 Sleep   + "Entering DarkWake state"   → 暗唤醒结束回睡
```

- reason：`due to (.+?) Using`
- 时长：行尾 `(\d+) secs`
- 区间起点：`startedAt` 后第一条 `Entering Sleep`（若不存在 → `sleptAtAll = false`）
- 区间终点：最后一条唤醒事件

### 7.5 排除规则（防误报，0 误报是底线）

排除同时满足以下条件的唤醒事件：

1. 是区间内**最后一条**唤醒，且其后没有 `Entering Sleep`，**且**距点击结束 < 120 秒；**或**
2. 发生在 `displayDetachedAt`（显示器接入时间戳）± 60 秒内。

---

## 8. 异常处理矩阵

| 场景 | 处理 |
|---|---|
| 程序关不掉 | 中断 + 提示 + 「仍然继续」（报告标注可能没睡成） |
| 蓝牙关不掉 | 降级 daemon；仍失败则提示 |
| 某项 pmset 改不了 | 记录到 `failedItems`，继续，结束时报出 |
| 完全没有 `Entering Sleep` | 报告首行改为「这次没睡成」 |
| 两个外接屏 | 必须全部拔掉（数量 = 0）才算拔完 |
| 倒计时期间插回线 | 取消睡眠，回到「可以拔线了」 |
| 外出中 App 被杀 | 状态文件在磁盘，重启后读取 |
| 外出期间系统重启 | 读 `kern.boottime` 对比，报告标注「期间重启过」，不自动重设 |
| 电量耗尽关机 | 无法取结束电量，报告显示「外出期间电量耗尽」 |
| 快照恢复单项失败 | 逐项独立恢复，失败项汇总提示 |
| 快照丢失/损坏 | 用安全默认值恢复（蓝牙开、共享开、TM 开），提示用户 |
| 忘记结束外出模式 | 插显示器时弹一次通知 |
| 日志滚动 | 用 `logAnchor` 定位，从锚点往后读 |
| 跨时区 | 记录 `timeZoneOffsetMinutes`，时间差按 UTC 计算 |
| 蓝牙耳机正在用 | 开始前提示「关闭蓝牙会断开耳机」 |

---

## 9. 已知限制（必须在详情页说明）

1. 硬件按键唤醒无法阻止（键盘任意键、触控板、电源键）。
2. 关蓝牙后「离线查找」失效，机器丢失且对方不开机则无法定位。
3. 关闭共享服务后局域网无法访问。
4. 定时唤醒任务只取消不恢复，需用户自行重设。
5. 未公证，首次打开需右键 → 打开。
6. 移动 App 位置会导致自启动失效，需重新勾选。

---

## 10. 交付物

| 交付物 | 说明 |
|---|---|
| `HeadlessKnightMaster.dmg` | 拖入「应用程序」安装 |
| 源码 | SPM 工程 + 构建脚本 |
| 本设计文档 | 实现依据 |
| 界面预览 | `preview/ui.html` |

---

## 11. 实机修正记录（2026-10-24）

第一版在真机上「一次都没成功」，用户拔了显示器、拔了电源，等半天键盘灯还亮着。
复盘出五个问题，全部是**软件说了假话**。这一节是设计文档的正式修订，实现以本节为准。

### 11.1 蓝牙：偏好文件那条路在 macOS 15 上已经死了

实测（macOS 15.8.1，Apple Silicon）：

```
$ defaults read /Library/Preferences/com.apple.Bluetooth ControllerPowerState
0
$ system_profiler SPBluetoothDataType | grep State:
          State: On
```

后台服务把 `ControllerPowerState` 写成 0、再 `killall bluetoothd`，这个老办法在
macOS 15 上**完全不生效**：控制器还是开着的。而旧代码的校验偏偏读的就是这个偏好
文件——写完立刻读回自己写的值，永远「成功」。于是界面写着「✓ 关闭了蓝牙」，
实际上蓝牙鼠标还连着，随时能把机器叫醒。

**修订：**

| 项 | 旧 | 新 |
|---|---|---|
| 真实状态来源 | 偏好文件（自己写的） | `system_profiler SPBluetoothDataType` |
| 私有 API | 默认关闭 | 拿到蓝牙权限后启用 |
| 无权限时 | 静默「成功」 | 报关键失败，阻断流程 |
| 失败后 | 无出口 | 阻塞页给「打开蓝牙权限设置」+ 提示去控制中心手动关 |

关键约束：**没有蓝牙权限就调 `IOBluetoothPreferenceSetControllerPowerState`，
进程会被 TCC 直接 abort**（`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`，不是返回
错误，是进程消失）。所以调用前必须先查 `CBCentralManager.authorization`，只有
`.allowedAlways` 才走那条路。权限在首次启动时通过 `CBCentralManager` 初始化
弹一次窗拿到；命令行路径（`--diagnose` / `--simulate-away`）没有 LaunchServices
上下文，弹不出窗会 abort，必须跳过。

### 11.2 睡眠：请求发出去不等于睡了

`pmset sleepnow` 在没有权限、或者被 `PreventSystemSleep` 断言挡住时**不会报错**，
它只是什么都不做。旧代码只要没抛异常就直接切到「外出中」，界面再硬编码一句
「系统已进入睡眠」。

2026-10-24 08:56:03 的现场：拔掉显示器的那一刻，WindowServer 抓了一个
`PreventSystemSleep`（`com.apple.WindowServer.PUIDS`），把 `sleepnow` 挡在外面。

**修订：**

1. 请求睡眠后等 4 秒，读 `pmset -g log` 确认有没有 `Entering Sleep`。
   真睡了的话这 4 秒是在挂起状态下过去的，检查发生在唤醒之后，日志里必然有。
2. 没睡成就重试，最多 3 次；每次重试前重新扫描并清掉新的断言持有者。
3. 3 次都失败 → **停在「可以拔掉显示器了」页**，写明是谁占着系统睡眠
   （`pmset -g assertions` 里的 `PreventSystemSleep` 持有者），并启动后台重试
   （每 15 秒一次，最多 6 次，**只在显示器仍然没插回来时**才重试）。
4. 只有验证通过才切到「外出中」。

### 11.3 拔线检测：认 ID，不认数量

`CGDisplayRegisterReconfigurationCallback` 会漏，所以「可以拔线了」这一页同时跑
一个 1 秒的轮询对账。

**第一版对账用错了判据。** 它数 `CGGetActiveDisplayList` 的个数，为 0 才算拔掉。
2026-10-24 09:41:08 的现场把这条路堵死了：

```
09:41:08  显示器变化 → active 1 个        ← 显示器已经物理拔掉
          coreaudiod 的显示断言同一秒全部释放   ← 系统自己也认为屏没了
```

也就是说**拔线之后 `active` 仍然返回 1**：一块残影屏（phantom）占着位置。数量
永远等不到 0，倒计时永远不启动，`pmset sleepnow` 一次都没被调用——键盘灯当然
不灭。这是「为什么不灭灯」的真正原因，跟睡眠、断言、蓝牙都无关。

**修订：按显示器 ID 判断，不按数量。**

进入拔线页时记下基线 `baselineDisplayIDs = CGGetOnlineDisplayList()`。之后只要
满足任一条就算拔掉：

1. `CGGetOnlineDisplayList()` 为空；或
2. 基线里的**任何一个 ID 不在**当前 online 集合里（子集判断）。

这么写是因为「数量」这件事在不同机器上含义不同，而「我插着的那块屏还在不在」
是同一个问题：

| 机器 | 拔掉外接屏后 | 数量判据 | ID 判据 |
|---|---|---|---|
| Mac mini / Studio（单屏） | 集合为空 | 0 → 成立 | 空集 → 成立 |
| MacBook + 外接屏 | 只剩内置屏 | 1 → **不成立** | 外接 ID 消失 → 成立 |
| 无头 MacBook（本机） | 内置被拔，残影屏顶上来 | 1 → **不成立** | 基线 ID 消失 → 成立 |

反过来，DPMS 关屏时显示器仍然 **online**（只是不在 active 列表里），所以用
online 集合判断不会把「屏幕睡了」误判成「线被拔了」。

**再加一道：认 EDID。** 影子屏还有更阴的一种可能——它沿用原来那块屏的 ID。
那样 ID 子集判断也过不了。所以进页面时同时记下每块屏的 `vendor/model`，之后
只要某块基线屏的厂商/型号对不上（影子屏通常报 0），就算拔线。真屏的 EDID 是
刻在硬件里的，显示器休眠、改分辨率、镜像都不会让它变。

残影屏也有它的用处：`isDisplayDetached()` 为真时，晚到的「欢迎回来」通知不会
再发出去——那时候屏幕其实不在，用户看不到。

另外在拔线页保留了一个「现在就让电脑睡眠」的按钮：万一哪台机器的显示栈比上面
三种更古怪，用户也不会被卡在那一页出不了门。

### 11.4 恢复失败不许吃掉快照

旧代码恢复失败照样 `clearState()`。下一次外出再拍快照，拍到的就是**已经被改过
的值**，从此永远恢复不回来——一个会自我固化的错误。

**修订：** 恢复失败时保留 `state.json`，`phase` 置为新增的 `needsRestore`；
首页显示「上次没能恢复原设置」+「重试恢复」；在这个状态下点「开始外出模式」
会先补恢复再开始新的一趟。

### 11.5 崩溃与可诊断性

| 崩溃 | 原因 | 修法 |
|---|---|---|
| `_dispatch_assert_queue_fail` (SIGTRAP) | `Notifier` 把 `@MainActor` 闭包交给 `UNUserNotificationCenter` 的后台回调 | 改用 async API，闭包根本不存在 |
| `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__` | 无权限调用 IOBluetooth 私有 API | 先查 `CBCentralManager.authorization` |

`HKMLog` 以前只写 stderr，从 Finder 启动后什么都不留。现在同时写
`~/Library/Logs/HeadlessKnightMaster/app.log`（2MB 滚动），外出流程每一步都打点。

### 11.6 权限清单（修订）

| 权限 | 何时要 | 不给会怎样 |
|---|---|---|
| 管理员密码 | 装后台服务 | 改不了 pmset，阻塞 |
| 通知 | 首次启动 | 只是收不到提醒 |
| **蓝牙** | 首次启动 | **自动关蓝牙做不到**，会在阻塞页请你手动关 |

### 11.7 回归测试

`Tests/HeadlessKnightMasterTests/HonestyTests.swift` 专门守这一节：
恢复失败不吃快照、蓝牙手动关掉后能放行、睡眠没睡成不许假装出门、
`PreventSystemSleep` 解析、引导走完不崩、退出前先恢复。

`DisplayDetachTests` 守拔线判断：影子屏换 ID、影子屏沿用同一个 ID 只把 EDID 变 0、
MacBook 拔外接屏、Mac mini 拔唯一屏、DPMS 关屏不算拔线、插回来要取消倒计时。
全量 168 条。

`--simulate-away <场景名>` 可以脱离真机把 12 条路径跑一遍，其中 `no-sleep`
用来确认「叫它睡但没睡成」时不会假装出门。

---

## 12. 强力模式（2026-10-24 追加）

### 12.1 它要解决的问题

外出模式已经把 `pmset sleep` 设成 **1 分钟**，所以机器只要安静下来一分钟就会
自己睡回去。问题在于「安静不下来」：包里的鼠标/触控板持续抖动会不断重置空闲
计时器；某个程序抓着 `PreventUserIdleSystemSleep`（Electron 类应用、Handoff、
`powerd` 的「屏幕亮着就别睡」）也会让计时器永远不走。这些情况下机器会一直醒
到电池耗尽，而用户毫不知情。

强力模式就是给这种情况兜底：**只要还处在「外出中」且机器连续醒着满 10 分钟，
就提醒一次并强制它睡回去。**

### 12.2 为什么是 10 分钟，不是 1 分钟

- 空闲睡眠计时器已经是 1 分钟。还能醒着 10 分钟，说明有东西在**持续**按住它，
  不是「刚醒还没来得及睡」。
- M1 Pro 空转 2~3 W，10 分钟约 0.25% 电量，成本可以忽略；真正贵的是醒一整个下午。
- 间隔压到 1~2 分钟没有收益（按住它的东西不会自己松手），却把「误判就打断用户」
  的概率放大好几倍。

### 12.3 计时用「累计醒着」，不是「距上次唤醒」

第一版想法是「每次唤醒重新计 10 分钟」。这是错的：包里抖动可能每几分钟唤醒
一次，每次唤醒都把计时清零，计时器永远走不到 10 分钟——**恰好是最需要它的场景
失效**。

现在记的是**连续醒着的累计时长**：

- 每 5 秒一拍，醒着就把这一拍的间隔累加进去；
- 两拍之间隔了超过 60 秒 ⇒ 进程被挂起过 ⇒ 机器真的睡了一觉 ⇒ 累计时长清零；
- 累计满 10 分钟 ⇒ 提醒 + 倒计时 + 强制睡 ⇒ 清零，下一个 10 分钟再来。

顺带把「压根没睡成」也覆盖了：睡眠失败的后台重试只跑 6 次 × 15 秒就放弃，
之后由强力模式每 10 分钟继续尝试。

### 12.4 三道护栏

强制睡眠会打断工作，所以动手前必须确认「真的没人在用」：

1. **显示器插着就不动手。** 插着显示器 = 人就在电脑前。这一条比什么都重要。
2. **有远程登录就不动手。** 只看 `who` 里**带来源地址**的会话（SSH 会话行尾有
   `(10.0.0.5)`）。不能用「有没有 ttys」判断——本机 Terminal 也是 ttys，会把
   用户自己的终端误当成远程登录，导致强力模式永远不触发。这种情况只提醒一次，
   不反复刷。
3. **倒计时 30 秒，且可以取消。** 10 秒太短：通知横幅可能根本没被看到，人在
   电脑前时也来不及反应。30 秒只多花 20 秒电量，却能让人伸手点「这次不睡」。
   点过之后累计时长归零，重新计 10 分钟，不会立刻又来。

### 12.5 通知：为什么以前「一次也没看到过」

用户的原话是「之前的策划里就有弹窗的，一次也没看到过」。查日志：

```
09:40:41  通知授权：已允许
（没有任何一条「已发送通知」）
```

不是通知坏了，是 `post()` 在真机上**从来没被调用过**——它只在「显示器插回来时
发欢迎回来」和「睡眠失败时发通知」两个地方触发，而那天 09:41 那次连睡眠请求
都没发出（影子屏 bug），显示器也没插回来过。

修法：

- 设置页把**真实的通知状态**摆出来（`已允许 · 横幅` / `被拒绝（去系统设置里打开）`
  / `横幅已关闭`），不再只说「已授权」；
- 加一个「试一下 ›」按钮，以及 `--notify-test` 命令行入口，当场验证横幅能不能弹；
- 强力模式的提醒就是这个通道，所以它必须先被证明是通的。

### 12.6 老设置文件不能因为新增字段被弄丢

`AppSettings` 加了 `strongMode`。合成的 `Codable` 解码遇到缺字段会直接抛错，
上层 `try?` 一吞，**整份设置**（开机自启、拔线等待）都会退回默认值。所以改成
逐字段 `decodeIfPresent`：新增字段永远读成默认值，旧设置原样保留。

### 12.7 回归测试

`Tests/HeadlessKnightMasterTests/StrongModeTests.swift` 守 10 条：累计满阈值才动手、
重复唤醒不许清零、真睡过去要清零、显示器插着不动手、有远程登录不动手、
「这次不睡」要重新计时、开关关着什么都不做、结束外出立刻收手、
`who` 解析只认带来源地址的会话、老设置文件能解码。全量 178 条。

---

## 13. 第一次实机成功之后的六条修改（2026-10-24 追加）

真机第一次完整跑通（拔线 → 睡 → 醒来结束 → 报告）之后用户提的六条。

### 13.1 恢复时把没开的共享服务打开了（真 bug）

旧代码判断「共享服务开着没有」用的是 `launchctl print-disabled system`：那里
**没有记录**被当成「开着」。于是三个 label 永远都算开着，出门时统统
`disable + bootout`，回来时统统 `enable + bootstrap`。

`bootstrap` 不只是「允许它启动」，而是**当场把它加载起来**。用户本来没开文件
共享，出趟门回来 445 端口就开始监听了。这是实打实的功能被偷偷打开。

**修订：** 判据换成「端口在不在监听」（`netstat -an -p tcp` 里的 `LISTEN`）：

| label | 端口 |
|---|---|
| `com.apple.smbd` | 445 |
| `com.apple.screensharing` | 5900 |
| `com.apple.AppleFileServer` | 548 |

在监听 = 外面能连进来 = 该关；没监听就一个字节都不碰，恢复时也不会去
`bootstrap` 它。快照里记的也换成「当时在监听的」，恢复只恢复这些。

### 13.2 结束外出要等一秒转圈圈

`pmset -g log` 要读将近一秒（几十万行），而这只在「结束外出」时用得到——用户
就盯着转圈圈。

**修订：** 机器一醒（`NSWorkspace.didWakeNotification`）和「重启后接着外出」时
就在后台预读一遍，缓存 30 分钟。点「结束外出」时直接用缓存，日志里会写
「用预读的唤醒日志，省掉这次等待」。缓存过期或没有缓存就老老实实再读一遍。

为什么不在点击时才预读：点击就是结束本身，来不及。

### 13.3 名字太长

`HeadlessKnightMaster` 在 Finder、活动监视器、崩溃报告里都是它，没人念得出来。

**修订：** 产品名（可执行文件 + `.app` + DMG）改成 `Knight`。Swift 模块名和
target 名保持 `HeadlessKnightMaster`（改名会牵动所有 `@testable import`），
bundle id 也保持 `com.headlessknight.master`——它决定通知授权和 TCC 记录。

**代价：** 自启动项里存的是绝对路径，改名后会失效。`bootstrap` 时如果发现
plist 里的路径和当前可执行文件不一致，就把路径改对；这里**绝不能**调
`enable()`，它会先 `bootout` 再 `bootstrap`，而 bootout 会把正在运行的自己杀掉。

### 13.4 强力模式的说明写错了

原文写「每 10 分钟强制它睡一次」，听起来像定时闹钟。实际规则是：**只要还没
结束外出、机器又连续醒着满 10 分钟，就强制它再睡一次**；真睡过去就清零，醒来
重新计。改成这句话。

### 13.5 设置入口点不进去

齿轮图标是 14×14 的按钮，可点区域就是 14×14，鼠标偏一点就点空。

**修订：** 图标还是 14pt，但按钮撑到 28×28 并加 `contentShape(Rectangle())`，
看起来没变大，点起来宽松一倍。关闭按钮同理。

### 13.6 「取消」不叫「取消」

「可以拔掉显示器了」那一页的按钮原来写「取消」。可它会把已经改掉的设置全部
恢复原样——不是关掉一个弹窗。改叫「结束外出模式」。

### 13.7 回归测试

共享服务三条改成用 `netstat` 输出驱动（只动在监听的、关不掉按优化项处理），
新增「预读的日志不会读第二遍」。全量 181 条。

## 14. 点「开机自启」，菜单栏出现两个图标

`LaunchAtLogin.enable()` 写完 plist 之后还调了一次 `launchctl bootstrap`。plist 里
`RunAtLoad = true`，而 `bootstrap` 不只是「登记」，它**当场把这个 agent 加载并运行**
——第二个实例立刻起来，菜单栏多一个图标。

`disable()` 里的 `bootout` 是同一类错的另一半：它会把正在运行的自己杀掉。用户点一下
开关，App 直接消失。

**修订：** 开关只做两件事——写 plist / 删 plist。`~/Library/LaunchAgents` 是登录时
launchd 自己会扫的目录，「写进去」本身就是「下次登录自启」，不需要任何 launchctl
命令，也不需要「立即生效」——用户点这个开关的当下，App 本来就在跑。

**保险：** `applicationDidFinishLaunching` 里先查同 bundle id 的实例，pid 小的留着，
后来的自己退出。两个实例会同时改 `state.json` 和 pmset，比多一个图标严重得多。

## 15. 关软件之前，得看得懂它在挡什么

原流程：扫到断言 → 10 秒倒计时 → 全部退出。用户只看到「UURemote 49 小时」
「Chrome 正在放音频」，既不知道它们挡的是睡眠还是屏幕，也不知道该去哪儿关；
10 秒连读完三个名字都紧张。

### 15.1 倒计时 10 秒 → 20 秒

够读完两三行理由，又不至于让人对着一个不动的界面等。`Timing.detectCountdownSeconds`
是唯一来源，测试里仍然是 1 秒。

### 15.2 每个程序写清「挡了什么、怎么关」

新增 `BlockerExplainer`（纯函数，无 I/O），把断言名翻成人话：

| 断言名 / 类型 | 理由 | 建议 |
|---|---|---|
| 含 `audio` / `playback` / `playing` | 正在放音频 | 关掉在放声音的那个标签页就好 |
| `PreventUserIdleSystemSleep` | 不许电脑空闲睡眠 | UU：在 UU 里关掉「防休眠」，就不用退出它 |
| `PreventSystemSleep` | 不许电脑睡眠 | 退出它，或者在它的设置里关掉保活 |
| `Powerd - Prevent sleep while display is on` | 屏幕亮着就不许睡 | — |
| 含 `headless` | 它也在做无头模式 | 它和你在做同一件事，退出它 |
| 含 `backup` / `time machine` | 正在备份 | — |
| `PreventUserIdleDisplaySleep` | 只让屏幕不灭 | 不影响睡眠，可以不管它 |

断言名是各个程序自己起的，没有标准（Chrome 叫 `AudioPlayback`，powerd 叫
`Prevent sleep while display is on`，MacHead 叫 `MacHead: Headless mode active`），
所以只能按关键词猜；猜不出来就退回断言类型，**绝不编一个具体理由**——用户会照着
这句话去关东西。

建议按 bundle id 的**小写子串**分派（写死完整 id 太脆：正式版 / Beta / 企业版都不
一样）：UU → 会议软件（提醒「现在退出等于挂断」）→ 浏览器 → 播放器 → 保活工具 →
Docker → 自己人 → Electron → 兜底「退出它，或者在它的设置里关掉保活」。

### 15.3 只退该退的

只挡屏幕的断言（`PreventUserIdleDisplaySleep` / `NoDisplaySleepAssertion`）和「电脑
能不能睡」无关；显示器都拔了的机器更没有屏幕可挡。以前它们也在 `blockers` 里，
20 秒后会被一起退掉——为一个不影响睡眠的理由杀掉正在放视频的播放器，是白丢用户
的进度。这和「恢复时把没开的共享服务打开」是同一类错。

**修订：** `AppState.blockers` 只放 `kind == .blocking` 的（`actionableBlockers`），
扫描结果本身不变，页面另起一行写「另有 N 个只让屏幕不灭，不会退出」。只剩屏幕断言
时连检测页都不弹，直接进「可以拔掉显示器了」。

### 15.4 回归测试

全量 198 条。新增 13 条：10 条理由文案（Chrome 音频 / UU / 只挡屏幕 / powerd /
caffeinate / 同类程序 / 备份 / 会议 / 认不出来 / PreventSystemSleep）、1 条「默认
20 秒」、2 条「只挡屏幕的不退出、也不弹检测页」。

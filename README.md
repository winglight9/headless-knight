# 无头骑士大师 · Knight

给「拆掉屏幕当服务器用」的 MacBook 一个出门按钮。

拆了屏（无 A 壳）的 MacBook 挂在角落里当服务器，有三件事一直别扭：拔掉显示器它不睡、睡着了被网络唤醒吵醒、回来还得手动把一堆设置改回去。这个菜单栏小工具把这三件事做成一个按钮：出门前点一下，回来点一下，中间不用管。

```
点菜单栏公文包
  → 「在家 · 系统可以正常睡眠」
  → 点「开始外出模式」
  → 列出挡睡眠的程序，每个写清挡了什么、怎么关；自己关也行，点「一键全部关闭」也行
  → 锁定 pmset、关共享服务、关蓝牙、暂停 Time Machine、关网络唤醒
  → 「可以拔掉显示器了」
你拔线
  → 确认真拔了才睡（插回来立刻取消）
你回来插线
  → 点一下结束外出：所有设置恢复原样，出一份报告
```

## 它到底做了什么

**出门前**

| 步骤 | 做法 | 为什么 |
|---|---|---|
| 锁定睡眠 | `disablesleep=0` `sleep=1` `womp=0` `powernap=0` `tcpkeepalive=0` | 让机器自己安静下来就睡，别等它「有空」 |
| 关闭共享服务 | 只关**正在监听**的 SMB / 屏幕共享 / AFP | 端口没在听就一个字节都不碰 |
| 关闭蓝牙 | 关掉蓝牙电源 | 蓝牙设备能把机器叫醒 |
| 暂停 Time Machine | `tmutil disable` | 备份一起来就是几十分钟不睡 |
| 退出挡睡眠的程序 | 逐个 `terminate` → `forceTerminate` | 会先告诉你每个程序挡的是睡眠还是屏幕 |

**拔线之后**：只有「我让你拔的那块屏真的不在了」才睡。判断依据是显示器 ID 基线子集 + EDID，不是「显示器数量为 0」——拔线后系统常常留一个幽灵屏，数量一直是 1。

**回来之后**：照着出门前拍的快照恢复，然后从 `pmset -g log` 里读出这一趟的真相：真睡了多久、被什么唤醒、电池掉了多少。

**强力模式**（可选）：没结束外出、机器又连续醒着满 10 分钟，就发通知、倒计时 30 秒、强制它再睡一次。给「不小心开着外出模式就合盖走了」留一条后路。

## 安装

从 [Releases](../../releases) 下载 `Knight.dmg`，把 `Knight.app` 拖进「应用程序」。

首次启动要做三件事：允许通知、允许蓝牙（要关蓝牙就得有权限）、装一个 root 后台服务（写 pmset 需要）。

应用是 ad-hoc 签名的，没有苹果公证，第一次打开请**右键 →「打开」**，之后就不会再拦。

## 从源码构建

需要 macOS 13+ 和 Swift 6 工具链（Xcode 15 命令行工具即可）。

```bash
./scripts/swift.sh build     # 编译
./scripts/swift.sh test      # 跑测试（201 条）
./scripts/build-app.sh       # 组装 build/Knight.app
./scripts/make-dmg.sh        # 打成 build/Knight.dmg
```

## 几个不显然的实现细节

这些都是踩过之后才写对的，注释里留了原因：

- **`pmset sleepnow` 不报错也可能没睡**。它被 `PreventSystemSleep` 断言挡住时只是什么都不做。所以请求完必须回读 `pmset -g log` 里的 `Entering Sleep`，确认了才敢说「已进入睡眠」。
- **幽灵显示器**。拔线后 `CGGetActiveDisplayList` 仍可能返回 1，用「数量 == 0」判断会永远等不到。改成记下拔线前的显示器 ID 集合与 EDID，任一消失才算拔掉。
- **自启动只写 plist，绝不 `launchctl bootstrap`**。plist 里 `RunAtLoad` 为真，`bootstrap` 会**当场**把 agent 加载运行，于是出现两个菜单栏图标；`bootout` 更糟，会把正在运行的自己杀掉。`~/Library/LaunchAgents` 每次登录都会被 launchd 扫，写进去就够了。
- **共享服务开没开，看端口**。`launchctl print-disabled` 里「没出现」不等于「开着」，拿它当判据会在恢复时把用户本来没开的服务 `bootstrap` 起来——445 端口突然开始监听。
- **只挡屏幕的断言不该被退出**。`PreventUserIdleDisplaySleep` 和「电脑能不能睡」无关，显示器都拔了更没有屏幕可挡，为一个不影响睡眠的理由杀掉正在放视频的播放器只是白丢进度。

## 目录

```
Sources/HKMKit/                不依赖 UI 的核心：pmset、断言扫描、显示器、唤醒日志、蓝牙、共享服务
Sources/HeadlessKnightMaster/  菜单栏 App（SwiftUI + AppKit）
Sources/hkm-helper/            root 提权小工具，只做 pmset 那几件事
Tests/                         201 条测试，含假时钟与假系统
docs/design.md                 设计文档：为什么这么设计、踩过哪些坑
preview/ui.html                界面设计稿（浏览器打开）
```

## 已知限制

- 只支持 macOS 13 及以上；界面只有中文。
- ad-hoc 签名、未公证。**改名或移动 `.app` 之后，蓝牙权限要重新授权**——TCC 是按路径记的。
- 自动退出挡睡眠的程序可能丢掉未保存的内容，所以不点按钮就不动手，旁边还有「取消，先不出门」。
- 检测页只显示前 4 个挡睡眠的程序，多出来的会一起关掉；清单每 1.5 秒刷新一次，你手动关掉某个程序，它就从清单上消失，全关干净了自动往下走。

## License

MIT，见 [LICENSE](LICENSE)。

# 无头骑士大师 · Knight

给「拆掉屏幕当服务器用」的 MacBook 一个出门按钮。

拆了屏的 MacBook 挂在角落当服务器，一直有三件麻烦事：拔掉显示器它不睡、睡着被网络唤醒吵醒、回来还得把一堆设置手动改回去。这个菜单栏工具把它们并成一个按钮——出门点一下，回来点一下。

## 用法

```
点菜单栏 →「开始外出模式」→ 它自己收拾，中途让你确认一次要不要关掉挡睡眠的程序
  →「可以拔掉显示器了」→ 你拔线，确认那块屏真的不在了才睡（插回来立刻取消）
你回来插线 → 点结束 → 设置还原，出一份报告
```

## 它做了什么

| 动作 | 手段 |
|---|---|
| 锁定睡眠 | `disablesleep=0` `sleep=1` `womp=0` `powernap=0` `tcpkeepalive=0` |
| 关闭共享服务 | 只关正在监听的 SMB / 屏幕共享 / AFP，端口没在听就不碰 |
| 关闭蓝牙 | 蓝牙断电，不然外设能把机器叫醒 |
| 暂停 Time Machine | `tmutil disable`，备份一起来就是几十分钟不睡 |
| 退出挡睡眠的程序 | `terminate` → `forceTerminate`，只退真的挡睡眠的 |

**拔线之后**：看「拔线前记下的那块屏」还在不在，不看显示器数量——拔线后系统常留一个幽灵屏，数量一直是 1。

**回来之后**：按出门前的快照还原，再从 `pmset -g log` 读出这一趟真睡了多久、被什么唤醒、掉了多少电。

**增强模式**（默认开）：没结束外出、机器又连续醒着满 5 分钟，就发通知、倒计时 30 秒、再让它睡一次。只在外接屏已拔掉时生效。

## 安装

从 [Releases](../../releases) 下载 `Knight.dmg`，`Knight.app` 拖进「应用程序」。

首次启动要授权三样：通知、蓝牙、一个 root 后台服务（写 pmset 用）。ad-hoc 签名、没有公证，第一次打开请右键 →「打开」，之后不再拦。

## 从源码构建

macOS 13+，Xcode 15 命令行工具即可。

```bash
./scripts/swift.sh build     # 编译
./scripts/swift.sh test      # 259 条测试
./scripts/build-app.sh       # build/Knight.app
./scripts/make-dmg.sh        # build/Knight.dmg
```

## 几个坑

- **`pmset sleepnow` 不报错也可能没睡**。被断言挡住时它什么都不做，所以请求完要回读 `Entering Sleep` 才算数。
- **自启动只写 plist，不 `launchctl bootstrap`**。`RunAtLoad` 会当场再起一个菜单栏图标；`bootout` 更糟，会把正在运行的自己杀掉。
- **共享服务开没开看端口**。`launchctl print-disabled` 里「没出现」不等于「开着」，拿它当判据会在恢复时凭空拉起 445。
- **只挡屏幕的断言不碰**。屏都拔了没有屏可挡，为一个不影响睡眠的理由杀掉正在放视频的播放器，只是白丢进度。

## 目录

```
Sources/HKMKit/                核心逻辑：pmset、断言、显示器、唤醒日志、蓝牙、共享服务，不依赖 UI
Sources/HeadlessKnightMaster/  菜单栏 App（SwiftUI + AppKit）
Sources/hkm-helper/            root 提权小工具，只做 pmset 那几件事
Tests/                         259 条测试，含假时钟与假系统
docs/design.md                 设计文档：为什么这么设计、踩过哪些坑
preview/ui.html                界面设计稿
```

## 已知限制

- macOS 13+，界面只有中文。
- ad-hoc 签名、未公证。**改名或移动 `.app` 后蓝牙权限要重新授权**——TCC 按路径记。
- 自动退程序会丢未保存的内容，所以不点按钮不动手，旁边有「取消，先不出门」。
- 检测页只列前 4 个挡睡眠的程序，多的会一起关；清单每 1.5 秒刷新，你手动关掉哪个它就从清单消失。

## License

MIT，见 [LICENSE](LICENSE)。

# 无头骑士大师 · Knight

无头 MacBook 的日常开关。

拆掉屏幕、或者合盖接着外接屏当工作机用的 MacBook，日常就两个状态：**一直醒着干活**，
和**出门时真的睡着**。这个菜单栏工具把这两件事各做成一个开关，顺手把「它到底睡没睡」
变成一份能看的报告。

不是服务器工具。它管的就是这台没屏幕的笔记本本身。

## 在家：让它醒着，但不亮着一块用不上的屏

- **内建屏摘掉。** 勾一下，内建屏从显示拓扑里断开，取消勾选接回；唤醒、插拔之后系统把
  屏装回来，它 0.3 秒后再摘一次。省电，也不再有一个假的「内屏在线」信号干扰判断。
  顺带解决一件很烦的事：内屏在线时 macOS 会把外接屏的旋转打回 0°，你的屏就横了。
- **不让它自己睡。** 一条电源断言，只挡「没人动就睡」，不挡你手动让它睡。本地跑模型、
  等一个长任务、连着远程，机器就一直醒着。
- **合盖、没屏，照常跑。** 上面两件事都不依赖那块不存在的屏幕。
- **⌘H** 随时接回 / 断开内建屏。

## 出门：点一下，回来有报告

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
| 断开内建屏 | SkyLight `CGSConfigureDisplayEnabled`，勾上就摘掉，唤醒后维持 |
| 防止空闲睡眠 | `PreventUserIdleSystemSleep` 断言，出门自动放开、回来接上 |

**拔线之后**：看「拔线前记下的那块屏」还在不在，不看显示器数量——拔线后系统常留一个幽灵屏，数量一直是 1。

**回来之后**：按出门前的快照还原，再从 `pmset -g log` 读出这一趟真睡了多久、被什么唤醒、掉了多少电。

**增强模式**（默认开）：没结束外出、机器又连续醒着满 5 分钟，就发通知、倒计时 30 秒、再让它睡一次。只在外接屏已拔掉时生效。

接不回内建屏的时候（App 崩了、设置丢了），命令行还有一条路：

```bash
/Applications/Knight.app/Contents/MacOS/Knight --restore-builtin
```

## 装之前该知道的

- **第一次打开要右键 →「打开」。** 没做公证，系统会拦一次，之后不再拦。
- **改名或移动 `.app` 之后，蓝牙要重新授权。** 权限是按路径记的。
- **它不会自己退程序。** 自动退会丢未保存的内容，所以必须你点一下，旁边还有「取消，先不出门」。
- **检测页只列前 4 个挡睡眠的程序**，多的会一起关。清单每 1.5 秒刷新，你手动关掉哪个，它就从清单上消失。
- **界面有中文和英文两套**，跟着系统语言走。

## 安装

从 [Releases](../../releases) 下载 `Knight.dmg`，`Knight.app` 拖进「应用程序」。

首次启动要授权三样：通知、蓝牙、一个 root 后台服务（写 pmset 用）。

## 给改代码的人

<details>
<summary>目录、构建、测试</summary>

```
Sources/HKMKit/                核心逻辑：pmset、断言、显示器、唤醒日志、蓝牙、共享服务，不依赖 UI
Sources/HeadlessKnightMaster/  菜单栏 App（SwiftUI + AppKit）
Sources/hkm-helper/            root 提权小工具，只做 pmset 那几件事
Tests/                         294 条测试，含假时钟与假系统
docs/design.md                 设计文档：为什么这么设计、踩过哪些坑
preview/ui.html                界面设计稿
```

macOS 13+，Xcode 15 命令行工具即可。

```bash
./scripts/swift.sh build     # 编译
./scripts/swift.sh test      # 294 条测试
./scripts/build-app.sh       # build/Knight.app
./scripts/make-dmg.sh        # build/Knight.dmg
```

实现上的坑（`pmset sleepnow` 的假成功、自启动不能 bootstrap、共享服务看端口、
只挡屏幕的断言不碰、helper 版本用握手判断）都记在 `docs/design.md` 最后一节。

</details>

## License

MIT，见 [LICENSE](LICENSE)。

# 无头骑士大师 / Knight

[English](README.en.md) · [官网](https://hkm.886366.xyz/) · [下载](https://hkm.886366.xyz/download/) · [常见问题](https://hkm.886366.xyz/faq/)

**在家保持运行，出门准备休眠。**

无头骑士大师是一款 macOS 菜单栏工具，适合拆除内建屏幕，或合盖连接外接显示器的 MacBook。在家时，它可以防止系统因空闲而睡眠；出门前，它帮助检查睡眠障碍，回来后提供唤醒和电量报告。

<img src="https://hkm.886366.xyz/assets/shots/home.png" width="320" alt="无头骑士大师主界面">

## 功能

- **在家工作：**按需防止系统空闲睡眠，显示器仍可按系统设置关闭。也可以断开不再使用的内建屏幕；按 `⌘H` 切换连接状态。
- **出门准备：**从菜单栏开始外出模式，检查阻止睡眠的程序。关闭程序前会征求确认；请先保存工作。
- **途中保护：**拔掉外接显示器后，应用会尝试让 MacBook 睡眠。增强模式开启时，如果机器意外唤醒并持续无人操作，会尝试让它重新睡眠。
- **回来查看：**结束外出模式后，查看睡眠、唤醒和电量变化报告，并尝试恢复此前的设置。

## 下载与安装

需要 **macOS 13 或更高版本、Apple Silicon**。应用免费、开源，界面支持中文和英文。

1. 从[下载页面](https://hkm.886366.xyz/download/)或 [GitHub Releases](https://github.com/winglight9/headless-knight/releases/latest) 下载 DMG。
2. 打开 DMG，将 `Knight.app` 拖入「应用程序」。
3. 首次启动时，按照系统提示允许打开。应用没有 Apple 开发者签名或公证；如遇阻拦，请参阅[首次打开说明](https://hkm.886366.xyz/download/)。
4. 根据提示完成设置。修改系统电源设置需要管理员授权；通知权限可以拒绝。

## 使用前须知

- 外出模式会调整睡眠、蓝牙和部分共享服务等设置，结束时会尝试恢复。**取消的定时唤醒需要手动重新设置。**
- 关闭蓝牙期间，「查找」的离线定位可能不可用；关闭共享服务期间，局域网设备可能无法连接本机。
- 键盘或触控板受到挤压可能唤醒 MacBook；软件无法阻止硬件误触。携带时建议使用物理遮挡。
- 退出程序可能导致未保存的内容丢失，请在确认关闭前保存。
- 移动应用后，开机自启可能需要重新启用；蓝牙权限也可能需要重新授权。

完整说明与故障排查见[常见问题](https://hkm.886366.xyz/faq/)；设计和实现细节见[设计文档](docs/design.md)。

## 从源码构建

需要 macOS 13 或更高版本及 Xcode 15 命令行工具。

```bash
./scripts/swift.sh build
./scripts/swift.sh test
./scripts/build-app.sh
./scripts/make-dmg.sh
```

核心逻辑位于 `Sources/HKMKit`，菜单栏界面位于 `Sources/HeadlessKnightMaster`，电源设置辅助工具位于 `Sources/hkm-helper`。

如果应用无法重新连接内建显示屏，可以在终端运行：

```bash
/Applications/Knight.app/Contents/MacOS/Knight --restore-builtin
```

## 许可证

[MIT](LICENSE)

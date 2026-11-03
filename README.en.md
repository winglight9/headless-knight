# Knight

[中文](README.md) · [Website](https://hkm.886366.xyz/en/) · [Download](https://hkm.886366.xyz/en/download/) · [FAQ](https://hkm.886366.xyz/en/faq/)

**Keep working at home. Prepare for sleep when you leave.**

Knight is a macOS menu bar utility for MacBooks with a removed built-in display or used with the lid closed and an external display. Keep your Mac awake for work, check for obstacles to sleep before leaving, and review wake activity and battery change when you return.

<img src="https://hkm.886366.xyz/assets/shots/en/home.png" width="320" alt="Knight home screen">

## Features

- **At home:** Prevent idle system sleep when needed while allowing the display to turn off according to macOS settings. Disconnect an unused built-in display and use `⌘H` to toggle it.
- **Before leaving:** Start Away Mode from the menu bar and review apps preventing sleep. Knight asks before closing apps; save your work first.
- **On the go:** After you disconnect the external display, Knight attempts to put the MacBook to sleep. With Enhanced Mode enabled, it can try again if the Mac wakes and remains unattended.
- **On return:** End Away Mode to review sleep, wake events, and battery change. Knight also attempts to restore the previous settings.

## Download and install

Requires **macOS 13 or later and Apple silicon**. Knight is free and open source, with Chinese and English interfaces.

1. Download the DMG from the [download page](https://hkm.886366.xyz/en/download/) or [GitHub Releases](https://github.com/winglight9/headless-knight/releases/latest).
2. Open the DMG and drag `Knight.app` into Applications.
3. Follow the macOS prompts to open the app. Knight is not signed or notarized by Apple; if macOS blocks it, see the [first-launch instructions](https://hkm.886366.xyz/en/download/).
4. Complete setup as prompted. Administrator authorization is required to change system power settings; notifications are optional.

## Before you use it

- Away Mode adjusts sleep, Bluetooth, and some sharing settings, and attempts to restore them when it ends. **Canceled scheduled wakes must be set up again manually.**
- While Bluetooth is off, Find My offline location may be unavailable. Disabling sharing services can prevent other devices on the local network from connecting.
- Pressure on the keyboard or trackpad can wake a MacBook. Software cannot prevent physical input; consider a protective cover when carrying it.
- Closing apps can result in lost unsaved work. Save before confirming.
- After moving the app, you may need to re-enable launch at login and grant Bluetooth permission again.

See the [FAQ](https://hkm.886366.xyz/en/faq/) for help and [design notes](docs/design.md) for implementation details.

## Build from source

Requires macOS 13 or later and Xcode 15 command line tools.

```bash
./scripts/swift.sh build
./scripts/swift.sh test
./scripts/build-app.sh
./scripts/make-dmg.sh
```

Core logic lives in `Sources/HKMKit`, the menu bar app in `Sources/HeadlessKnightMaster`, and the power settings helper in `Sources/hkm-helper`.

If the app cannot reconnect the built-in display, run:

```bash
/Applications/Knight.app/Contents/MacOS/Knight --restore-builtin
```

## License

[MIT](LICENSE)

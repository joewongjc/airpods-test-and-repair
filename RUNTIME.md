[中文](#中文说明) | [English](#english-notes)

# English Notes

## End-User Path

The intended distribution model is:

1. Download the packaged `.dmg` from GitHub Releases
2. Open the disk image
3. Drag `AirPods Fix.app` into `Applications`
4. Open the app normally

For packaged releases, end users do **not** need:

- Xcode
- Xcode Command Line Tools
- a local Swift toolchain

## Runtime Expectations

- macOS 13 or later
- AirPods or AirPods Pro

Packaged release builds are expected to bundle `blueutil` inside the app so Bluetooth reconnect can work without extra setup.

If a build does **not** include bundled `blueutil`, the app still works for:

- device scanning
- battery display
- audio diagnostics
- speaker test
- microphone test
- soft repair
- medium repair

In that case, only Bluetooth reconnect requires installing `blueutil` manually.

## Source Builds

Building from source is a developer workflow. It requires:

- Xcode Command Line Tools
- the Swift toolchain

`blueutil` is optional for local development, but recommended if you want the built app to include Bluetooth reconnect support.

Helpful commands:

```bash
./build.sh
./package-release.sh
```

## Release Packaging

- `build.sh` builds `AirPods Fix.app`
- `package-release.sh` builds the app and creates a distributable `.dmg`
- `.github/workflows/build-release.yml` builds release artifacts on GitHub Actions

When a `v*` tag is pushed, the workflow is designed to build the packaged app on macOS and upload the `.dmg` to the GitHub Release.

## Operational Note

Unsigned apps may still trigger macOS Gatekeeper warnings on first launch. Signing and notarization are a separate release-hardening step.

# 中文说明

## 面向用户的使用路径

推荐的分发方式是：

1. 从 GitHub Releases 下载打包好的 `.dmg`
2. 打开磁盘镜像
3. 把 `AirPods Fix.app` 拖到 `Applications`
4. 正常打开使用

对于打包发布版，终端用户**不需要**：

- Xcode
- Xcode Command Line Tools
- 本地 Swift 工具链

## 运行时说明

- macOS 13 或更高版本
- AirPods 或 AirPods Pro

打包发布版默认应该把 `blueutil` 一起放进 app，这样蓝牙重连功能可以直接使用。

如果某个构建版本**没有**打包 `blueutil`，app 仍然可以正常使用这些能力：

- 设备扫描
- 电量显示
- 音频诊断
- 扬声器测试
- 麦克风测试
- 软修复
- 中修复

这种情况下，只有蓝牙重连功能需要你手动安装 `blueutil`。

## 从源码构建

源码构建是开发者路径，需要：

- Xcode Command Line Tools
- Swift 工具链

本地开发时 `blueutil` 不是强制要求，但如果你希望构建出的 app 自带蓝牙重连能力，建议安装它。

常用命令：

```bash
./build.sh
./package-release.sh
```

## 发布打包

- `build.sh` 负责构建 `AirPods Fix.app`
- `package-release.sh` 负责构建 app 并生成分发用 `.dmg`
- `.github/workflows/build-release.yml` 会在 GitHub Actions 上构建发布产物

当你 push `v*` tag 时，这个 workflow 会在 macOS runner 上打包 app，并把 `.dmg` 上传到 GitHub Release。

## 额外说明

如果 app 还没有完成签名和 notarization，用户首次打开时仍然可能遇到 macOS Gatekeeper 提示。这属于后续发布加固步骤，不影响当前“下载即用”的分发路径。

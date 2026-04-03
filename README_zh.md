**中文** | [English](README.md)

# AirPods Fix

一个原生 macOS 应用，用来诊断和修复常见的 AirPods 音频问题。

它主要解决 macOS 上最常见的几类麻烦：AirPods 明明连上了却没声音、系统把声音送错设备、音频退化成单声道 / 通话模式、音量实际上接近关掉，或者你只是想快速确认麦克风链路是否正常。

虽然这个 app 还是叫 AirPods Fix，但底层的音频诊断和修复流程也能帮到很多能正常暴露为 macOS 音频输出的蓝牙耳机。

## 普通用户

如果你只是想使用这个工具，直接下载 [GitHub Releases](https://github.com/XiXiphus/airpods-test-and-repair/releases) 里的打包版。

1. 下载最新 `.dmg`
2. 打开磁盘镜像
3. 把 `AirPods Fix.app` 拖到 `Applications`
4. 正常启动 app

只是运行 release 版的话，一般不需要 Xcode、Xcode Command Line Tools、Homebrew 或本地 Swift 工具链。

当前 release 可能还是未签名版本。如果 macOS 首次启动时拦截了 app，请对 app 点右键选择“打开”，或者到“系统设置 -> 隐私与安全性”里手动允许后再启动。

如果同时连接了多副兼容耳机，先在 app 里选中目标设备，再执行修复。

## 开发者

只有在你要参与开发时，才需要从源码构建。

- macOS 13 或更高版本
- Xcode Command Line Tools

常用命令：

```bash
./build.sh
./package-release.sh
```

- `./build.sh` 生成 `AirPods Fix.app`
- `./package-release.sh` 生成发布用 `.dmg`
- push `v*` tag 后，[GitHub Actions](https://github.com/XiXiphus/airpods-test-and-repair/actions) 会自动构建并发布 release 产物

更详细的打包和发布说明见 [RUNTIME.md](RUNTIME.md)。

## 运行时依赖

Release 构建应当把 `blueutil` 一起打进 app。

- release 版正常情况下自带 `blueutil`，蓝牙重连可直接使用
- 本地构建会优先使用系统里已有的 `blueutil`
- 如果缺少 `blueutil`，app 仍然可以使用扫描、诊断、扬声器测试、麦克风测试、刷新音频路由和重启 `coreaudiod`
- 如果缺少 `blueutil`，只有蓝牙重连步骤不可用

麦克风权限只会在你运行麦克风测试时请求。

## 这个 App 做什么

- 检测已连接的 AirPods 或兼容耳机；如果系统能提供电量数据，就显示左耳、右耳和充电盒电量
- 支持同时连接多副兼容耳机，并明确选择要修哪一副
- 右上角提供运行时语言切换，下拉菜单支持英文、简体中文和日文
- 过滤掉不能映射到真实音频输出的重复蓝牙 beacon 条目
- 诊断输出路由、立体声 / 单声道模式、采样率、静音状态和低音量
- 提供扬声器测试和麦克风测试
- 提供一键修复，按阶段依次尝试：
  - 刷新音频路由
  - 重启 `coreaudiod`
  - 条件允许时重连蓝牙
- 在刷新音频路由前先临时静音，完成后恢复原来的静音状态，避免切到 MacBook 扬声器时突然外放
- 保留带时间戳的日志，方便排查

## 快速使用

1. 把 AirPods 连接到 Mac
2. 打开 app，等待自动扫描
3. 如果连接了多副 AirPods，先选择目标设备
4. 查看诊断区域
5. 按需运行扬声器或麦克风测试
6. 如果需要，可在右上角菜单切换界面语言
7. 如果音频链路仍然异常，使用**一键修复**

## 系统要求

- macOS 13 (Ventura) 或更高版本
- AirPods、AirPods Pro，或任何能正常暴露为 macOS 音频输出且提供足够设备元数据用于匹配的蓝牙耳机

## 许可证

[MIT](LICENSE)

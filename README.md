[中文版](README_zh.md) | **English**

# AirPods Fix

A native macOS app for diagnosing and repairing common AirPods audio problems.

It is built for the cases that waste the most time on macOS: AirPods are connected but silent, macOS routes audio to the wrong output, sound drops into mono / call mode, volume is effectively off, or the microphone path needs a quick check.

The app is still branded around AirPods, but the underlying audio diagnosis and repair flow can also help many Bluetooth headsets that show up as normal macOS audio outputs.

## End Users

If you just want to use the app, download the packaged build from [GitHub Releases](https://github.com/XiXiphus/airpods-test-and-repair/releases).

1. Download the latest `.dmg`
2. Open the disk image
3. Drag `AirPods Fix.app` into `Applications`
4. Launch the app normally

You do not need Xcode, Xcode Command Line Tools, Homebrew, or a local Swift toolchain to run the release build.

Current releases may be unsigned. If macOS blocks the first launch, Control-click the app and choose `Open`, or allow it in `System Settings -> Privacy & Security` and launch it again.

If more than one compatible headset is connected, choose the correct target device in the app before running repair.

## Developers

Build from source only if you are working on the project itself.

- macOS 13 or later
- Xcode Command Line Tools

Common commands:

```bash
./build.sh
./package-release.sh
```

- `./build.sh` builds `AirPods Fix.app`
- `./package-release.sh` builds the app and creates a release `.dmg`
- Pushing a `v*` tag triggers [GitHub Actions](https://github.com/XiXiphus/airpods-test-and-repair/actions) to build and publish a release artifact

More packaging and release notes are in [RUNTIME.md](RUNTIME.md).

## Runtime Dependencies

Release builds are expected to bundle `blueutil` inside the app.

- Release builds should include `blueutil`, so Bluetooth reconnect is available out of the box
- Local builds use a system-installed `blueutil` if one is available
- If `blueutil` is missing, the app still supports scanning, diagnosis, speaker test, microphone test, audio route refresh, and `coreaudiod` restart
- If `blueutil` is missing, only the Bluetooth reconnect step is unavailable

The app asks for microphone permission only when you run the microphone test.

## What The App Does

- Detects connected AirPods and compatible headsets that expose battery data, then shows left, right, and case battery levels when available
- Supports multiple compatible headsets and lets you choose the repair target explicitly
- Includes a runtime language switcher in the top-right corner with English, Simplified Chinese, and Japanese
- Filters duplicate Bluetooth beacon entries that do not map to a real audio output device
- Diagnoses output routing, stereo vs mono mode, sample rate, mute state, and low volume
- Includes speaker and microphone test tools
- Provides one-click repair with staged recovery:
  - refresh audio routing
  - restart `coreaudiod`
  - reconnect Bluetooth when available
- Temporarily mutes system output during route refresh, then restores the original mute state, so fallback switching does not blast audio through the MacBook speakers
- Keeps a timestamped log for troubleshooting

## Quick Use

1. Connect AirPods to your Mac
2. Open the app and let it scan
3. Choose the target pair if more than one is connected
4. Check the diagnostic section
5. Run speaker or microphone tests if needed
6. Switch the UI language from the top-right menu if needed
7. Use **One-Click Repair** if the audio path is still broken

## Requirements

- macOS 13 (Ventura) or later
- AirPods, AirPods Pro, or another Bluetooth headset that exposes a normal macOS audio output and enough device metadata for matching

## License

[MIT](LICENSE)

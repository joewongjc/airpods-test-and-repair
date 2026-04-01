[中文版](README_zh.md) | **English**

# AirPods Test and Repair

A native macOS diagnostic and repair tool for AirPods.

When your AirPods connect but produce no sound, distorted audio, or microphone issues, this app helps you diagnose and fix the problem without restarting your Mac.

## Features

### Device Detection & Battery

- Auto-detects all connected AirPods via Bluetooth
- Lets you choose the target pair when multiple AirPods are connected at the same time
- Shows real-time battery levels for left earbud, right earbud, and charging case
- Displays connection status with color-coded indicators (green/yellow/red)

### Audio Diagnostics

- Checks if AirPods is the current default output device
- Detects audio channel configuration (stereo vs mono)
- Reads sample rate (24kHz, 44.1kHz, 48kHz) to identify audio mode:
  - **Stereo mode** (44.1kHz/48kHz): Full quality music playback
  - **Mono 24kHz**: Reduced quality, usually a routing issue
  - **Voice call mode** (8kHz/16kHz): Mic active, lower speaker quality
- Monitors system volume and mute status
- Flags issues: wrong output device, degraded mono/call mode, muted audio, extremely low volume

### Speaker Test

Plays system test sounds (Ping + Glass) through AirPods so you can confirm audio output is working on both earbuds.

### Microphone Test

Real-time microphone level monitoring with:

- RMS-based level meter with smooth animation
- Signal quality indicator: Silent / Weak / Normal / Loud / Very Loud
- Peak level marker with auto-decay
- Color-coded gradient bar (green -> yellow -> orange -> red)
- Auto-retry on silent detection (handles permission grant delays)

### Audio Repair (3 Levels)

**1. Soft Fix** - Audio route refresh (no service interruption)

- Unmutes system if muted
- Boosts volume if below 10%
- Switches output to built-in speakers, then back to AirPods
- Forces macOS to rebuild the audio route without touching core services

**2. Medium Fix** - Restart `coreaudiod`

- Kills and restarts macOS core audio daemon
- Brief audio interruption (~3 seconds)
- Re-diagnoses audio state after recovery

**3. Hard Fix** - Bluetooth reconnect

- Disconnects AirPods via `blueutil`
- Waits for Bluetooth handshake to fully close
- Reconnects and rebuilds audio channels
- Runs diagnostics after reconnection to verify

Each repair level shows a real-time progress bar with step descriptions.
The app exposes these levels through a single **One-Click Repair** action and stops as soon as a stage resolves the issue.

### Diagnostic Log

Expandable log panel with timestamped entries showing every action taken - useful for understanding what went wrong and verifying the fix.

## Requirements

- macOS 13 (Ventura) or later
- [blueutil](https://github.com/toy/blueutil) - for Bluetooth control (`brew install blueutil`)
- AirPods (any generation) or AirPods Pro

## Build

```bash
git clone https://github.com/joewongjc/airpods-test-and-repair.git
cd airpods-test-and-repair
./build.sh
```

No Xcode required - just the Swift toolchain that comes with Xcode Command Line Tools.

## Install

After building, move the app to your preferred location:

```bash
# User Applications
cp -r "AirPods Fix.app" ~/Applications/

# Or system-wide (requires admin)
sudo cp -r "AirPods Fix.app" /Applications/
```

Or simply double-click the `.app` to run without installing.

## Usage

1. Connect your AirPods to your Mac
2. Open the app - it auto-scans for connected AirPods
3. If multiple pairs are connected, choose the target pair from the device picker
4. Check the diagnostic panel for any issues (red indicators)
5. Use **Speaker Test** to verify audio output
6. Use **Microphone Test** to verify mic input
7. If something's wrong, hit **One-Click Repair** to escalate through the repair levels automatically

### When to use each repair level

| Symptom | Recommended Fix |
|---|---|
| Connected but no sound | Soft Fix (audio route refresh) |
| Sound cuts in and out | Medium Fix (restart coreaudiod) |
| One earbud not working | Hard Fix (Bluetooth reconnect) |
| Stuck in mono/call mode | Medium Fix, then check if a call app is active |
| Mic not picking up sound | Hard Fix (reconnect rebuilds audio channels) |

## How It Works

The app is a single-file SwiftUI application (~1200 lines) that uses:

- **CoreAudio API** for direct audio device switching (faster and more reliable than AppleScript)
- **AVFoundation** for real-time microphone level monitoring
- **system_profiler** to read Bluetooth device info and battery levels
- **blueutil** for programmatic Bluetooth disconnect/reconnect
- **osascript** for volume and mute control

Unicode normalization handles macOS smart quotes in device names (e.g., AirPods Pro with curly quotes) to avoid matching failures.

## Permissions

The app requests **Microphone access** for the mic test feature. This is optional - all other features work without it.

## License

MIT

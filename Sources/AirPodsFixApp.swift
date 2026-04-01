import Cocoa
import SwiftUI
import AVFoundation
import CoreAudio

// MARK: - 数据模型

struct AirPodsDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let batteryLeft: String
    let batteryRight: String
    let batteryCase: String
    let macAddress: String

    init(name: String, batteryLeft: String, batteryRight: String, batteryCase: String, macAddress: String) {
        self.name = name
        self.batteryLeft = batteryLeft
        self.batteryRight = batteryRight
        self.batteryCase = batteryCase
        self.macAddress = macAddress
        let normalizedMAC = normalizeHardwareIdentifier(macAddress)
        self.id = normalizedMAC.isEmpty ? normalizeAudioDeviceName(name) : normalizedMAC
    }

    var shortAddress: String? {
        let normalizedMAC = normalizeHardwareIdentifier(macAddress)
        guard normalizedMAC.count >= 4 else { return nil }
        return String(normalizedMAC.suffix(4)).uppercased()
    }

    var pickerLabel: String {
        guard let shortAddress else { return name }
        return "\(name) · \(shortAddress)"
    }
}

struct AudioDiagnosis {
    var isDefaultOutput = false
    var outputChannels = "?"
    var sampleRate = "?"
    var volume = "?"
    var isMuted = false

    var channelCount: Int? { Int(outputChannels) }
    var sampleRateHz: Int? { Int(sampleRate) }
    var volumePercent: Int? { Int(volume) }

    var isLowVolume: Bool {
        (volumePercent ?? 50) < 5
    }

    var isReducedQualityMode: Bool {
        guard let ch = channelCount, let sr = sampleRateHz else { return false }
        return ch < 2 || sr < 44100
    }

    var hasIssue: Bool {
        !isDefaultOutput || isMuted || isLowVolume || isReducedQualityMode
    }

    var modeLabel: String {
        guard let ch = channelCount, let sr = sampleRateHz else { return "未知" }
        if ch >= 2 && sr >= 44100 { return "立体声 \(sr/1000)kHz" }
        if ch == 1 && sr == 24000 { return "单声道 24kHz" }
        if ch == 1 && (sr == 8000 || sr == 16000) { return "通话模式 \(sr/1000)kHz" }
        return "\(ch == 1 ? "单声道" : "立体声") \(sr/1000)kHz"
    }
}

// MARK: - Shell 工具

func normalizeAudioDeviceName(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{201C}", with: "\"")
        .replacingOccurrences(of: "\u{201D}", with: "\"")
        .replacingOccurrences(of: ":", with: "")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizeHardwareIdentifier(_ value: String) -> String {
    normalizeAudioDeviceName(value)
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")
}

func lineIndentation(_ line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.count
}

func bluetoothDeviceBlocks(from output: String) -> [(name: String, lines: [String])] {
    let allLines = output.components(separatedBy: "\n")
    var blocks: [(name: String, lines: [String])] = []
    var index = 0

    while index < allLines.count {
        let line = allLines[index]
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        let indentation = lineIndentation(line)

        guard trimmedLine.hasSuffix(":"), indentation >= 8 else {
            index += 1
            continue
        }

        let name = String(trimmedLine.dropLast())
        var blockLines: [String] = []
        var nextIndex = index + 1

        while nextIndex < allLines.count {
            let nextLine = allLines[nextIndex]
            let trimmedNextLine = nextLine.trimmingCharacters(in: .whitespaces)
            let nextIndentation = lineIndentation(nextLine)

            if trimmedNextLine.hasSuffix(":"), nextIndentation <= indentation {
                break
            }

            blockLines.append(trimmedNextLine)
            nextIndex += 1
        }

        blocks.append((name: name, lines: blockLines))
        index = nextIndex
    }

    return blocks
}

struct ShellCommandResult {
    let output: String
    let status: Int32

    var succeeded: Bool { status == 0 }
}

func commandSearchPaths() -> [String] {
    let preferred = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)

    var result: [String] = []
    for path in preferred + environmentPaths where !path.isEmpty {
        if !result.contains(path) {
            result.append(path)
        }
    }
    return result
}

func bundledToolURL(named name: String) -> URL? {
    guard let resourceURL = Bundle.main.resourceURL else { return nil }
    let candidate = resourceURL.appendingPathComponent("bin/\(name)")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

func resolvedToolURL(named name: String) -> URL? {
    if let bundled = bundledToolURL(named: name) {
        return bundled
    }

    for basePath in commandSearchPaths() {
        let candidate = URL(fileURLWithPath: basePath).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }

    return nil
}

func runProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String] = [:]
) -> ShellCommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    if !environment.isEmpty {
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
    }
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ShellCommandResult(output: error.localizedDescription, status: -1)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return ShellCommandResult(output: output, status: process.terminationStatus)
}

func runShell(_ command: String) -> ShellCommandResult {
    runProcess(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-c", command],
        environment: ["PATH": commandSearchPaths().joined(separator: ":")]
    )
}

func runTool(named name: String, arguments: [String]) -> ShellCommandResult {
    guard let executableURL = resolvedToolURL(named: name) else {
        return ShellCommandResult(output: "\(name) not found", status: 127)
    }
    return runProcess(executableURL: executableURL, arguments: arguments)
}

func runBlueutil(_ arguments: [String]) -> ShellCommandResult {
    runTool(named: "blueutil", arguments: arguments)
}

func shell(_ command: String) -> String {
    runShell(command).output
}

// MARK: - CoreAudio 设备切换

struct AudioOutputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let modelUID: String
    let transportType: UInt32
    let isOutput: Bool

    var isBluetoothTransport: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioOutputMatch {
    case matched(AudioOutputDevice)
    case ambiguous([AudioOutputDevice])
    case notFound
}

func audioObjectStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutableBytes(of: &value) { rawBuffer in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, rawBuffer.baseAddress!)
    }
    guard status == noErr else { return nil }
    return value as String
}

func audioObjectUInt32Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func audioObjectFloat64Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func outputChannelCount(for deviceID: AudioDeviceID) -> Int? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return nil }

    let rawPointer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else { return nil }
    let bufferList = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
    let channels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    return channels > 0 ? channels : nil
}

func defaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    ) == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return deviceID
}

func listAudioOutputDevices() -> [AudioOutputDevice] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

    var result: [AudioOutputDevice] = []
    for did in deviceIDs {
        guard
            let name = audioObjectStringProperty(objectID: did, selector: kAudioObjectPropertyName),
            let uid = audioObjectStringProperty(objectID: did, selector: kAudioDevicePropertyDeviceUID),
            let transportType = audioObjectUInt32Property(objectID: did, selector: kAudioDevicePropertyTransportType),
            outputChannelCount(for: did) != nil
        else { continue }

        let modelUID = audioObjectStringProperty(objectID: did, selector: kAudioDevicePropertyModelUID) ?? ""
        result.append(
            AudioOutputDevice(
                id: did,
                name: name,
                uid: uid,
                modelUID: modelUID,
                transportType: transportType,
                isOutput: true
            )
        )
    }
    return result
}

func defaultOutputDevice() -> AudioOutputDevice? {
    guard let deviceID = defaultOutputDeviceID() else { return nil }
    return listAudioOutputDevices().first(where: { $0.id == deviceID })
}

func nominalSampleRate(for deviceID: AudioDeviceID) -> Int? {
    guard let sampleRate = audioObjectFloat64Property(objectID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) else {
        return nil
    }
    return Int(sampleRate.rounded())
}

func audioOutputMatchScore(for candidate: AudioOutputDevice, target: AirPodsDevice) -> Int {
    let normalizedTargetName = normalizeAudioDeviceName(target.name)
    let normalizedTargetMAC = normalizeHardwareIdentifier(target.macAddress)
    let candidateName = normalizeAudioDeviceName(candidate.name)
    let candidateUID = normalizeHardwareIdentifier(candidate.uid)
    let candidateModelUID = normalizeHardwareIdentifier(candidate.modelUID)

    let hasExactNameMatch = candidateName == normalizedTargetName
    let hasPartialNameMatch = candidateName.contains(normalizedTargetName) || normalizedTargetName.contains(candidateName)
    let hasMACMatch =
        !normalizedTargetMAC.isEmpty &&
        (candidateUID.contains(normalizedTargetMAC) || candidateModelUID.contains(normalizedTargetMAC))
    let hasAirPodsSignal =
        candidateName.contains("airpods") ||
        candidateUID.contains("airpods") ||
        candidateModelUID.contains("airpods")

    guard hasExactNameMatch || hasPartialNameMatch || hasMACMatch || hasAirPodsSignal else {
        return 0
    }

    var score = 0
    if candidate.isBluetoothTransport { score += 40 }
    if hasAirPodsSignal { score += 20 }
    if hasPartialNameMatch { score += 80 }
    if hasExactNameMatch { score += 80 }
    if hasMACMatch { score += 200 }
    return score
}

func matchAudioOutputDevice(for device: AirPodsDevice) -> AudioOutputMatch {
    let rankedMatches = listAudioOutputDevices()
        .compactMap { candidate -> (AudioOutputDevice, Int)? in
            let score = audioOutputMatchScore(for: candidate, target: device)
            return score > 0 ? (candidate, score) : nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.isBluetoothTransport && !rhs.0.isBluetoothTransport
        }

    guard let best = rankedMatches.first else { return .notFound }

    let topMatches = rankedMatches
        .filter { $0.1 == best.1 }
        .map(\.0)

    if topMatches.count > 1 {
        return .ambiguous(topMatches)
    }
    return .matched(best.0)
}

@discardableResult
func switchOutputDevice(to device: AudioOutputDevice) -> Bool {
    var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = device.id
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
    )
    return status == noErr
}

@discardableResult
func switchOutputDevice(toNameContaining keyword: String) -> Bool {
    let devices = listAudioOutputDevices()
    let normalizedKeyword = normalizeAudioDeviceName(keyword)
    guard let target = devices.first(where: {
        normalizeAudioDeviceName($0.name).contains(normalizedKeyword)
    }) else { return false }
    return switchOutputDevice(to: target)
}

func fallbackAudioOutputDevice(excluding deviceName: String) -> AudioOutputDevice? {
    let devices = listAudioOutputDevices()
    let normalizedTarget = normalizeAudioDeviceName(deviceName)
    let priorityKeywords = ["macbook", "built-in", "内置", "speaker", "speakers", "扬声器"]

    func isTargetDevice(_ candidate: AudioOutputDevice) -> Bool {
        let normalizedCandidate = normalizeAudioDeviceName(candidate.name)
        return normalizedCandidate == normalizedTarget
            || normalizedCandidate.contains(normalizedTarget)
            || normalizedTarget.contains(normalizedCandidate)
    }

    if let preferred = devices.first(where: { candidate in
        let normalizedCandidate = normalizeAudioDeviceName(candidate.name)
        return !isTargetDevice(candidate)
            && priorityKeywords.contains(where: { normalizedCandidate.contains($0) })
    }) {
        return preferred
    }

    if let nonAirPods = devices.first(where: { candidate in
        let normalizedCandidate = normalizeAudioDeviceName(candidate.name)
        return !isTargetDevice(candidate) && !normalizedCandidate.contains("airpods")
    }) {
        return nonAirPods
    }

    return devices.first(where: { !isTargetDevice($0) })
}

// MARK: - 诊断引擎

class DiagnosticEngine: ObservableObject {
    @Published var device: AirPodsDevice?
    @Published var diagnosis = AudioDiagnosis()
    @Published var logs: [LogEntry] = []
    @Published var isScanning = false
    @Published var isFixing = false
    @Published var bluetoothOn = true
    @Published var allDevices: [AirPodsDevice] = []
    private var hasLoggedMissingBlueutil = false

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let message: String
        let isError: Bool
    }

    init() { scan() }

    func log(_ msg: String, isError: Bool = false) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let entry = LogEntry(time: fmt.string(from: Date()), message: msg, isError: isError)
        DispatchQueue.main.async { self.logs.append(entry) }
    }

    private func selectedDeviceLabel(for device: AirPodsDevice) -> String {
        allDevices.count > 1 ? device.pickerLabel : device.name
    }

    private func blueutilGuidance() -> String {
        "未找到 blueutil；请使用预编译发布版，或先安装 blueutil（brew install blueutil）"
    }

    private func noteMissingBlueutilIfNeeded() {
        guard !hasLoggedMissingBlueutil else { return }
        hasLoggedMissingBlueutil = true
        log("蓝牙重连功能受限，\(blueutilGuidance())")
    }

    private func ensureBlueutilAvailable(for feature: String) -> Bool {
        guard resolvedToolURL(named: "blueutil") != nil else {
            log("\(feature) 需要 blueutil，\(blueutilGuidance())", isError: true)
            return false
        }
        return true
    }

    private func commandFailureSuffix(_ result: ShellCommandResult) -> String {
        let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return "（退出码 \(result.status)）" }
        return "：\(trimmedOutput)"
    }

    @discardableResult
    private func runCommand(_ command: String, failureMessage: String) -> Bool {
        let result = runShell(command)
        guard result.succeeded else {
            log("\(failureMessage)\(commandFailureSuffix(result))", isError: true)
            return false
        }
        return true
    }

    private func restartCoreAudioService() -> Bool {
        let nonInteractiveSudo = runShell("sudo -n killall coreaudiod")
        if nonInteractiveSudo.succeeded {
            return true
        }

        let directKill = runShell("killall coreaudiod")
        if directKill.succeeded {
            return true
        }

        let preferredFailure = nonInteractiveSudo.output.isEmpty ? directKill : nonInteractiveSudo
        log("无法重启音频服务\(commandFailureSuffix(preferredFailure))", isError: true)
        return false
    }

    func selectDevice(withID id: String) {
        guard let selected = allDevices.first(where: { $0.id == id }) else { return }
        guard device?.id != selected.id else { return }
        DispatchQueue.main.async { self.device = selected }
        log("切换目标设备: \(selectedDeviceLabel(for: selected))")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            diagnoseAudio(for: selected)
        }
    }

    func scan() {
        isScanning = true
        logs.removeAll()
        log("开始扫描...")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let previousDeviceID = device?.id
            let btPower = runBlueutil(["--power"])
            let btSysProf = runShell("system_profiler SPBluetoothDataType | head -5")
            if btPower.status == 127 {
                noteMissingBlueutilIfNeeded()
            }
            let hasBTOn = btPower.succeeded && btPower.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                || btSysProf.output.contains("State: On")
            log("蓝牙: \(hasBTOn ? "已开启" : "未开启")")
            DispatchQueue.main.async { self.bluetoothOn = hasBTOn }
            if !hasBTOn {
                log("蓝牙未开启", isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            let btInfoResult = runShell("system_profiler SPBluetoothDataType")
            guard btInfoResult.succeeded else {
                log("读取蓝牙设备信息失败\(commandFailureSuffix(btInfoResult))", isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            let devices = bluetoothDeviceBlocks(from: btInfoResult.output).compactMap { block -> AirPodsDevice? in
                var battL = "-", battR = "-", battC = "-", mac = ""
                for line in block.lines {
                    if line.starts(with: "Left Battery Level:") { battL = line.components(separatedBy: ": ").last ?? "-" }
                    if line.starts(with: "Right Battery Level:") { battR = line.components(separatedBy: ": ").last ?? "-" }
                    if line.starts(with: "Case Battery Level:") { battC = line.components(separatedBy: ": ").last ?? "-" }
                    if line.starts(with: "Address:") { mac = line.components(separatedBy: ": ").last ?? "" }
                }

                guard battL != "-" || battR != "-" else { return nil }
                return AirPodsDevice(
                    name: block.name,
                    batteryLeft: battL,
                    batteryRight: battR,
                    batteryCase: battC,
                    macAddress: mac
                )
            }

            let selectedDevice = devices.first(where: { $0.id == previousDeviceID }) ?? devices.first
            DispatchQueue.main.async {
                self.allDevices = devices
                self.device = selectedDevice
            }

            if devices.isEmpty {
                self.log("未找到已连接的 AirPods", isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            if devices.count > 1 {
                self.log("检测到 \(devices.count) 台 AirPods，可在设备卡片中切换目标设备")
            }

            guard let selectedDevice else {
                self.log("未找到可用的目标设备", isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            self.log("已连接: \(self.selectedDeviceLabel(for: selectedDevice))")
            self.diagnoseAudio(for: selectedDevice)
            DispatchQueue.main.async { self.isScanning = false }
        }
    }

    @discardableResult
    func diagnoseAudio(for device: AirPodsDevice) -> AudioDiagnosis {
        var diag = AudioDiagnosis()

        switch matchAudioOutputDevice(for: device) {
        case .matched(let audioOutput):
            if let channels = outputChannelCount(for: audioOutput.id) {
                diag.outputChannels = "\(channels)"
            }
            if let sampleRate = nominalSampleRate(for: audioOutput.id) {
                diag.sampleRate = "\(sampleRate)"
            }
            diag.isDefaultOutput = defaultOutputDeviceID() == audioOutput.id
        case .ambiguous:
            log("检测到多个与 \(selectedDeviceLabel(for: device)) 匹配的音频输出，请先在系统声音设置里选中目标设备", isError: true)
        case .notFound:
            log("未在音频输出列表中找到 \(selectedDeviceLabel(for: device))", isError: true)
        }

        let volumeResult = runShell("osascript -e 'output volume of (get volume settings)'")
        if volumeResult.succeeded {
            diag.volume = volumeResult.output
        } else {
            log("读取系统音量失败\(commandFailureSuffix(volumeResult))", isError: true)
        }

        let mutedResult = runShell("osascript -e 'output muted of (get volume settings)'")
        if mutedResult.succeeded {
            diag.isMuted = mutedResult.output == "true"
        } else {
            log("读取静音状态失败\(commandFailureSuffix(mutedResult))", isError: true)
        }

        log("模式: \(diag.modeLabel) | 音量: \(diag.volume)%\(diag.isMuted ? " (静音)" : "")")
        if !diag.isDefaultOutput { log("\(selectedDeviceLabel(for: device)) 非当前输出设备", isError: true) }
        if diag.isMuted { log("系统已静音", isError: true) }
        if diag.isDefaultOutput, diag.isReducedQualityMode { log("当前输出模式异常：\(diag.modeLabel)", isError: true) }
        DispatchQueue.main.async { self.diagnosis = diag }
        return diag
    }

    // MARK: 修复进度

    @Published var fixProgress: Double = 0       // 0~1
    @Published var fixStepText: String = ""      // 当前步骤描述
    @Published var fixDone: Bool = false          // 修复完成

    private func step(_ text: String, progress: Double) {
        log(text)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.fixStepText = text
                self.fixProgress = progress
            }
        }
    }

    private func beginFix() {
        isFixing = true
        fixDone = false
        fixProgress = 0
        fixStepText = ""
    }

    private func endFix() {
        DispatchQueue.main.async {
            withAnimation {
                self.fixProgress = 1.0
                self.fixDone = true
            }
            // 3 秒后清除完成状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    self.isFixing = false
                    self.fixDone = false
                    self.fixProgress = 0
                    self.fixStepText = ""
                }
            }
        }
    }

    private func sanitizedBluetoothAddress(for device: AirPodsDevice) -> String? {
        let safeMac = device.macAddress
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ";", with: "")
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "$", with: "")
        return safeMac.isEmpty ? nil : safeMac
    }

    @discardableResult
    private func switchToSelectedAirPodsOutput(_ device: AirPodsDevice) -> Bool {
        switch matchAudioOutputDevice(for: device) {
        case .matched(let audioOutput):
            return switchOutputDevice(to: audioOutput)
        case .ambiguous:
            log("无法唯一定位 \(selectedDeviceLabel(for: device)) 的音频输出，请先在系统声音设置中选中目标设备", isError: true)
            return false
        case .notFound:
            log("未找到 \(selectedDeviceLabel(for: device)) 的音频输出", isError: true)
            return false
        }
    }

    @discardableResult
    private func refreshAudioRoute(
        for device: AirPodsDevice,
        fallbackStep: String,
        fallbackProgress: Double,
        targetStep: String,
        targetProgress: Double,
        settleStep: String,
        settleProgress: Double
    ) -> Bool {
        step(fallbackStep, progress: fallbackProgress)
        if let fallback = fallbackAudioOutputDevice(excluding: device.name) {
            if switchOutputDevice(to: fallback) {
                log("已切换到 \(fallback.name)")
                Thread.sleep(forTimeInterval: 1.0)
            } else {
                log("切换到 \(fallback.name) 失败，继续尝试重选 \(device.name)", isError: true)
            }
        } else {
            log("未找到可用的备用输出，直接重选 \(device.name)")
        }

        step(targetStep, progress: targetProgress)
        let ok = switchToSelectedAirPodsOutput(device)
        if ok {
            log("已切换到 \(selectedDeviceLabel(for: device))")
        } else {
            log("切换到 \(selectedDeviceLabel(for: device)) 失败", isError: true)
        }

        step(settleStep, progress: settleProgress)
        Thread.sleep(forTimeInterval: 1.0)
        return ok
    }

    // 软修复: 修静音/音量/输出设备，不动 coreaudiod，不断蓝牙
    // 核心: 先切回本机扬声器，再切回 AirPods，强制刷新音频路由
    func fix() {
        guard let dev = device else { return }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in

            step("检查静音状态...", progress: 0.05)
            Thread.sleep(forTimeInterval: 0.3)
            if diagnosis.isMuted {
                step("取消静音...", progress: 0.1)
                _ = runCommand("osascript -e 'set volume without output muted'", failureMessage: "取消静音失败")
            }

            step("检查音量...", progress: 0.15)
            Thread.sleep(forTimeInterval: 0.3)
            if let vol = Int(diagnosis.volume), vol < 10 {
                step("调高音量至 50%...", progress: 0.2)
                _ = runCommand("osascript -e 'set volume output volume 50'", failureMessage: "调整音量失败")
            }

            let ok = refreshAudioRoute(
                for: dev,
                fallbackStep: "切换到备用输出...",
                fallbackProgress: 0.3,
                targetStep: "切换输出到 AirPods...",
                targetProgress: 0.6,
                settleStep: "等待音频通道建立...",
                settleProgress: 0.75
            )

            step("验证修复结果...", progress: 0.9)
            self.diagnoseAudio(for: dev)

            if ok {
                step("音频路由已刷新", progress: 1.0)
            } else {
                step("切换失败，试「重启音频」或「重连蓝牙」", progress: 1.0)
            }
            endFix()
        }
    }

    // 中修复: 重启 coreaudiod
    func restartAudioService() {
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            step("停止音频服务...", progress: 0.15)
            guard restartCoreAudioService() else {
                step("重启音频服务失败", progress: 1.0)
                endFix()
                return
            }

            step("等待服务重启...", progress: 0.35)
            Thread.sleep(forTimeInterval: 1.5)
            step("音频服务恢复中...", progress: 0.55)
            Thread.sleep(forTimeInterval: 1.5)

            step("验证音频状态...", progress: 0.8)
            Thread.sleep(forTimeInterval: 0.5)
            if let dev = device {
                self.diagnoseAudio(for: dev)
            }

            step("音频服务已重启", progress: 1.0)
            endFix()
        }
    }

    // 硬修复: 断开重连蓝牙
    func reconnectBluetooth() {
        guard ensureBlueutilAvailable(for: "蓝牙重连") else { return }
        guard let dev = device else {
            log("未找到可修复的设备", isError: true); return
        }
        guard let safeMac = sanitizedBluetoothAddress(for: dev) else {
            log("蓝牙地址无效或缺失", isError: true); return
        }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            step("断开 AirPods...", progress: 0.1)
            let disconnectResult = runBlueutil(["--disconnect", safeMac])
            let disconnectSucceeded = disconnectResult.succeeded
            if !disconnectSucceeded {
                log("断开蓝牙设备失败\(commandFailureSuffix(disconnectResult))", isError: true)
            }

            step("等待断开完成...", progress: 0.2)
            Thread.sleep(forTimeInterval: 1.5)
            step("已断开，准备重连...", progress: 0.3)
            Thread.sleep(forTimeInterval: 1.5)

            step("重新连接 AirPods...", progress: 0.4)
            let reconnectResult = runBlueutil(["--connect", safeMac])
            guard reconnectResult.succeeded else {
                log("重新连接蓝牙设备失败\(commandFailureSuffix(reconnectResult))", isError: true)
                step(disconnectSucceeded ? "蓝牙重连失败" : "蓝牙断开/重连失败", progress: 1.0)
                endFix()
                return
            }

            step("等待蓝牙握手...", progress: 0.5)
            Thread.sleep(forTimeInterval: 2)
            step("建立音频通道...", progress: 0.65)
            Thread.sleep(forTimeInterval: 2)
            step("连接稳定中...", progress: 0.8)
            Thread.sleep(forTimeInterval: 1)

            step("验证连接状态...", progress: 0.9)
            self.diagnoseAudio(for: dev)

            step("蓝牙重连完成", progress: 1.0)
            endFix()
        }
    }

    // MARK: 智能一键修复（按强度递增依次尝试）
    func runSmartRepair() {
        guard let dev = device else { return }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in

            // ===== 阶段 1: 软修复 (0% ~ 30%) =====
            step("开始修复：检查静音状态...", progress: 0.05)
            Thread.sleep(forTimeInterval: 0.3)
            if diagnosis.isMuted {
                step("取消静音...", progress: 0.08)
                _ = runCommand("osascript -e 'set volume without output muted'", failureMessage: "取消静音失败")
            }

            step("检查音量...", progress: 0.12)
            Thread.sleep(forTimeInterval: 0.3)
            if let vol = Int(diagnosis.volume), vol < 10 {
                step("调高音量至 50%...", progress: 0.15)
                _ = runCommand("osascript -e 'set volume output volume 50'", failureMessage: "调整音量失败")
            }

            _ = refreshAudioRoute(
                for: dev,
                fallbackStep: "刷新音频路由...",
                fallbackProgress: 0.20,
                targetStep: "重选 AirPods 输出...",
                targetProgress: 0.24,
                settleStep: "等待音频通道建立...",
                settleProgress: 0.28
            )

            step("软修复完成，验证状态...", progress: 0.30)
            let softDiagnosis = self.diagnoseAudio(for: dev)

            if !softDiagnosis.hasIssue {
                step("软修复已解决问题", progress: 1.0)
                endFix()
                return
            }

            // ===== 阶段 2: 中修复 (30% ~ 60%) =====
            step("软修复未解决，重启音频服务...", progress: 0.35)
            let audioRestarted = restartCoreAudioService()

            if audioRestarted {
                step("等待服务重启...", progress: 0.45)
                Thread.sleep(forTimeInterval: 1.5)
                step("音频服务恢复中...", progress: 0.55)
                Thread.sleep(forTimeInterval: 1.5)
            } else {
                step("无法重启音频服务，继续尝试蓝牙重连...", progress: 0.60)
            }

            step("中修复完成，验证状态...", progress: 0.60)
            let mediumDiagnosis = self.diagnoseAudio(for: dev)

            if !mediumDiagnosis.hasIssue {
                step("中修复已解决问题", progress: 1.0)
                endFix()
                return
            }

            // ===== 阶段 3: 硬修复 (60% ~ 100%) =====
            guard ensureBlueutilAvailable(for: "蓝牙重连") else {
                step("未找到 blueutil，无法执行蓝牙重连", progress: 1.0)
                endFix()
                return
            }

            guard let safeMac = sanitizedBluetoothAddress(for: dev) else {
                step("中修复未解决，但无法获取蓝牙地址", progress: 1.0)
                endFix()
                return
            }

            step("中修复未解决，断开蓝牙...", progress: 0.65)
            let disconnectResult = runBlueutil(["--disconnect", safeMac])
            let disconnectSucceeded = disconnectResult.succeeded
            if !disconnectSucceeded {
                log("断开蓝牙设备失败\(commandFailureSuffix(disconnectResult))", isError: true)
            }

            step("等待蓝牙断开...", progress: 0.72)
            Thread.sleep(forTimeInterval: 1.5)
            step("重新连接 AirPods...", progress: 0.78)
            let reconnectResult = runBlueutil(["--connect", safeMac])
            guard reconnectResult.succeeded else {
                log("重新连接蓝牙设备失败\(commandFailureSuffix(reconnectResult))", isError: true)
                step(disconnectSucceeded ? "硬修复执行失败" : "硬修复未能完成蓝牙重连", progress: 1.0)
                endFix()
                return
            }

            step("等待蓝牙握手与音频通道建立...", progress: 0.88)
            Thread.sleep(forTimeInterval: 4.0)

            step("硬修复完成，验证状态...", progress: 0.95)
            let finalDiagnosis = self.diagnoseAudio(for: dev)

            if finalDiagnosis.hasIssue {
                step("所有修复尝试完毕，仍有问题，建议检查硬件", progress: 1.0)
            } else {
                step("硬修复已解决问题，AirPods 恢复正常", progress: 1.0)
            }
            endFix()
        }
    }

    // MARK: 播放测试音

    @Published var isPlayingTest = false

    func playTestSound() {
        isPlayingTest = true
        log("播放测试音...")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // 用系统音效测试，简短清脆
            if let sound = NSSound(named: "Ping") {
                sound.play()
                Thread.sleep(forTimeInterval: 1.0)
            }
            // 再来一个不同的音效确认
            if let sound = NSSound(named: "Glass") {
                sound.play()
                Thread.sleep(forTimeInterval: 1.0)
            }
            log("测试音播放完毕")
            DispatchQueue.main.async { self.isPlayingTest = false }
        }
    }

    // MARK: 麦克风监测

    @Published var micLevel: Float = 0
    @Published var micPeak: Float = 0
    @Published var isMicMonitoring = false
    private var audioEngine: AVAudioEngine?
    private var micTimer: Timer?
    private var peakDecayTimer: Timer?

    private var micRetryCount = 0

    func startMicMonitor() {
        guard !isMicMonitoring else { return }
        micRetryCount = 0
        launchMicEngine()
    }

    private func launchMicEngine() {
        // 清理旧引擎
        if let old = audioEngine {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }

        log("启动麦克风监测...")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)
        log("麦克风格式: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch")

        var silentFrames = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            // 取所有通道的最大 RMS
            var maxRMS: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                var sum: Float = 0
                let data = channelData[ch]
                for i in 0..<count {
                    let sample = data[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(count))
                maxRMS = max(maxRMS, rms)
            }

            // 转换为 0~1 范围 (-50dB ~ 0dB)
            let db = 20 * log10(max(maxRMS, 0.000001))
            let normalized = max(0, min(1, (db + 50) / 50))

            // 检测连续静音 (权限刚授予时引擎拿不到数据)
            if maxRMS < 0.0001 {
                silentFrames += 1
                // 连续 ~2 秒静音且没重试过，自动重启引擎
                if silentFrames > 30 && self.micRetryCount < 2 {
                    silentFrames = 0
                    self.micRetryCount += 1
                    DispatchQueue.main.async {
                        self.log("检测到静音，重启麦克风引擎 (第\(self.micRetryCount)次)...")
                        self.launchMicEngine()
                    }
                    return
                }
            } else {
                silentFrames = 0
            }

            DispatchQueue.main.async {
                self.micLevel = normalized
                if normalized > self.micPeak {
                    self.micPeak = normalized
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
            isMicMonitoring = true
            log("麦克风监测中...")

            // Peak 衰减定时器
            peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.micPeak = max(self.micPeak - 0.1, 0)
            }
        } catch {
            log("麦克风启动失败: \(error.localizedDescription)", isError: true)
        }
    }

    func stopMicMonitor() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isMicMonitoring = false
        peakDecayTimer?.invalidate()
        peakDecayTimer = nil
        micLevel = 0
        micPeak = 0
        log("麦克风监测已停止")
    }
}

// MARK: - SymbolEffect 兼容性扩展

extension View {
    @ViewBuilder
    func safeSymbolEffectPulse(isActive: Bool) -> some View {
        if #available(macOS 14, *) {
            self.symbolEffect(.pulse, isActive: isActive)
        } else {
            self
        }
    }
}

// MARK: - 设计系统

enum DS {
    static let cardBg = Color(NSColor.controlBackgroundColor)
    static let surfaceBg = Color(NSColor.windowBackgroundColor)
    static let subtleBorder = Color.primary.opacity(0.06)
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
}

// MARK: - 电量条组件

struct BatteryRing: View {
    let label: String
    let percent: Int
    let icon: String

    private var color: Color {
        if percent > 50 { return .green }
        if percent > 20 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // 背景圆环
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 4)
                    .frame(width: 38, height: 38)
                // 电量圆环
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100.0)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(-90))
                // 百分比
                Text("\(percent)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 状态行组件

struct DiagRow: View {
    let icon: String
    let label: String
    let value: String
    let status: RowStatus

    enum RowStatus { case ok, warn, neutral }

    private var statusColor: Color {
        switch status {
        case .ok: return .green
        case .warn: return .red
        case .neutral: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject var engine = DiagnosticEngine()
    @State private var showLog = false

    private func selectedDeviceTitle(_ device: AirPodsDevice) -> String {
        engine.allDevices.count > 1 ? device.pickerLabel : device.name
    }

    var body: some View {
        VStack(spacing: DS.sectionSpacing) {
            headerSection
            if let dev = engine.device {
                deviceSection(dev)
                diagnosisSection(dev)
                audioTestSection
                if engine.isFixing || engine.fixDone {
                    fixProgressSection
                }
                actionsSection
            } else if !engine.isScanning {
                emptySection
            }
            if showLog || !engine.logs.isEmpty {
                logSection
            }
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.surfaceBg)
    }

    // MARK: 头部

    var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "airpodspro")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("AirPods Fix")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.bluetoothOn ? Color.blue : Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(engine.bluetoothOn ? "蓝牙已连接" : "蓝牙未连接")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if engine.isScanning || engine.isFixing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }
            Button(action: { engine.scan() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(engine.isScanning || engine.isFixing)
        }
    }

    // MARK: 设备信息

    func deviceSection(_ dev: AirPodsDevice) -> some View {
        VStack(spacing: 8) {
            // 设备名 + 状态
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDeviceTitle(dev))
                        .font(.system(size: 13, weight: .semibold))
                    Text(engine.diagnosis.modeLabel)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.diagnosis.hasIssue ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                    Text(engine.diagnosis.hasIssue ? "异常" : "正常")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((engine.diagnosis.hasIssue ? Color.red : Color.green).opacity(0.1))
                .clipShape(Capsule())
            }

            if engine.allDevices.count > 1 {
                HStack(spacing: 10) {
                    Text("目标设备")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker(
                        "目标设备",
                        selection: Binding(
                            get: { engine.device?.id ?? "" },
                            set: { engine.selectDevice(withID: $0) }
                        )
                    ) {
                        ForEach(engine.allDevices) { candidate in
                            Text(candidate.pickerLabel).tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(engine.isScanning || engine.isFixing)
                }

                Divider().opacity(0.5)
            }

            // 电量圆环 - 横排
            HStack(spacing: 20) {
                BatteryRing(label: "左耳", percent: Int(dev.batteryLeft.replacingOccurrences(of: "%", with: "")) ?? 0, icon: "ear")
                BatteryRing(label: "右耳", percent: Int(dev.batteryRight.replacingOccurrences(of: "%", with: "")) ?? 0, icon: "ear")
                if dev.batteryCase != "-", let pct = Int(dev.batteryCase.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: "充电盒", percent: pct, icon: "case")
                }
            }
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
    }

    // MARK: 诊断

    func diagnosisSection(_ dev: AirPodsDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("诊断")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            DiagRow(
                icon: engine.diagnosis.isDefaultOutput ? "checkmark.circle.fill" : "xmark.circle.fill",
                label: "输出设备",
                value: engine.diagnosis.isDefaultOutput ? selectedDeviceTitle(dev) : "非 \(selectedDeviceTitle(dev))",
                status: engine.diagnosis.isDefaultOutput ? .ok : .warn
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: "waveform",
                label: "音频模式",
                value: engine.diagnosis.modeLabel,
                status: engine.diagnosis.sampleRateHz == nil || engine.diagnosis.channelCount == nil
                    ? .neutral
                    : (engine.diagnosis.isReducedQualityMode ? .warn : .ok)
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: engine.diagnosis.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: "静音",
                value: engine.diagnosis.isMuted ? "已静音" : "关闭",
                status: engine.diagnosis.isMuted ? .warn : .ok
            )
            Divider().opacity(0.5)

            let vol = Int(engine.diagnosis.volume) ?? 0
            DiagRow(
                icon: "speaker.wave.1.fill",
                label: "音量",
                value: "\(engine.diagnosis.volume)%",
                status: vol < 5 ? .warn : .ok
            )
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
    }

    // MARK: 音频测试

    var audioTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音频测试")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            // 播放测试
            HStack(spacing: 10) {
                Image(systemName: engine.isPlayingTest ? "speaker.wave.3.fill" : "speaker.wave.2")
                    .font(.system(size: 14))
                    .foregroundColor(engine.isPlayingTest ? .accentColor : .secondary)
                    .frame(width: 20)
                    .safeSymbolEffectPulse(isActive: engine.isPlayingTest)
                Text("扬声器测试")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { engine.playTestSound() }) {
                    Text(engine.isPlayingTest ? "播放中..." : "播放")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(engine.isPlayingTest ? 0.1 : 0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(engine.isPlayingTest)
            }

            Divider().opacity(0.5)

            // 麦克风测试
            HStack(spacing: 10) {
                Image(systemName: engine.isMicMonitoring ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundColor(engine.isMicMonitoring ? .red : .secondary)
                    .frame(width: 20)
                Text("麦克风测试")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    if engine.isMicMonitoring {
                        engine.stopMicMonitor()
                    } else {
                        engine.startMicMonitor()
                    }
                }) {
                    Text(engine.isMicMonitoring ? "停止" : "开始")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(engine.isMicMonitoring ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                        .foregroundColor(engine.isMicMonitoring ? .red : .accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // 麦克风电平条
            if engine.isMicMonitoring {
                VStack(spacing: 6) {
                    // 电平条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // 背景刻度
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))

                            // 电平
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: levelGradient(for: engine.micLevel),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * CGFloat(engine.micLevel)))
                                .animation(.easeOut(duration: 0.08), value: engine.micLevel)

                            // Peak 标记
                            if engine.micPeak > 0.01 {
                                Rectangle()
                                    .fill(Color.red.opacity(0.6))
                                    .frame(width: 2)
                                    .offset(x: max(0, geo.size.width * CGFloat(engine.micPeak) - 1))
                                    .animation(.easeOut(duration: 0.15), value: engine.micPeak)
                            }
                        }
                    }
                    .frame(height: 14)

                    // 标签
                    HStack {
                        Text("安静")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                        Spacer()
                        Text(micLevelText(engine.micLevel))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(micLevelColor(engine.micLevel))
                        Spacer()
                        Text("响亮")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: engine.isMicMonitoring)
    }

    private func levelGradient(for level: Float) -> [Color] {
        if level < 0.4 { return [.green.opacity(0.7), .green] }
        if level < 0.7 { return [.green, .yellow, .orange] }
        return [.green, .yellow, .orange, .red]
    }

    private func micLevelText(_ level: Float) -> String {
        if level < 0.05 { return "无信号" }
        if level < 0.2 { return "微弱" }
        if level < 0.4 { return "正常" }
        if level < 0.7 { return "较响" }
        return "很响"
    }

    private func micLevelColor(_ level: Float) -> Color {
        if level < 0.05 { return .secondary }
        if level < 0.4 { return .green }
        if level < 0.7 { return .orange }
        return .red
    }

    // MARK: 修复进度

    var fixProgressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 步骤文字
            HStack(spacing: 8) {
                if engine.fixDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
                Text(engine.fixStepText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(engine.fixDone ? .green : .primary)
                Spacer()
                Text("\(Int(engine.fixProgress * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            engine.fixDone
                                ? Color.green
                                : Color.accentColor
                        )
                        .frame(width: geo.size.width * engine.fixProgress)
                        .animation(.easeInOut(duration: 0.3), value: engine.fixProgress)
                }
            }
            .frame(height: 6)
        }
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.25), value: engine.isFixing)
    }

    // MARK: 操作按钮

    var actionsSection: some View {
        VStack(spacing: 10) {
            Text("都设置好了就是不出声音？修复一下")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            ActionButton(
                title: engine.isFixing ? "修复中..." : "一键修复 AirPods",
                subtitle: "依次尝试：刷新音频路由 → 重启音频服务 → 重连蓝牙",
                icon: "arrow.clockwise.circle",
                style: .primary,
                action: { engine.runSmartRepair() }
            )
            .disabled(engine.isScanning || engine.isFixing)
        }
    }

    // MARK: 空状态

    var emptySection: some View {
        VStack(spacing: 14) {
            Image(systemName: "airpodspro")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text(engine.bluetoothOn ? "未找到 AirPods" : "蓝牙未开启")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("确保 AirPods 已取出并靠近 Mac")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(DS.cardPadding)
        .background(DS.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(DS.subtleBorder, lineWidth: 1)
        )
    }

    // MARK: 日志

    var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showLog ? 90 : 0))
                        .foregroundColor(.secondary)
                    Text("日志")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(engine.logs.count)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .buttonStyle(.plain)

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(engine.logs) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.time)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.5))
                                    Text(entry.message)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(entry.isError ? .red : .primary.opacity(0.7))
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 120)
                    .background(Color.black.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: engine.logs.count) {
                        if let last = engine.logs.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 操作按钮组件

struct ActionButton: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let style: ButtonType
    let action: () -> Void
    @State private var isHovered = false

    enum ButtonType { case primary, secondary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundColor(style == .primary ? .white.opacity(0.7) : .secondary)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: style == .secondary ? 1 : 0)
            )
            .shadow(color: style == .primary ? Color.accentColor.opacity(isHovered ? 0.3 : 0.15) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.9 : 1.0))
        case .secondary:
            return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.06 : 0.03))
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        }
    }

    private var borderColor: Color {
        style == .secondary ? DS.subtleBorder : .clear
    }
}

// MARK: - App Entry

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var sizeObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostingView = NSHostingView(rootView: ContentView())

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AirPods Fix"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor

        // 初始大小适配内容
        let fitting = hostingView.fittingSize
        window.setContentSize(NSSize(width: 380, height: fitting.height))
        window.center()
        window.makeKeyAndOrderFront(nil)

        // 监听内容大小变化，自动调整窗口高度
        sizeObserver = hostingView.observe(\.intrinsicContentSize, options: [.new]) { [weak self] view, _ in
            guard let self = self, let window = self.window else { return }
            let newSize = view.fittingSize
            // 保持窗口顶部不动，向下/上调整
            var frame = window.frame
            let delta = newSize.height - frame.size.height + (frame.size.height - (window.contentView?.frame.height ?? frame.size.height))
            frame.origin.y -= delta
            frame.size.height += delta
            frame.size.width = 380
            window.setFrame(frame, display: true, animate: true)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

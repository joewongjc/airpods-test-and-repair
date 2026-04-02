import Cocoa
import SwiftUI
import AVFoundation
import CoreAudio

// MARK: - 数据模型

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        }
    }

    var shortLabel: String {
        switch self {
        case .english: return "EN"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        }
    }
}

func localized(_ language: AppLanguage, en: String, zh: String, ja: String) -> String {
    switch language {
    case .english: return en
    case .chinese: return zh
    case .japanese: return ja
    }
}

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

    func modeLabel(in language: AppLanguage) -> String {
        guard let ch = channelCount, let sr = sampleRateHz else {
            return localized(language, en: "Unknown", zh: "未知", ja: "不明")
        }
        if ch >= 2 && sr >= 44100 {
            return localized(
                language,
                en: "Stereo \(sr/1000)kHz",
                zh: "立体声 \(sr/1000)kHz",
                ja: "ステレオ \(sr/1000)kHz"
            )
        }
        if ch == 1 && sr == 24000 {
            return localized(
                language,
                en: "Mono 24kHz",
                zh: "单声道 24kHz",
                ja: "モノラル 24kHz"
            )
        }
        if ch == 1 && (sr == 8000 || sr == 16000) {
            return localized(
                language,
                en: "Call mode \(sr/1000)kHz",
                zh: "通话模式 \(sr/1000)kHz",
                ja: "通話モード \(sr/1000)kHz"
            )
        }
        return localized(
            language,
            en: "\(ch == 1 ? "Mono" : "Stereo") \(sr/1000)kHz",
            zh: "\(ch == 1 ? "单声道" : "立体声") \(sr/1000)kHz",
            ja: "\(ch == 1 ? "モノラル" : "ステレオ") \(sr/1000)kHz"
        )
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
    audioOutputMatchScore(
        for: candidate,
        targetName: target.name,
        targetMACAddress: target.macAddress
    )
}

func audioOutputMatchScore(
    for candidate: AudioOutputDevice,
    targetName: String,
    targetMACAddress: String
) -> Int {
    let normalizedTargetName = normalizeAudioDeviceName(targetName)
    let normalizedTargetMAC = normalizeHardwareIdentifier(targetMACAddress)
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

func bestMatchingAudioOutput(
    forBluetoothName name: String,
    macAddress: String,
    among outputs: [AudioOutputDevice]
) -> (device: AudioOutputDevice, score: Int)? {
    outputs
        .compactMap { candidate -> (AudioOutputDevice, Int)? in
            let score = audioOutputMatchScore(
                for: candidate,
                targetName: name,
                targetMACAddress: macAddress
            )
            return score > 0 ? (candidate, score) : nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.isBluetoothTransport && !rhs.0.isBluetoothTransport
        }
        .first
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
        if let defaultOutputID = defaultOutputDeviceID(),
           let selected = topMatches.first(where: { $0.id == defaultOutputID }) {
            return .matched(selected)
        }
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
    private static let languageDefaultsKey = "selectedLanguage"

    @Published var device: AirPodsDevice?
    @Published var diagnosis = AudioDiagnosis()
    @Published var logs: [LogEntry] = []
    @Published var isScanning = false
    @Published var isFixing = false
    @Published var bluetoothOn = true
    @Published var allDevices: [AirPodsDevice] = []
    @Published var language = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: DiagnosticEngine.languageDefaultsKey) ?? ""
    ) ?? .english
    private var hasLoggedMissingBlueutil = false
    private var audioDeviceChangeObserverInstalled = false
    private var activationObserver: Any?
    private var lastAutoScanTime: Date = .distantPast

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let message: String
        let isError: Bool
    }

    private struct OutputSafetyState {
        var volume: Int
        var isMuted: Bool
    }

    init() {
        scan()
        installAutoRefresh()
    }

    private func installAutoRefresh() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.autoScanIfNeeded()
        }
        installAudioDeviceChangeListener()
    }

    private func autoScanIfNeeded() {
        guard !isScanning, !isFixing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutoScanTime) > 3 else { return }
        lastAutoScanTime = now
        scan()
    }

    private func installAudioDeviceChangeListener() {
        guard !audioDeviceChangeObserverInstalled else { return }
        audioDeviceChangeObserverInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.autoScanIfNeeded()
        }
    }

    deinit {
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func log(_ msg: String, isError: Bool = false) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let entry = LogEntry(time: fmt.string(from: Date()), message: msg, isError: isError)
        DispatchQueue.main.async { self.logs.append(entry) }
    }

    private func selectedDeviceLabel(for device: AirPodsDevice) -> String {
        allDevices.count > 1 ? device.pickerLabel : device.name
    }

    private func lt(en: String, zh: String, ja: String) -> String {
        localized(language, en: en, zh: zh, ja: ja)
    }

    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        UserDefaults.standard.set(language.rawValue, forKey: DiagnosticEngine.languageDefaultsKey)
        DispatchQueue.main.async {
            self.language = language
        }
    }

    private func blueutilGuidance() -> String {
        lt(
            en: "blueutil not found; use the prebuilt release, or install blueutil first (`brew install blueutil`)",
            zh: "未找到 blueutil；请使用预编译发布版，或先安装 blueutil（brew install blueutil）",
            ja: "blueutil が見つかりません。配布版を使うか、先に blueutil をインストールしてください（`brew install blueutil`）"
        )
    }

    private func noteMissingBlueutilIfNeeded() {
        guard !hasLoggedMissingBlueutil else { return }
        hasLoggedMissingBlueutil = true
        log(
            lt(
                en: "Bluetooth reconnect is limited. \(blueutilGuidance())",
                zh: "蓝牙重连功能受限，\(blueutilGuidance())",
                ja: "Bluetooth 再接続は制限されています。\(blueutilGuidance())"
            )
        )
    }

    private func ensureBlueutilAvailable(for feature: String) -> Bool {
        guard resolvedToolURL(named: "blueutil") != nil else {
            log(
                lt(
                    en: "\(feature) requires blueutil. \(blueutilGuidance())",
                    zh: "\(feature) 需要 blueutil，\(blueutilGuidance())",
                    ja: "\(feature) には blueutil が必要です。\(blueutilGuidance())"
                ),
                isError: true
            )
            return false
        }
        return true
    }

    private func commandFailureSuffix(_ result: ShellCommandResult) -> String {
        let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return localized(
                language,
                en: " (exit code \(result.status))",
                zh: "（退出码 \(result.status)）",
                ja: "（終了コード \(result.status)）"
            )
        }
        return localized(
            language,
            en: ": \(trimmedOutput)",
            zh: "：\(trimmedOutput)",
            ja: "：\(trimmedOutput)"
        )
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

    private func currentOutputSafetyState() -> OutputSafetyState? {
        let volumeResult = runShell("osascript -e 'output volume of (get volume settings)'")
        guard volumeResult.succeeded else {
            log(
                lt(
                    en: "Failed to read system volume\(commandFailureSuffix(volumeResult))",
                    zh: "读取系统音量失败\(commandFailureSuffix(volumeResult))",
                    ja: "システム音量の読み取りに失敗しました\(commandFailureSuffix(volumeResult))"
                ),
                isError: true
            )
            return nil
        }

        let mutedResult = runShell("osascript -e 'output muted of (get volume settings)'")
        guard mutedResult.succeeded else {
            log(
                lt(
                    en: "Failed to read mute state\(commandFailureSuffix(mutedResult))",
                    zh: "读取静音状态失败\(commandFailureSuffix(mutedResult))",
                    ja: "ミュート状態の読み取りに失敗しました\(commandFailureSuffix(mutedResult))"
                ),
                isError: true
            )
            return nil
        }

        guard let volume = Int(volumeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            log(
                lt(
                    en: "Could not parse the current system volume: \(volumeResult.output)",
                    zh: "无法解析当前系统音量：\(volumeResult.output)",
                    ja: "現在のシステム音量を解析できませんでした: \(volumeResult.output)"
                ),
                isError: true
            )
            return nil
        }

        return OutputSafetyState(
            volume: min(max(volume, 0), 100),
            isMuted: mutedResult.output == "true"
        )
    }

    @discardableResult
    private func setSystemOutputMuted(_ muted: Bool, failureMessage: String) -> Bool {
        let command = muted
            ? "osascript -e 'set volume with output muted'"
            : "osascript -e 'set volume without output muted'"
        return runCommand(command, failureMessage: failureMessage)
    }

    @discardableResult
    private func setSystemOutputVolume(_ volume: Int, failureMessage: String) -> Bool {
        let clampedVolume = min(max(volume, 0), 100)
        return runCommand(
            "osascript -e 'set volume output volume \(clampedVolume)'",
            failureMessage: failureMessage
        )
    }

    private func reinforceQuietOutputProtection() {
        _ = setSystemOutputMuted(
            true,
            failureMessage: lt(
                en: "Failed to enable protective mute",
                zh: "进入保护静音失败",
                ja: "保護ミュートの有効化に失敗しました"
            )
        )
    }

    private func applyCorrectiveOutputAdjustments(
        to state: inout OutputSafetyState,
        basedOn diagnosis: AudioDiagnosis
    ) {
        if diagnosis.isMuted {
            state.isMuted = false
        }
        if let volume = diagnosis.volumePercent, volume < 10 {
            state.volume = max(state.volume, 50)
        }
    }

    private func restoreOutputSafetyState(_ state: OutputSafetyState) {
        _ = setSystemOutputVolume(
            state.volume,
            failureMessage: lt(
                en: "Failed to restore system volume",
                zh: "恢复系统音量失败",
                ja: "システム音量の復元に失敗しました"
            )
        )
        _ = setSystemOutputMuted(
            state.isMuted,
            failureMessage: lt(
                en: "Failed to restore mute state",
                zh: "恢复静音状态失败",
                ja: "ミュート状態の復元に失敗しました"
            )
        )
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
        log(
            lt(
                en: "Failed to restart the audio service\(commandFailureSuffix(preferredFailure))",
                zh: "无法重启音频服务\(commandFailureSuffix(preferredFailure))",
                ja: "音声サービスを再起動できませんでした\(commandFailureSuffix(preferredFailure))"
            ),
            isError: true
        )
        return false
    }

    func selectDevice(withID id: String) {
        guard let selected = allDevices.first(where: { $0.id == id }) else { return }
        guard device?.id != selected.id else { return }
        DispatchQueue.main.async { self.device = selected }
        log(
            lt(
                en: "Switched target device: \(selectedDeviceLabel(for: selected))",
                zh: "切换目标设备: \(selectedDeviceLabel(for: selected))",
                ja: "対象デバイスを切り替えました: \(selectedDeviceLabel(for: selected))"
            )
        )
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            diagnoseAudio(for: selected)
        }
    }

    func scan() {
        isScanning = true
        logs.removeAll()
        log(lt(en: "Starting scan...", zh: "开始扫描...", ja: "スキャンを開始します..."))

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let previousDeviceID = device?.id
            let btPower = runBlueutil(["--power"])
            let btSysProf = runShell("system_profiler SPBluetoothDataType | head -5")
            if btPower.status == 127 {
                noteMissingBlueutilIfNeeded()
            }
            let hasBTOn = btPower.succeeded && btPower.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                || btSysProf.output.contains("State: On")
            log(
                lt(
                    en: "Bluetooth: \(hasBTOn ? "On" : "Off")",
                    zh: "蓝牙: \(hasBTOn ? "已开启" : "未开启")",
                    ja: "Bluetooth: \(hasBTOn ? "オン" : "オフ")"
                )
            )
            DispatchQueue.main.async { self.bluetoothOn = hasBTOn }
            if !hasBTOn {
                log(lt(en: "Bluetooth is off", zh: "蓝牙未开启", ja: "Bluetooth がオフです"), isError: true)
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            let btInfoResult = runShell("system_profiler SPBluetoothDataType")
            guard btInfoResult.succeeded else {
                log(
                    lt(
                        en: "Failed to read Bluetooth device info\(commandFailureSuffix(btInfoResult))",
                        zh: "读取蓝牙设备信息失败\(commandFailureSuffix(btInfoResult))",
                        ja: "Bluetooth デバイス情報の読み取りに失敗しました\(commandFailureSuffix(btInfoResult))"
                    ),
                    isError: true
                )
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            let audioOutputs = listAudioOutputDevices()
            struct BluetoothScanCandidate {
                let device: AirPodsDevice
                let matchedOutput: AudioOutputDevice?
                let score: Int
            }

            let allBlocks = bluetoothDeviceBlocks(from: btInfoResult.output)
            var bestCandidateByOutputID: [AudioDeviceID: BluetoothScanCandidate] = [:]
            var unmatchedCandidates: [String: BluetoothScanCandidate] = [:]
            for block in allBlocks {
                var battL = "-", battR = "-", battC = "-", mac = ""
                var genericBattery: String?
                for line in block.lines {
                    if line.starts(with: "Left Battery Level:") { battL = line.components(separatedBy: ": ").last ?? "-" }
                    else if line.starts(with: "Right Battery Level:") { battR = line.components(separatedBy: ": ").last ?? "-" }
                    else if line.starts(with: "Case Battery Level:") { battC = line.components(separatedBy: ": ").last ?? "-" }
                    else if line.starts(with: "Battery Level:") { genericBattery = line.components(separatedBy: ": ").last }
                    if line.starts(with: "Address:") { mac = line.components(separatedBy: ": ").last ?? "" }
                }
                if battL == "-" && battR == "-", let gb = genericBattery {
                    battL = gb; battR = gb
                }

                guard battL != "-" || battR != "-" else { continue }

                let newDevice = AirPodsDevice(
                    name: block.name,
                    batteryLeft: battL,
                    batteryRight: battR,
                    batteryCase: battC,
                    macAddress: mac
                )

                if let bestMatch = bestMatchingAudioOutput(
                    forBluetoothName: block.name,
                    macAddress: mac,
                    among: audioOutputs
                ) {
                    let candidate = BluetoothScanCandidate(
                        device: newDevice,
                        matchedOutput: bestMatch.device,
                        score: bestMatch.score
                    )
                    if let existing = bestCandidateByOutputID[bestMatch.device.id] {
                        if candidate.score > existing.score {
                            bestCandidateByOutputID[bestMatch.device.id] = candidate
                        }
                    } else {
                        bestCandidateByOutputID[bestMatch.device.id] = candidate
                    }
                } else {
                    let likelyInCase = battC != "-"
                    if !likelyInCase {
                        let candidate = BluetoothScanCandidate(
                            device: newDevice,
                            matchedOutput: nil,
                            score: 0
                        )
                        unmatchedCandidates[newDevice.id] = candidate
                    }
                }
            }

            let matchedIDs = Set(bestCandidateByOutputID.values.map(\.device.id))
            let allCandidates = bestCandidateByOutputID.values.map(\.device)
                + unmatchedCandidates.values
                    .filter { !matchedIDs.contains($0.device.id) }
                    .map(\.device)

            let devices = allCandidates
                .sorted { lhs, rhs in
                    if lhs.name != rhs.name {
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.id < rhs.id
                }

            let selectedDevice = devices.first(where: { $0.id == previousDeviceID }) ?? devices.first
            DispatchQueue.main.async {
                self.allDevices = devices
                self.device = selectedDevice
            }

            if devices.isEmpty {
                self.log(
                    lt(
                        en: "No connected headset was found",
                        zh: "未找到已连接的蓝牙耳机",
                        ja: "接続中のヘッドセットが見つかりません"
                    ),
                    isError: true
                )
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            if devices.count > 1 {
                self.log(
                    lt(
                        en: "Detected \(devices.count) compatible headsets. You can switch the target device in the device card.",
                        zh: "检测到 \(devices.count) 台可修复的蓝牙耳机，可在设备卡片中切换目标设备",
                        ja: "対応ヘッドセットを \(devices.count) 台検出しました。デバイスカードで対象を切り替えられます。"
                    )
                )
            }

            guard let selectedDevice else {
                self.log(
                    lt(
                        en: "No usable target device was found",
                        zh: "未找到可用的目标设备",
                        ja: "使用可能な対象デバイスが見つかりません"
                    ),
                    isError: true
                )
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            self.log(
                lt(
                    en: "Connected: \(self.selectedDeviceLabel(for: selectedDevice))",
                    zh: "已连接: \(self.selectedDeviceLabel(for: selectedDevice))",
                    ja: "接続済み: \(self.selectedDeviceLabel(for: selectedDevice))"
                )
            )
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
            log(
                lt(
                    en: "Multiple audio outputs match \(selectedDeviceLabel(for: device)). Select the target in System Settings first.",
                    zh: "检测到多个与 \(selectedDeviceLabel(for: device)) 匹配的音频输出，请先在系统声音设置里选中目标设备",
                    ja: "\(selectedDeviceLabel(for: device)) に一致する音声出力が複数あります。先にシステム設定で対象を選んでください。"
                ),
                isError: true
            )
        case .notFound:
            log(
                lt(
                    en: "Could not find \(selectedDeviceLabel(for: device)) in the audio output list",
                    zh: "未在音频输出列表中找到 \(selectedDeviceLabel(for: device))",
                    ja: "音声出力一覧に \(selectedDeviceLabel(for: device)) が見つかりません"
                ),
                isError: true
            )
        }

        let volumeResult = runShell("osascript -e 'output volume of (get volume settings)'")
        if volumeResult.succeeded {
            diag.volume = volumeResult.output
        } else {
            log(
                lt(
                    en: "Failed to read system volume\(commandFailureSuffix(volumeResult))",
                    zh: "读取系统音量失败\(commandFailureSuffix(volumeResult))",
                    ja: "システム音量の読み取りに失敗しました\(commandFailureSuffix(volumeResult))"
                ),
                isError: true
            )
        }

        let mutedResult = runShell("osascript -e 'output muted of (get volume settings)'")
        if mutedResult.succeeded {
            diag.isMuted = mutedResult.output == "true"
        } else {
            log(
                lt(
                    en: "Failed to read mute state\(commandFailureSuffix(mutedResult))",
                    zh: "读取静音状态失败\(commandFailureSuffix(mutedResult))",
                    ja: "ミュート状態の読み取りに失敗しました\(commandFailureSuffix(mutedResult))"
                ),
                isError: true
            )
        }

        let modeLabel = diag.modeLabel(in: language)
        log(
            lt(
                en: "Mode: \(modeLabel) | Volume: \(diag.volume)%\(diag.isMuted ? " (muted)" : "")",
                zh: "模式: \(modeLabel) | 音量: \(diag.volume)%\(diag.isMuted ? " (静音)" : "")",
                ja: "モード: \(modeLabel) | 音量: \(diag.volume)%\(diag.isMuted ? " (ミュート)" : "")"
            )
        )
        if !diag.isDefaultOutput {
            log(
                lt(
                    en: "\(selectedDeviceLabel(for: device)) is not the current output device",
                    zh: "\(selectedDeviceLabel(for: device)) 非当前输出设备",
                    ja: "\(selectedDeviceLabel(for: device)) は現在の出力デバイスではありません"
                ),
                isError: true
            )
        }
        if diag.isMuted {
            log(lt(en: "System output is muted", zh: "系统已静音", ja: "システム出力はミュートです"), isError: true)
        }
        if diag.isDefaultOutput, diag.isReducedQualityMode {
            log(
                lt(
                    en: "Current output mode is degraded: \(modeLabel)",
                    zh: "当前输出模式异常：\(modeLabel)",
                    ja: "現在の出力モードが劣化しています: \(modeLabel)"
                ),
                isError: true
            )
        }
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

    private func logOutputResolutionFailure(for device: AirPodsDevice, match: AudioOutputMatch) {
        switch match {
        case .matched:
            log(
                lt(
                    en: "The headset became available, but macOS still did not switch the output route",
                    zh: "耳机输出已经出现，但 macOS 仍未切换音频路由",
                    ja: "ヘッドセット出力は利用可能になりましたが、macOS が音声ルートを切り替えませんでした"
                ),
                isError: true
            )
        case .ambiguous:
            log(
                lt(
                    en: "Multiple audio outputs match \(selectedDeviceLabel(for: device)). Select it in System Settings first.",
                    zh: "检测到多个与 \(selectedDeviceLabel(for: device)) 匹配的音频输出，请先在系统声音设置里选中目标设备",
                    ja: "\(selectedDeviceLabel(for: device)) に一致する音声出力が複数あります。先にシステム設定で対象を選んでください。"
                ),
                isError: true
            )
        case .notFound:
            log(
                lt(
                    en: "No audio output was found for \(selectedDeviceLabel(for: device))",
                    zh: "未找到 \(selectedDeviceLabel(for: device)) 的音频输出",
                    ja: "\(selectedDeviceLabel(for: device)) の音声出力が見つかりません"
                ),
                isError: true
            )
        }
    }

    private func waitForResolvedOutput(for device: AirPodsDevice, timeout: TimeInterval) -> AudioOutputMatch {
        let deadline = Date().addingTimeInterval(timeout)
        var lastMatch = matchAudioOutputDevice(for: device)
        while Date() < deadline {
            if case .matched = lastMatch {
                return lastMatch
            }
            Thread.sleep(forTimeInterval: 0.35)
            lastMatch = matchAudioOutputDevice(for: device)
        }
        return lastMatch
    }

    @discardableResult
    private func askBluetoothToClaimDevice(for device: AirPodsDevice) -> Bool {
        guard resolvedToolURL(named: "blueutil") != nil else {
            noteMissingBlueutilIfNeeded()
            return false
        }
        guard let safeMac = sanitizedBluetoothAddress(for: device) else {
            return false
        }

        log(
            lt(
                en: "The headset is not active on this Mac yet. Requesting Bluetooth handoff...",
                zh: "目标耳机还没有切到这台 Mac，尝试请求蓝牙切换...",
                ja: "ヘッドセットはまだこの Mac で有効ではありません。Bluetooth の切り替えを要求しています..."
            )
        )

        let connectResult = runBlueutil(["--connect", safeMac])
        guard connectResult.succeeded else {
            let isPermissionError = connectResult.output.contains("absence of access") || connectResult.status == 134
            if isPermissionError {
                log(
                    lt(
                        en: "Bluetooth access denied. Grant permission in System Settings → Privacy & Security → Bluetooth for AirPods Fix, then retry.",
                        zh: "蓝牙权限被拒绝，请在「系统设置 → 隐私与安全性 → 蓝牙」中允许 AirPods Fix 访问蓝牙，然后重试",
                        ja: "Bluetooth アクセスが拒否されました。「システム設定 → プライバシーとセキュリティ → Bluetooth」で AirPods Fix にアクセスを許可してから再試行してください。"
                    ),
                    isError: true
                )
            } else {
                log(
                    lt(
                        en: "Failed to request Bluetooth handoff\(commandFailureSuffix(connectResult))",
                        zh: "请求蓝牙切换失败\(commandFailureSuffix(connectResult))",
                        ja: "Bluetooth の切り替え要求に失敗しました\(commandFailureSuffix(connectResult))"
                    ),
                    isError: true
                )
            }
            return false
        }

        log(
            lt(
                en: "Bluetooth handoff requested. Waiting for the headset output to appear...",
                zh: "已请求蓝牙切换，等待耳机输出出现在这台 Mac 上...",
                ja: "Bluetooth の切り替えを要求しました。ヘッドセット出力がこの Mac に現れるのを待っています..."
            )
        )
        return true
    }

    @discardableResult
    private func switchResolvedOutputToDefault(_ audioOutput: AudioOutputDevice) -> Bool {
        if defaultOutputDeviceID() == audioOutput.id {
            return true
        }
        guard switchOutputDevice(to: audioOutput) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.35)
        let verified = defaultOutputDeviceID() == audioOutput.id
        return verified
    }

    @discardableResult
    private func switchToSelectedAirPodsOutput(_ device: AirPodsDevice) -> Bool {
        let initialMatch = matchAudioOutputDevice(for: device)
        if case .matched(let audioOutput) = initialMatch,
           switchResolvedOutputToDefault(audioOutput) {
            return true
        }

        let shouldAttemptBluetoothHandoff: Bool
        switch initialMatch {
        case .matched(let audioOutput):
            shouldAttemptBluetoothHandoff = defaultOutputDeviceID() != audioOutput.id
        case .ambiguous, .notFound:
            shouldAttemptBluetoothHandoff = true
        }

        var finalMatch = initialMatch
        if shouldAttemptBluetoothHandoff && askBluetoothToClaimDevice(for: device) {
            finalMatch = waitForResolvedOutput(for: device, timeout: 4.0)
            if case .matched(let refreshedOutput) = finalMatch,
               switchResolvedOutputToDefault(refreshedOutput) {
                return true
            }
        }

        logOutputResolutionFailure(for: device, match: finalMatch)
        return false
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
        reinforceQuietOutputProtection()
        step(fallbackStep, progress: fallbackProgress)
        if let fallback = fallbackAudioOutputDevice(excluding: device.name) {
            reinforceQuietOutputProtection()
            if switchOutputDevice(to: fallback) {
                log(
                    lt(
                        en: "Switched to \(fallback.name)",
                        zh: "已切换到 \(fallback.name)",
                        ja: "\(fallback.name) に切り替えました"
                    )
                )
                Thread.sleep(forTimeInterval: 1.0)
            } else {
                log(
                    lt(
                        en: "Failed to switch to \(fallback.name). Will keep trying to reselect \(device.name).",
                        zh: "切换到 \(fallback.name) 失败，继续尝试重选 \(device.name)",
                        ja: "\(fallback.name) への切り替えに失敗しました。\(device.name) の再選択を続けます。"
                    ),
                    isError: true
                )
            }
        } else {
            log(
                lt(
                    en: "No fallback output was found. Reselecting \(device.name) directly.",
                    zh: "未找到可用的备用输出，直接重选 \(device.name)",
                    ja: "使える代替出力が見つからないため、\(device.name) を直接再選択します。"
                )
            )
        }

        step(targetStep, progress: targetProgress)
        reinforceQuietOutputProtection()
        let ok = switchToSelectedAirPodsOutput(device)
        if ok {
            log(
                lt(
                    en: "Switched to \(selectedDeviceLabel(for: device))",
                    zh: "已切换到 \(selectedDeviceLabel(for: device))",
                    ja: "\(selectedDeviceLabel(for: device)) に切り替えました"
                )
            )
        } else {
            log(
                lt(
                    en: "Failed to switch to \(selectedDeviceLabel(for: device))",
                    zh: "切换到 \(selectedDeviceLabel(for: device)) 失败",
                    ja: "\(selectedDeviceLabel(for: device)) への切り替えに失敗しました"
                ),
                isError: true
            )
        }

        step(settleStep, progress: settleProgress)
        reinforceQuietOutputProtection()
        Thread.sleep(forTimeInterval: 1.0)
        return ok
    }

    // 软修复: 修静音/音量/输出设备，不动 coreaudiod，不断蓝牙
    // 核心: 先切回本机扬声器，再切回 AirPods，强制刷新音频路由
    func fix() {
        guard let dev = device else { return }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let startingDiagnosis = self.diagnoseAudio(for: dev)
            let originalOutputState = currentOutputSafetyState()
            var desiredOutputState = originalOutputState
            if var state = desiredOutputState {
                applyCorrectiveOutputAdjustments(to: &state, basedOn: startingDiagnosis)
                desiredOutputState = state
            }
            defer {
                if let state = desiredOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(
                lt(en: "Protecting current output...", zh: "保护当前输出...", ja: "現在の出力を保護しています..."),
                progress: 0.05
            )
            reinforceQuietOutputProtection()
            let ok = refreshAudioRoute(
                for: dev,
                fallbackStep: lt(en: "Switching to fallback output...", zh: "切换到备用输出...", ja: "代替出力に切り替えています..."),
                fallbackProgress: 0.3,
                targetStep: lt(en: "Switching back to the target headset...", zh: "切换输出到目标耳机...", ja: "対象ヘッドセットへ戻しています..."),
                targetProgress: 0.6,
                settleStep: lt(en: "Waiting for the audio path to settle...", zh: "等待音频通道建立...", ja: "音声経路の確立を待っています..."),
                settleProgress: 0.75
            )

            if let state = desiredOutputState {
                step(
                    lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."),
                    progress: 0.85
                )
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Verifying result...", zh: "验证修复结果...", ja: "結果を確認しています..."), progress: 0.9)
            self.diagnoseAudio(for: dev)

            if ok {
                step(lt(en: "Audio route refreshed", zh: "音频路由已刷新", ja: "音声ルートを更新しました"), progress: 1.0)
            } else {
                step(
                    lt(
                        en: "Output switching failed. Try restarting audio or reconnecting Bluetooth.",
                        zh: "切换失败，试「重启音频」或「重连蓝牙」",
                        ja: "切り替えに失敗しました。音声サービス再起動または Bluetooth 再接続を試してください。"
                    ),
                    progress: 1.0
                )
            }
            endFix()
        }
    }

    // 中修复: 重启 coreaudiod
    func restartAudioService() {
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let originalOutputState = currentOutputSafetyState()
            defer {
                if let state = originalOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(lt(en: "Protecting current output...", zh: "保护当前输出...", ja: "現在の出力を保護しています..."), progress: 0.05)
            reinforceQuietOutputProtection()
            step(lt(en: "Stopping the audio service...", zh: "停止音频服务...", ja: "音声サービスを停止しています..."), progress: 0.15)
            reinforceQuietOutputProtection()
            guard restartCoreAudioService() else {
                step(lt(en: "Failed to restart the audio service", zh: "重启音频服务失败", ja: "音声サービスの再起動に失敗しました"), progress: 1.0)
                endFix()
                return
            }

            step(lt(en: "Waiting for the service to restart...", zh: "等待服务重启...", ja: "サービスの再起動を待っています..."), progress: 0.35)
            Thread.sleep(forTimeInterval: 1.5)
            step(lt(en: "Audio service is recovering...", zh: "音频服务恢复中...", ja: "音声サービスの復旧中..."), progress: 0.55)
            Thread.sleep(forTimeInterval: 1.5)

            step(lt(en: "Verifying audio state...", zh: "验证音频状态...", ja: "音声状態を確認しています..."), progress: 0.8)
            Thread.sleep(forTimeInterval: 0.5)
            if let state = originalOutputState {
                restoreOutputSafetyState(state)
            }
            if let dev = device {
                self.diagnoseAudio(for: dev)
            }

            step(lt(en: "Audio service restarted", zh: "音频服务已重启", ja: "音声サービスを再起動しました"), progress: 1.0)
            endFix()
        }
    }

    // 硬修复: 断开重连蓝牙
    func reconnectBluetooth() {
        guard ensureBlueutilAvailable(for: lt(en: "Bluetooth reconnect", zh: "蓝牙重连", ja: "Bluetooth 再接続")) else { return }
        guard let dev = device else {
            log(lt(en: "No repair target was found", zh: "未找到可修复的设备", ja: "修復対象のデバイスが見つかりません"), isError: true); return
        }
        guard let safeMac = sanitizedBluetoothAddress(for: dev) else {
            log(lt(en: "Bluetooth address is invalid or missing", zh: "蓝牙地址无效或缺失", ja: "Bluetooth アドレスが無効か不足しています"), isError: true); return
        }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let originalOutputState = currentOutputSafetyState()
            defer {
                if let state = originalOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(lt(en: "Protecting current output...", zh: "保护当前输出...", ja: "現在の出力を保護しています..."), progress: 0.05)
            reinforceQuietOutputProtection()
            step(lt(en: "Disconnecting the target headset...", zh: "断开目标耳机...", ja: "対象ヘッドセットを切断しています..."), progress: 0.1)
            reinforceQuietOutputProtection()
            let disconnectResult = runBlueutil(["--disconnect", safeMac])
            let disconnectSucceeded = disconnectResult.succeeded
            if !disconnectSucceeded {
                log(
                    lt(
                        en: "Failed to disconnect the Bluetooth device\(commandFailureSuffix(disconnectResult))",
                        zh: "断开蓝牙设备失败\(commandFailureSuffix(disconnectResult))",
                        ja: "Bluetooth デバイスの切断に失敗しました\(commandFailureSuffix(disconnectResult))"
                    ),
                    isError: true
                )
            }

            step(lt(en: "Waiting for disconnect...", zh: "等待断开完成...", ja: "切断完了を待っています..."), progress: 0.2)
            Thread.sleep(forTimeInterval: 1.5)
            step(lt(en: "Disconnected. Preparing to reconnect...", zh: "已断开，准备重连...", ja: "切断しました。再接続を準備しています..."), progress: 0.3)
            Thread.sleep(forTimeInterval: 1.5)

            step(lt(en: "Reconnecting the target headset...", zh: "重新连接目标耳机...", ja: "対象ヘッドセットを再接続しています..."), progress: 0.4)
            reinforceQuietOutputProtection()
            let reconnectResult = runBlueutil(["--connect", safeMac])
            guard reconnectResult.succeeded else {
                log(
                    lt(
                        en: "Failed to reconnect the Bluetooth device\(commandFailureSuffix(reconnectResult))",
                        zh: "重新连接蓝牙设备失败\(commandFailureSuffix(reconnectResult))",
                        ja: "Bluetooth デバイスの再接続に失敗しました\(commandFailureSuffix(reconnectResult))"
                    ),
                    isError: true
                )
                step(
                    disconnectSucceeded
                        ? lt(en: "Bluetooth reconnect failed", zh: "蓝牙重连失败", ja: "Bluetooth の再接続に失敗しました")
                        : lt(en: "Bluetooth disconnect/reconnect failed", zh: "蓝牙断开/重连失败", ja: "Bluetooth の切断/再接続に失敗しました"),
                    progress: 1.0
                )
                endFix()
                return
            }

            step(lt(en: "Waiting for Bluetooth handshake...", zh: "等待蓝牙握手...", ja: "Bluetooth ハンドシェイクを待っています..."), progress: 0.5)
            Thread.sleep(forTimeInterval: 2)
            step(lt(en: "Establishing audio path...", zh: "建立音频通道...", ja: "音声経路を確立しています..."), progress: 0.65)
            Thread.sleep(forTimeInterval: 2)
            step(lt(en: "Stabilizing connection...", zh: "连接稳定中...", ja: "接続を安定化しています..."), progress: 0.8)
            Thread.sleep(forTimeInterval: 1)

            step(lt(en: "Verifying connection...", zh: "验证连接状态...", ja: "接続状態を確認しています..."), progress: 0.9)
            if let state = originalOutputState {
                restoreOutputSafetyState(state)
            }
            self.diagnoseAudio(for: dev)

            step(lt(en: "Bluetooth reconnect finished", zh: "蓝牙重连完成", ja: "Bluetooth の再接続が完了しました"), progress: 1.0)
            endFix()
        }
    }

    // MARK: 智能一键修复（按强度递增依次尝试）
    func runSmartRepair() {
        guard let dev = device else { return }
        beginFix()
        DispatchQueue.global(qos: .userInitiated).async { [self] in

            // ===== 阶段 1: 软修复 (0% ~ 30%) =====
            step(lt(en: "Repair started: reading current audio state...", zh: "开始修复：读取当前音频状态...", ja: "修復開始: 現在の音声状態を読み取っています..."), progress: 0.03)
            let currentDiagnosis = self.diagnoseAudio(for: dev)
            let originalOutputState = currentOutputSafetyState()
            var desiredOutputState = originalOutputState
            if var state = desiredOutputState {
                applyCorrectiveOutputAdjustments(to: &state, basedOn: currentDiagnosis)
                desiredOutputState = state
            }
            defer {
                if let state = desiredOutputState {
                    restoreOutputSafetyState(state)
                }
            }

            step(lt(en: "Repair started: protecting current output...", zh: "开始修复：保护当前输出...", ja: "修復開始: 現在の出力を保護しています..."), progress: 0.05)
            reinforceQuietOutputProtection()
            _ = refreshAudioRoute(
                for: dev,
                fallbackStep: lt(en: "Refreshing the audio route...", zh: "刷新音频路由...", ja: "音声ルートを更新しています..."),
                fallbackProgress: 0.20,
                targetStep: lt(en: "Reselecting the target headset output...", zh: "重选目标耳机输出...", ja: "対象ヘッドセット出力を再選択しています..."),
                targetProgress: 0.24,
                settleStep: lt(en: "Waiting for the audio path to settle...", zh: "等待音频通道建立...", ja: "音声経路の確立を待っています..."),
                settleProgress: 0.28
            )

            if let state = desiredOutputState {
                step(lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."), progress: 0.29)
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Soft repair finished. Verifying state...", zh: "软修复完成，验证状态...", ja: "ソフト修復が完了しました。状態を確認しています..."), progress: 0.30)
            let softDiagnosis = self.diagnoseAudio(for: dev)

            if !softDiagnosis.hasIssue {
                step(lt(en: "Soft repair resolved the issue", zh: "软修复已解决问题", ja: "ソフト修復で問題が解決しました"), progress: 1.0)
                endFix()
                return
            }

            // ===== 阶段 2: 中修复 (30% ~ 60%) =====
            reinforceQuietOutputProtection()
            step(lt(en: "Soft repair was not enough. Restarting the audio service...", zh: "软修复未解决，重启音频服务...", ja: "ソフト修復では解決しませんでした。音声サービスを再起動しています..."), progress: 0.35)
            let audioRestarted = restartCoreAudioService()

            if audioRestarted {
                step(lt(en: "Waiting for the service to restart...", zh: "等待服务重启...", ja: "サービスの再起動を待っています..."), progress: 0.45)
                Thread.sleep(forTimeInterval: 1.5)
                step(lt(en: "Audio service is recovering...", zh: "音频服务恢复中...", ja: "音声サービスの復旧中..."), progress: 0.55)
                Thread.sleep(forTimeInterval: 1.5)
            } else {
                step(lt(en: "Could not restart the audio service. Will continue with Bluetooth reconnect...", zh: "无法重启音频服务，继续尝试蓝牙重连...", ja: "音声サービスを再起動できなかったため、Bluetooth 再接続を続けます..."), progress: 0.60)
            }

            if let state = desiredOutputState {
                step(lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."), progress: 0.59)
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Medium repair finished. Verifying state...", zh: "中修复完成，验证状态...", ja: "中程度の修復が完了しました。状態を確認しています..."), progress: 0.60)
            let mediumDiagnosis = self.diagnoseAudio(for: dev)

            if !mediumDiagnosis.hasIssue {
                step(lt(en: "Medium repair resolved the issue", zh: "中修复已解决问题", ja: "中程度の修復で問題が解決しました"), progress: 1.0)
                endFix()
                return
            }

            // ===== 阶段 3: 硬修复 (60% ~ 100%) =====
            guard ensureBlueutilAvailable(for: lt(en: "Bluetooth reconnect", zh: "蓝牙重连", ja: "Bluetooth 再接続")) else {
                step(lt(en: "blueutil is unavailable, so Bluetooth reconnect cannot run", zh: "未找到 blueutil，无法执行蓝牙重连", ja: "blueutil がないため Bluetooth 再接続を実行できません"), progress: 1.0)
                endFix()
                return
            }

            guard let safeMac = sanitizedBluetoothAddress(for: dev) else {
                step(lt(en: "Medium repair was not enough, but the Bluetooth address is unavailable", zh: "中修复未解决，但无法获取蓝牙地址", ja: "中程度の修復では解決しませんでしたが、Bluetooth アドレスを取得できません"), progress: 1.0)
                endFix()
                return
            }

            reinforceQuietOutputProtection()
            step(lt(en: "Medium repair was not enough. Disconnecting Bluetooth...", zh: "中修复未解决，断开蓝牙...", ja: "中程度の修復では解決しませんでした。Bluetooth を切断しています..."), progress: 0.65)
            let disconnectResult = runBlueutil(["--disconnect", safeMac])
            let disconnectSucceeded = disconnectResult.succeeded
            if !disconnectSucceeded {
                log(
                    lt(
                        en: "Failed to disconnect the Bluetooth device\(commandFailureSuffix(disconnectResult))",
                        zh: "断开蓝牙设备失败\(commandFailureSuffix(disconnectResult))",
                        ja: "Bluetooth デバイスの切断に失敗しました\(commandFailureSuffix(disconnectResult))"
                    ),
                    isError: true
                )
            }

            step(lt(en: "Waiting for Bluetooth disconnect...", zh: "等待蓝牙断开...", ja: "Bluetooth の切断を待っています..."), progress: 0.72)
            Thread.sleep(forTimeInterval: 1.5)
            step(lt(en: "Reconnecting the target headset...", zh: "重新连接目标耳机...", ja: "対象ヘッドセットを再接続しています..."), progress: 0.78)
            reinforceQuietOutputProtection()
            let reconnectResult = runBlueutil(["--connect", safeMac])
            guard reconnectResult.succeeded else {
                log(
                    lt(
                        en: "Failed to reconnect the Bluetooth device\(commandFailureSuffix(reconnectResult))",
                        zh: "重新连接蓝牙设备失败\(commandFailureSuffix(reconnectResult))",
                        ja: "Bluetooth デバイスの再接続に失敗しました\(commandFailureSuffix(reconnectResult))"
                    ),
                    isError: true
                )
                step(
                    disconnectSucceeded
                        ? lt(en: "Hard repair failed", zh: "硬修复执行失败", ja: "ハード修復に失敗しました")
                        : lt(en: "Hard repair could not complete the Bluetooth reconnect", zh: "硬修复未能完成蓝牙重连", ja: "ハード修復で Bluetooth 再接続を完了できませんでした"),
                    progress: 1.0
                )
                endFix()
                return
            }

            step(lt(en: "Waiting for Bluetooth handshake and audio path...", zh: "等待蓝牙握手与音频通道建立...", ja: "Bluetooth ハンドシェイクと音声経路の確立を待っています..."), progress: 0.88)
            Thread.sleep(forTimeInterval: 4.0)

            if let state = desiredOutputState {
                step(lt(en: "Restoring user output settings...", zh: "恢复用户音量设置...", ja: "ユーザーの出力設定を復元しています..."), progress: 0.93)
                restoreOutputSafetyState(state)
            }
            step(lt(en: "Hard repair finished. Verifying state...", zh: "硬修复完成，验证状态...", ja: "ハード修復が完了しました。状態を確認しています..."), progress: 0.95)
            let finalDiagnosis = self.diagnoseAudio(for: dev)

            if finalDiagnosis.hasIssue {
                step(lt(en: "All repair attempts finished, but the issue remains. Hardware should be checked next.", zh: "所有修复尝试完毕，仍有问题，建议检查硬件", ja: "すべての修復を試しましたが、まだ問題があります。次はハードウェアを確認してください。"), progress: 1.0)
            } else {
                step(lt(en: "Hard repair resolved the issue. The headset is back to normal.", zh: "硬修复已解决问题，目标耳机恢复正常", ja: "ハード修復で問題が解決しました。ヘッドセットは正常に戻りました。"), progress: 1.0)
            }
            endFix()
        }
    }

    // MARK: 播放测试音

    @Published var isPlayingTest = false

    func playTestSound() {
        isPlayingTest = true
        log(lt(en: "Playing test sound...", zh: "播放测试音...", ja: "テスト音を再生しています..."))
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
            log(lt(en: "Test sound finished", zh: "测试音播放完毕", ja: "テスト音の再生が完了しました"))
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

        log(lt(en: "Starting microphone monitor...", zh: "启动麦克风监测...", ja: "マイク監視を開始しています..."))

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)
        log(
            lt(
                en: "Microphone format: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch",
                zh: "麦克风格式: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch",
                ja: "マイク形式: \(Int(nativeFormat.sampleRate))Hz / \(nativeFormat.channelCount)ch"
            )
        )

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
                        self.log(
                            self.lt(
                                en: "Silence detected. Restarting microphone engine (attempt \(self.micRetryCount))...",
                                zh: "检测到静音，重启麦克风引擎 (第\(self.micRetryCount)次)...",
                                ja: "無音を検出しました。マイクエンジンを再起動します（\(self.micRetryCount)回目）..."
                            )
                        )
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
            log(lt(en: "Microphone monitor is running...", zh: "麦克风监测中...", ja: "マイク監視中..."))

            // Peak 衰减定时器
            peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.micPeak = max(self.micPeak - 0.1, 0)
            }
        } catch {
            log(
                lt(
                    en: "Failed to start microphone monitor: \(error.localizedDescription)",
                    zh: "麦克风启动失败: \(error.localizedDescription)",
                    ja: "マイク監視の開始に失敗しました: \(error.localizedDescription)"
                ),
                isError: true
            )
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
        log(lt(en: "Microphone monitor stopped", zh: "麦克风监测已停止", ja: "マイク監視を停止しました"))
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
        device.name
    }

    private func t(en: String, zh: String, ja: String) -> String {
        localized(engine.language, en: en, zh: zh, ja: ja)
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
                    Text(
                        engine.bluetoothOn
                            ? t(en: "Bluetooth Connected", zh: "蓝牙已连接", ja: "Bluetooth接続済み")
                            : t(en: "Bluetooth Disconnected", zh: "蓝牙未连接", ja: "Bluetooth未接続")
                    )
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
            Picker(
                "Language",
                selection: Binding(
                    get: { engine.language },
                    set: { engine.setLanguage($0) }
                )
            ) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.menuLabel).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 90)
            .disabled(engine.isScanning || engine.isFixing)
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
                    Text(engine.diagnosis.modeLabel(in: engine.language))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.diagnosis.hasIssue ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                    Text(
                        engine.diagnosis.hasIssue
                            ? t(en: "Issue", zh: "异常", ja: "要確認")
                            : t(en: "OK", zh: "正常", ja: "正常")
                    )
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((engine.diagnosis.hasIssue ? Color.red : Color.green).opacity(0.1))
                .clipShape(Capsule())
            }

            if engine.allDevices.count > 1 {
                HStack(spacing: 10) {
                    Text(t(en: "Target Device", zh: "目标设备", ja: "対象デバイス"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker(
                        t(en: "Target Device", zh: "目标设备", ja: "対象デバイス"),
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

            // 电量圆环 - 横排（只显示有数据的）
            HStack(spacing: 20) {
                if dev.batteryLeft != "-", let pctL = Int(dev.batteryLeft.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: t(en: "Left", zh: "左耳", ja: "左"), percent: pctL, icon: "ear")
                }
                if dev.batteryRight != "-", let pctR = Int(dev.batteryRight.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: t(en: "Right", zh: "右耳", ja: "右"), percent: pctR, icon: "ear")
                }
                if dev.batteryCase != "-", let pct = Int(dev.batteryCase.replacingOccurrences(of: "%", with: "")) {
                    BatteryRing(label: t(en: "Case", zh: "充电盒", ja: "ケース"), percent: pct, icon: "case")
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
            Text(t(en: "Diagnosis", zh: "诊断", ja: "診断"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            DiagRow(
                icon: engine.diagnosis.isDefaultOutput ? "checkmark.circle.fill" : "xmark.circle.fill",
                label: t(en: "Output Device", zh: "输出设备", ja: "出力デバイス"),
                value: engine.diagnosis.isDefaultOutput
                    ? selectedDeviceTitle(dev)
                    : t(en: "Not \(selectedDeviceTitle(dev))", zh: "非 \(selectedDeviceTitle(dev))", ja: "\(selectedDeviceTitle(dev)) ではない"),
                status: engine.diagnosis.isDefaultOutput ? .ok : .warn
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: "waveform",
                label: t(en: "Audio Mode", zh: "音频模式", ja: "音声モード"),
                value: engine.diagnosis.modeLabel(in: engine.language),
                status: engine.diagnosis.sampleRateHz == nil || engine.diagnosis.channelCount == nil
                    ? .neutral
                    : (engine.diagnosis.isReducedQualityMode ? .warn : .ok)
            )
            Divider().opacity(0.5)
            DiagRow(
                icon: engine.diagnosis.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: t(en: "Mute", zh: "静音", ja: "ミュート"),
                value: engine.diagnosis.isMuted
                    ? t(en: "Muted", zh: "已静音", ja: "ミュート中")
                    : t(en: "Off", zh: "关闭", ja: "オフ"),
                status: engine.diagnosis.isMuted ? .warn : .ok
            )
            Divider().opacity(0.5)

            let vol = Int(engine.diagnosis.volume) ?? 0
            DiagRow(
                icon: "speaker.wave.1.fill",
                label: t(en: "Volume", zh: "音量", ja: "音量"),
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
            Text(t(en: "Audio Tests", zh: "音频测试", ja: "音声テスト"))
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
                Text(t(en: "Speaker Test", zh: "扬声器测试", ja: "スピーカーテスト"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { engine.playTestSound() }) {
                    Text(engine.isPlayingTest ? t(en: "Playing...", zh: "播放中...", ja: "再生中...") : t(en: "Play", zh: "播放", ja: "再生"))
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
                Text(t(en: "Microphone Test", zh: "麦克风测试", ja: "マイクテスト"))
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
                    Text(engine.isMicMonitoring ? t(en: "Stop", zh: "停止", ja: "停止") : t(en: "Start", zh: "开始", ja: "開始"))
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
                        Text(t(en: "Quiet", zh: "安静", ja: "静か"))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                        Spacer()
                        Text(micLevelText(engine.micLevel, language: engine.language))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(micLevelColor(engine.micLevel))
                        Spacer()
                        Text(t(en: "Loud", zh: "响亮", ja: "大きい"))
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

    private func micLevelText(_ level: Float, language: AppLanguage) -> String {
        if level < 0.05 { return localized(language, en: "No Signal", zh: "无信号", ja: "信号なし") }
        if level < 0.2 { return localized(language, en: "Weak", zh: "微弱", ja: "弱い") }
        if level < 0.4 { return localized(language, en: "Normal", zh: "正常", ja: "通常") }
        if level < 0.7 { return localized(language, en: "Loud", zh: "较响", ja: "大きめ") }
        return localized(language, en: "Very Loud", zh: "很响", ja: "かなり大きい")
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
            Text(t(en: "Everything looks right but there is still no sound? Try repair.", zh: "都设置好了就是不出声音？修复一下", ja: "設定は合っているのに音が出ませんか？修復を試してください。"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            ActionButton(
                title: engine.isFixing ? t(en: "Repairing...", zh: "修复中...", ja: "修復中...") : t(en: "One-Click Repair", zh: "一键修复耳机音频", ja: "ワンクリック修復"),
                subtitle: t(en: "Tries in order: refresh route → restart audio service → reconnect Bluetooth", zh: "依次尝试：刷新音频路由 → 重启音频服务 → 重连蓝牙", ja: "順番に実行: 音声ルート更新 → 音声サービス再起動 → Bluetooth再接続"),
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
            Text(
                engine.bluetoothOn
                    ? t(en: "No compatible headset found", zh: "未找到兼容耳机", ja: "対応するヘッドセットが見つかりません")
                    : t(en: "Bluetooth Is Off", zh: "蓝牙未开启", ja: "Bluetoothがオフです")
            )
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text(t(en: "Make sure the headset is out of the case and close to your Mac", zh: "确保 AirPods 已取出并靠近 Mac", ja: "ヘッドセットをケースから出し、Mac の近くに置いてください"))
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
                    Text(t(en: "Logs", zh: "日志", ja: "ログ"))
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

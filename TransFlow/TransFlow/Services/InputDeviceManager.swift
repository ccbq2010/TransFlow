// InputDeviceManager.swift
// 枚举 macOS 上所有音频输入设备，并把 UID 解析成 AudioDeviceID。
// 给 SettingsView 用来展示可选列表，给 AudioCaptureService 用来绑定到非默认设备。
import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox
import Combine

/// Lightweight, Sendable description of a single audio input device.
struct InputDevice: Identifiable, Equatable, Hashable, Sendable {
    /// AudioDeviceID (a UInt32). Not a Swift Identifiable.id type itself, so we expose uid.
    let deviceID: AudioDeviceID
    /// Stable, system-wide unique identifier (e.g. "AppleHDAEngineInput:1", "BlackHole2ch_UID").
    let uid: String
    /// Human-readable name (e.g. "Mac mini Speakers", "AirPods Pro", "BlackHole 2ch").
    let name: String
    /// Manufacturer reported by CoreAudio (e.g. "Apple Inc.", "Existential Audio Inc").
    let manufacturer: String
    /// Number of input channels (1 for mono mics, 2 for stereo, etc.).
    let channelCount: Int
    /// True if the device is virtual (BlackHole, Loopback, AirPlay, Aggregate).
    /// Virtual devices usually do NOT capture ambient sound on their own — they
    /// only see audio that's been routed to them by another app or by the system.
    let isVirtual: Bool

    var id: String { uid }
}

/// Resolves device UIDs, enumerates input devices, and watches for plug/unplug events.
/// `@MainActor` so SwiftUI views can observe the @Published list directly.
@MainActor
final class InputDeviceManager: ObservableObject {
    static let shared = InputDeviceManager()

    /// All currently available input devices, sorted by name.
    @Published private(set) var devices: [InputDevice] = []

    /// UID of the system default input device ("BlackHole 2ch" on the user's setup).
    @Published private(set) var systemDefaultUID: String?

    /// Notification name emitted whenever the device list or system default changes.
    static let devicesDidChange = Notification.Name("InputDeviceManager.devicesDidChange")

    // C listener blocks. Accessed from the (nonisolated) deinit, so they cannot be
    // MainActor-isolated. The blocks themselves are safe to call from any thread
    // (they just dispatch a Task to MainActor).
    private nonisolated(unsafe) var listenerBlock: AudioObjectPropertyListenerBlock?
    private nonisolated(unsafe) var defaultListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        refresh()
        registerListeners()
    }

    deinit {
        // Tear listeners down via the raw C API. Safe to call from any thread.
        if let block = listenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
        if let block = defaultListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
    }

    // MARK: - Public

    /// Force a re-scan. Safe to call from the main actor.
    func refresh() {
        let (defaultUID, list) = Self.enumerate()
        self.systemDefaultUID = defaultUID
        self.devices = list
        NotificationCenter.default.post(name: Self.devicesDidChange, object: self)
    }

    /// Resolve a stored UID to an AudioDeviceID. Returns nil if the device is no longer connected.
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        devices.first(where: { $0.uid == uid })?.deviceID
    }

    /// Display name for a stored UID, falling back to a truncated UID string.
    func displayName(forUID uid: String?) -> String {
        guard let uid, !uid.isEmpty else {
            return devices.first(where: { $0.uid == systemDefaultUID })?.name
                ?? String(localized: "audio.input.system_default")
        }
        return devices.first(where: { $0.uid == uid })?.name ?? uid
    }

    // MARK: - Private

    private func registerListeners() {
        // Re-scan when devices come or go.
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devAddr, DispatchQueue.main, devBlock)
        self.listenerBlock = devBlock

        // Re-scan when the system default input changes (e.g. user picks one in System Settings).
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defAddr, DispatchQueue.main, defBlock)
        self.defaultListenerBlock = defBlock
    }

    // MARK: - CoreAudio enumeration

    /// Pure C-API enumeration. No SwiftUI / Observable dependency so it can be
    /// unit-tested in isolation. Returns (systemDefaultUID, sortedDevices).
    nonisolated static func enumerate() -> (String?, [InputDevice]) {
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &size
        ) == noErr, size > 0 else { return (nil, []) }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let st = ids.withUnsafeMutableBytes { p in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &size, p.baseAddress!)
        }
        guard st == noErr else { return (nil, []) }

        // Resolve system default input.
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var defaultID: AudioDeviceID = 0
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &defSize, &defaultID)

        var out: [InputDevice] = []
        out.reserveCapacity(ids.count)
        // BUG-FIX-DUP: macOS returns multiple distinct AudioDeviceIDs that share the same
        // device UID (virtual devices like BlackHole 2ch expose per-stream subdevices that
        // all report the same UID and human-readable name). Without dedup, the Settings
        // picker showed the same device three times. Dedupe by UID; the first deviceID
        // wins. (Choosing by UID is what the user-facing logic already uses.)
        var seenUIDs: Set<String> = []
        for id in ids {
            guard let info = describe(id) else { continue }
            if seenUIDs.insert(info.uid).inserted {
                out.append(info)
            }
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let defaultUID = out.first(where: { $0.deviceID == defaultID })?.uid
        return (defaultUID, out)
    }

    /// Per-device introspection. Returns nil if the device is not an input device
    /// or if the required properties are unavailable.
    private nonisolated static func describe(_ id: AudioDeviceID) -> InputDevice? {
        // Must have at least one input stream.
        var sAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var sSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { return nil }
        let streamCount = Int(sSize) / MemoryLayout<AudioStreamID>.size

        var totalChannels: Int = 0
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
        let streams = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: 1)
        defer { streams.deallocate() }
        guard AudioObjectGetPropertyData(id, &sAddr, 0, nil, &streamSize, streams) == noErr else { return nil }
        let sList = streams.assumingMemoryBound(to: AudioStreamID.self)
        for i in 0..<streamCount {
            var vAddr = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var vSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(sList[i], &vAddr, 0, nil, &vSize) == noErr, vSize > 0 else { continue }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(vSize), alignment: 1)
            defer { buf.deallocate() }
            guard AudioObjectGetPropertyData(sList[i], &vAddr, 0, nil, &vSize, buf) == noErr else { continue }
            let asbd = buf.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee
            totalChannels += Int(asbd.mChannelsPerFrame)
        }
        guard totalChannels > 0 else { return nil }

        let uid = stringProp(id, kAudioDevicePropertyDeviceUID)
        let name = cfStringProp(id, kAudioDevicePropertyDeviceNameCFString)
        let mfg = stringProp(id, kAudioDevicePropertyDeviceManufacturer)
        let transport = stringProp(id, kAudioDevicePropertyTransportType)
        // NOTE: Bluetooth is deliberately NOT treated as virtual — a Bluetooth
        // headset mic is a real capture device and must not be flagged as
        // "only captures audio routed to it".
        let isVirtual = ["virtual", "aggregate", "airplay"]
            .contains { transport.localizedCaseInsensitiveContains($0) }
            || mfg.localizedCaseInsensitiveContains("existential")
            || mfg.localizedCaseInsensitiveContains("rogue amoeba")
            || name.localizedCaseInsensitiveContains("blackhole")
            || name.localizedCaseInsensitiveContains("loopback")
            || name.localizedCaseInsensitiveContains("multi-output")
            || name.localizedCaseInsensitiveContains("aggregate")
        return InputDevice(
            deviceID: id,
            uid: uid,
            name: name,
            manufacturer: mfg,
            channelCount: totalChannels,
            isVirtual: isVirtual
        )
    }

    private nonisolated static func stringProp(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return "" }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 1)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, data) == noErr else { return "" }
        return String(data: Data(bytes: data, count: Int(size)), encoding: .utf8) ?? ""
    }

    private nonisolated static func cfStringProp(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr,
              let cf = ref?.takeRetainedValue() else { return "" }
        return cf as String
    }
}

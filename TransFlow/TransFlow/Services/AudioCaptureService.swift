@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
import CoreAudio

/// Captures microphone audio using AVAudioEngine, outputting 16kHz mono Float32 AudioChunks.
final class AudioCaptureService: @unchecked Sendable {

    /// Start capturing microphone audio.
    /// - Parameter deviceUID: Optional CoreAudio device UID (e.g. "AppleHDAEngineInput:1").
    ///   When nil, the engine uses the macOS system default input. When set, the engine's
    ///   input node is rebound to the specified device via `kAudioOutputUnitProperty_CurrentDevice`
    ///   BEFORE the tap is installed, so the user can record from any device regardless of
    ///   what the system default currently is.
    /// - Returns: A stream of `AudioChunk` and a `stop` closure.
    nonisolated func startCapture(deviceUID: String? = nil) -> (stream: AsyncStream<AudioChunk>, stop: @Sendable () -> Void) {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // CRITICAL (P0-AUDIO-1 修复): AVAudioEngine 的 I/O 图是懒初始化的，
        // `engine.inputNode.audioUnit` 在 `prepare()` / `start()` 之前是 **nil**。
        // 若不先 prepare()，下面 bindInputDevice 里读 `audioUnit` 会拿到 nil →
        // kAudioOutputUnitProperty_CurrentDevice 绑定静默失败（return false）→
        // 引擎停留在系统默认输入（通常是虚拟聚合设备 CADefaultDeviceAggregate）
        // → 完全采集不到真实麦克风声音。
        // `prepare()` 仅初始化音频单元、不启动 IO，正好让 audioUnit 就绪以便绑定。
        engine.prepare()
        var inputFormat = inputNode.outputFormat(forBus: 0)

        // Log the device the engine's input node is ACTUALLY bound to right now,
        // read from the audio unit's kAudioOutputUnitProperty_CurrentDevice (not from
        // kAudioHardwarePropertyDefaultInputDevice). Before any explicit bind the
        // engine mirrors the system default; after a bind it shows the device we
        // really capture from. This is the source of truth for the diagnostic.
        let initialID = Self.boundDeviceID(on: engine) ?? 0
        let (initialName, initialUID) = Self.nameAndUID(forDeviceID: initialID)
        NSLog("[AudioCapture] input device (initial): name=\(initialName) uid=\(initialUID) format=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch")

        // If a specific device UID was requested, rebind the input node's underlying
        // AudioUnit to that device. Must happen BEFORE engine.start() and before
        // installTap, otherwise the tap will be tied to the system default and the
        // format we read above will be wrong for the actual device we'll be tapping.
        if let deviceUID, !deviceUID.isEmpty,
           let deviceID = Self.resolveDeviceID(uid: deviceUID) {
            let bound = Self.bindInputDevice(deviceID: deviceID, on: engine)
            // Re-read the format AFTER the bind so the converter is built for the
            // actual device we'll be capturing from. (Different devices can report
            // very different sample rates and channel counts.)
            inputFormat = inputNode.outputFormat(forBus: 0)
            let (boundName, boundUID) = Self.nameAndUID(forDeviceID: deviceID)
            NSLog("[AudioCapture] input device (after bind): name=\(boundName) uid=\(boundUID) format=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch bound=\(bound)")
            if !bound {
                ErrorLogger.shared.log(
                    "Failed to bind input device '\(boundName)' (uid=\(boundUID)). Engine will stay on system default — audio capture may be silent. " +
                    "Likely cause: the audio unit was not initialized before bind, or the device is no longer available.",
                    source: "AudioCapture"
                )
            }
        } else if let deviceUID, !deviceUID.isEmpty {
            NSLog("[AudioCapture] WARN: requested deviceUID=\(deviceUID) not found among current inputs; falling back to system default")
        } else {
            // No device UID specified (System Default).
            // If the resolved default is a virtual/aggregate device (e.g. BlackHole,
            // Loopback, CADefaultDeviceAggregate), it may capture silence when no app
            // is routing audio to it. Do NOT silently switch devices — the user may have
            // intentionally chosen a virtual default (e.g. routing a call into BlackHole).
            // Log a loud warning; the UI surfaces a non-fatal alert with guidance.
            let isVirtualDefault = Self.isVirtualDevice(deviceID: initialID)
            if isVirtualDefault {
                ErrorLogger.shared.log(
                    "⚠️ System default input '\(initialName)' is a virtual/aggregate device — " +
                    "may capture silence. Recording continues on the system default; " +
                    "select a real microphone in Settings if no sound is captured.",
                    source: "AudioCapture"
                )
                NSLog("[AudioCapture] ⚠️ System default '\(initialName)' is virtual — continuing on system default (no auto-fallback)")
            }
        }

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16_000, channels: 1
        ) else {
            ErrorLogger.shared.log(
                "Failed to create target audio format (16kHz mono)",
                source: "AudioCapture"
            )
            continuation.finish()
            return (stream, {})
        }

        // Create converter from input format to 16kHz mono
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            ErrorLogger.shared.log(
                "Failed to create audio converter from \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch to 16kHz/1ch",
                source: "AudioCapture"
            )
            continuation.finish()
            return (stream, {})
        }

        // P0-A: Counter for diagnostic logging of the first N audio chunks.
        // Placed outside the tap closure because closures cannot capture mutable statics.
        nonisolated(unsafe) var chunkLogCount: Int32 = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // CRITICAL: output capacity MUST be derived from the actual input buffer size.
            // A fixed capacity (previously 1600) silently truncates audio whenever
            // inputFrames * (16000 / inputSampleRate) > capacity.
            // e.g. AirPods mic @24kHz delivers 4096-frame buffers -> needs ~2731 output
            // frames; with 1600 capacity, 41% of all audio was dropped, destroying
            // recognition accuracy. Built-in mic @48kHz (-> ~1365 frames) masked the bug.
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let requiredCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: requiredCapacity
            ) else { return }

            var error: NSError?
            nonisolated(unsafe) var consumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil, outputBuffer.frameLength > 0,
                  let channelData = outputBuffer.floatChannelData else { return }

            let frameCount = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

            // Calculate normalized audio level: RMS → dB → 0-1
            let level = Self.calculateNormalizedLevel(samples: samples)

            // P0-A: Log audio level for the first 20 chunks to help diagnose
            // silent/virtual device issues. RMS < 0.01 → VAD will strip it.
            let idx = OSAtomicIncrement32(&chunkLogCount)
            if idx <= 20 {
                let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
                NSLog("[AudioCapture] chunk #\(idx) RMS=\(String(format: "%.4f", rms)) level=\(String(format: "%.3f", level)) frames=\(frameCount)")
            }

            let chunk = AudioChunk(
                samples: samples,
                level: level,
                timestamp: Date()
            )
            continuation.yield(chunk)
        }

        do {
            try engine.start()
        } catch {
            // 修复：engine.start() 失败时必须移除已安装的 tap，否则下次 installTap 会崩溃
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            return (stream, {})
        }

        nonisolated(unsafe) let capturedEngine = engine
        nonisolated(unsafe) let capturedInputNode = inputNode
        let stop: @Sendable () -> Void = {
            capturedInputNode.removeTap(onBus: 0)
            capturedEngine.stop()
            continuation.finish()
        }

        return (stream, stop)
    }

    /// Rebind the given AVAudioEngine's input node to a specific AudioDeviceID.
    /// Returns true on success.
    nonisolated private static func bindInputDevice(deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        guard let au = engine.inputNode.audioUnit else { return false }
        var dev = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    /// Resolve a CoreAudio device UID to its AudioDeviceID by walking the current device list.
    nonisolated private static func resolveDeviceID(uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        _ = ids.withUnsafeMutableBytes { p in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, p.baseAddress!)
        }
        for id in ids {
            var nAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var ref: Unmanaged<CFString>?
            var nSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nAddr, 0, nil, &nSize, &ref) == noErr,
                  let cf = ref?.takeRetainedValue() else { continue }
            if (cf as String) == uid { return id }
        }
        return nil
    }

    /// Request microphone permission.
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Input device introspection (for diagnostics / device picker UI)

    /// The AudioDeviceID actually bound to the engine's input node right now, read
    /// from the audio unit's `kAudioOutputUnitProperty_CurrentDevice`. This is the
    /// device the engine will really capture from — which may differ from the
    /// macOS system default once we've explicitly bound a specific device.
    nonisolated private static func boundDeviceID(on engine: AVAudioEngine) -> AudioDeviceID? {
        guard let au = engine.inputNode.audioUnit else { return nil }
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            &size
        )
        return status == noErr ? dev : nil
    }

    /// Resolve an AudioDeviceID to its (name, UID) pair for logging.
    nonisolated private static func nameAndUID(forDeviceID id: AudioDeviceID) -> (String, String) {
        guard id != 0 else { return ("", "") }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var name = ""
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
           let cf = nameRef?.takeRetainedValue() {
            name = cf as String
        }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uid = ""
        if AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
           let cf = uidRef?.takeRetainedValue() {
            uid = cf as String
        }

        return (name, uid)
    }

    /// Check if the given AudioDeviceID is a virtual/aggregate device (BlackHole, Loopback, etc.).
    /// Uses the same heuristics as InputDeviceManager.isVirtual.
    nonisolated private static func isVirtualDevice(deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }

        // Read transport type
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = ""
        if let ref: Unmanaged<CFString> = Self.readProperty(deviceID, &tAddr) {
            transport = ref.takeRetainedValue() as String
        }

        // Read manufacturer
        var mAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceManufacturer,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mfg = ""
        if let ref: Unmanaged<CFString> = Self.readProperty(deviceID, &mAddr) {
            mfg = ref.takeRetainedValue() as String
        }

        // Read device name
        var nAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = ""
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(deviceID, &nAddr, 0, nil, &nameSize, &nameRef) == noErr,
           let cf = nameRef?.takeRetainedValue() {
            name = cf as String
        }

        return ["virtual", "aggregate", "airplay"]
            .contains { transport.localizedCaseInsensitiveContains($0) }
            || mfg.localizedCaseInsensitiveContains("existential")
            || mfg.localizedCaseInsensitiveContains("rogue amoeba")
            || name.localizedCaseInsensitiveContains("blackhole")
            || name.localizedCaseInsensitiveContains("loopback")
            || name.localizedCaseInsensitiveContains("multi-output")
            || name.localizedCaseInsensitiveContains("aggregate")
    }

    /// Helper: read a CFString property from an AudioDeviceID.
    nonisolated private static func readProperty(_ id: AudioDeviceID, _ addr: inout AudioObjectPropertyAddress) -> Unmanaged<CFString>? {
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        return ref
    }

    /// Calculate normalized audio level from samples: RMS → dB → 0-1 range.
    nonisolated private static func calculateNormalizedLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        // Normalize: -60dB → 0, 0dB → 1
        let normalized = max(0, min(1, (db + 60) / 60))
        return normalized
    }
}

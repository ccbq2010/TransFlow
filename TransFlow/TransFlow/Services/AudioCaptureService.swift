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
        var inputFormat = inputNode.outputFormat(forBus: 0)

        // Log which input device the system actually gave us — if the user picked
        // BlackHole 2ch (or any other virtual device) as macOS default input, this
        // will be that virtual device's UID, NOT the real microphone.
        let resolvedName = AudioCaptureService.currentInputDeviceName()
        let resolvedUID = AudioCaptureService.currentInputDeviceUID()
        NSLog("[AudioCapture] input device (initial): name=\(resolvedName) uid=\(resolvedUID) format=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch")

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
            let reboundName = AudioCaptureService.currentInputDeviceName()
            let reboundUID = AudioCaptureService.currentInputDeviceUID()
            NSLog("[AudioCapture] input device (after bind): name=\(reboundName) uid=\(reboundUID) format=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch bound=\(bound)")
        } else if let deviceUID, !deviceUID.isEmpty {
            NSLog("[AudioCapture] WARN: requested deviceUID=\(deviceUID) not found among current inputs; falling back to system default")
        }

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16_000, channels: 1
        ) else {
            continuation.finish()
            return (stream, {})
        }

        // Create converter from input format to 16kHz mono
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            continuation.finish()
            return (stream, {})
        }

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

    // MARK: - Default input device introspection (for diagnostics / device picker UI)

    /// Human-readable name of the system default input device, e.g. "Mac mini Speakers",
    /// "AirPods Pro", "BlackHole 2ch". Returns "" if unavailable.
    nonisolated static func currentInputDeviceName() -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devId: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devId
        ) == noErr, devId != 0 else { return "" }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            devId, &nameAddr, 0, nil, &nameSize, &nameRef
        ) == noErr, let cf = nameRef?.takeRetainedValue() else { return "" }
        return cf as String
    }

    /// Stable UID of the system default input device (e.g. "AppleHDAEngineInput:1").
    /// Returns "" if unavailable.
    nonisolated static func currentInputDeviceUID() -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devId: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devId
        ) == noErr, devId != 0 else { return "" }
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            devId, &uidAddr, 0, nil, &uidSize, &uidRef
        ) == noErr, let cf = uidRef?.takeRetainedValue() else { return "" }
        return cf as String
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

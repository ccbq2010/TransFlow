import Foundation
import SwiftUI

/// Cloud ASR provider presets.
///
/// Extensible: add a new `case` here and supply its `defaultBaseURL` /
/// `defaultModel`, and the Settings UI + persistence pick it up automatically.
/// New non-OpenAI-compatible backends (e.g. a true streaming WebSocket) can be
/// added by conforming to `CloudASRServiceProtocol` and selecting it in the engine.
enum CloudASRProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    /// SiliconFlow OpenAI-compatible audio transcription endpoint (VOX's provider).
    case siliconFlow = "siliconflow"
    /// Any OpenAI-compatible `/v1/audio/transcriptions` endpoint (bring your own URL + model).
    case custom = "custom"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .siliconFlow: "cloud_asr.provider.siliconflow"
        case .custom: "cloud_asr.provider.custom"
        }
    }

    /// Default endpoint URL for this provider.
    var defaultBaseURL: String {
        switch self {
        case .siliconFlow: "https://api.siliconflow.cn/v1/audio/transcriptions"
        case .custom: ""
        }
    }

    /// Default model identifier for this provider.
    ///
    /// SiliconFlow's `/v1/audio/transcriptions` only supports two models:
    /// `FunAudioLLM/SenseVoiceSmall` (multilingual incl. English, free) and
    /// `TeleAI/TeleSpeechASR` (Chinese-focused). SenseVoiceSmall is the better
    /// default for English use.
    var defaultModel: String {
        switch self {
        case .siliconFlow: "FunAudioLLM/SenseVoiceSmall"
        case .custom: ""
        }
    }
}

/// Configuration for the optional cloud ASR correction layer (Scheme A).
///
/// Persisted as a single JSON blob in `UserDefaults` so the whole struct can be
/// extended with new fields without migrating many individual keys.
struct CloudASRConfig: Codable, Sendable, Equatable {
    /// Master switch. When off, the on-device engine is used as-is.
    var enabled: Bool
    /// Selected provider preset.
    var provider: CloudASRProvider
    /// API key / bearer token.
    var apiKey: String
    /// Full endpoint URL (OpenAI-compatible multipart `/v1/audio/transcriptions`).
    var baseURL: String
    /// Model identifier understood by the endpoint.
    var model: String
    /// Per-request network timeout in seconds.
    var timeout: TimeInterval
    /// Max seconds of audio sent per request; longer audio is chunked (VOX uses 7s).
    var chunkSeconds: TimeInterval

    init(
        enabled: Bool = false,
        provider: CloudASRProvider = .siliconFlow,
        apiKey: String = "",
        baseURL: String = CloudASRProvider.siliconFlow.defaultBaseURL,
        model: String = CloudASRProvider.siliconFlow.defaultModel,
        timeout: TimeInterval = 8.0,
        chunkSeconds: TimeInterval = 7.0
    ) {
        self.enabled = enabled
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.chunkSeconds = chunkSeconds
    }

    /// Sensible default: disabled, SiliconFlow preset with VOX's TeleSpeechASR model.
    static let `default` = CloudASRConfig()

    /// Whether a request can actually be attempted with the current config.
    var isConfigured: Bool {
        enabled && !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }
}

/// Abstraction over a cloud transcription backend.
///
/// The default implementation (`CloudASRService`) targets OpenAI-compatible
/// `/v1/audio/transcriptions` endpoints. Swap in a different conformer (e.g. a
/// true streaming WebSocket client) without touching the engine layer.
protocol CloudASRServiceProtocol: Sendable {
    /// Transcribe raw 16kHz mono Float32 samples; returns recognized text or nil on failure.
    func transcribe(samples: [Float], sampleRate: Double) async -> String?
    /// Transcribe already-encoded 16-bit PCM WAV data; returns recognized text or nil on failure.
    func transcribe(wavData: Data) async -> String?
}

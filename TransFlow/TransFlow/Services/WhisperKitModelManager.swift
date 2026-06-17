import Foundation
import WhisperKit
import Observation

/// Manages WhisperKit model download status and progress.
/// Separate from `SpeechModelManager` which handles Apple Speech models.
@Observable
@MainActor
final class WhisperKitModelManager {
    static let shared = WhisperKitModelManager()

    /// 默认模型：large-v3_turbo 量化版（954MB），速度快、准确度高。
    /// 必须使用完整目录名，否则 WhisperKit 的 `*small/*` glob 会匹配到多个目录
    /// （openai_whisper-small / openai_whisper-small.en / openai_whisper-small_216MB 等），
    /// 抛出 "Multiple models found" 错误。
    static let defaultModelName = "openai_whisper-large-v3_turbo_954MB"

    /// HuggingFace 镜像站，解决 huggingface.co 在中国区域被墙的问题。
    static let mirrorEndpoint = "https://hf-mirror.com"

    /// Current download state.
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case failed(message: String)
    }

    var downloadState: DownloadState = .notDownloaded

    /// Whether the model is ready for use.
    var isReady: Bool {
        if case .ready = downloadState { return true }
        return false
    }

    private var downloadTask: Task<Void, Never>?

    private init() {}

    /// Check if the model is already downloaded.
    /// 同时检查 UserDefaults 标记和磁盘文件，避免用户清理缓存后误报就绪。
    func checkStatus(modelName: String = WhisperKitModelManager.defaultModelName) async {
        let key = "whisperkit.model.\(modelName).downloaded"
        let userDefaultsSaysReady = UserDefaults.standard.bool(forKey: key)

        if userDefaultsSaysReady {
            // 验证模型文件确实存在
            if Self.modelExistsOnDisk(modelName: modelName) {
                downloadState = .ready
            } else {
                // UserDefaults 标记为已下载但文件不存在（用户清理了缓存）
                UserDefaults.standard.set(false, forKey: key)
                downloadState = .notDownloaded
            }
        } else {
            downloadState = .notDownloaded
        }
    }

    /// 检查模型目录是否存在于 HuggingFace 默认下载路径。
    /// WhisperKit 默认下载到 ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<modelName>
    private static func modelExistsOnDisk(modelName: String) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelPath = documents
            .appending(component: "huggingface")
            .appending(component: "models")
            .appending(component: "argmaxinc")
            .appending(component: "whisperkit-coreml")
            .appending(component: modelName)
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Download the WhisperKit model.
    func downloadModel(modelName: String = WhisperKitModelManager.defaultModelName) async {
        // Cancel any existing download
        downloadTask?.cancel()

        downloadTask = Task {
            downloadState = .downloading(progress: 0)

            do {
                // 先用 WhisperKit.download 静态方法下载，拿到进度回调。
                // 不直接用 WhisperKit(config) 是因为 config 路径不暴露下载进度。
                ErrorLogger.shared.info(
                    "开始下载 WhisperKit 模型: \(modelName) from \(Self.mirrorEndpoint)",
                    source: "WhisperKitModelManager"
                )
                let modelFolder = try await WhisperKit.download(
                    variant: modelName,
                    from: "argmaxinc/whisperkit-coreml",
                    endpoint: Self.mirrorEndpoint
                ) { progress in
                    // progressCallback 是 @Sendable，不能捕获 @MainActor 的 self，
                    // 通过 shared 单例 + MainActor Task 更新 UI
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        WhisperKitModelManager.shared.downloadState = .downloading(progress: fraction)
                    }
                }

                // 下载完成后，用 modelFolder 初始化 WhisperKit 加载模型，验证模型可用
                let config = WhisperKitConfig(
                    modelFolder: modelFolder.path,
                    download: false
                )
                _ = try await WhisperKit(config)

                // 下载成功后用 UserDefaults 标记
                let key = "whisperkit.model.\(modelName).downloaded"
                UserDefaults.standard.set(true, forKey: key)

                ErrorLogger.shared.info(
                    "WhisperKit 模型下载完成: \(modelName)",
                    source: "WhisperKitModelManager"
                )
                downloadState = .ready
            } catch {
                let msg = error.localizedDescription
                ErrorLogger.shared.error(
                    "WhisperKit 模型下载失败 (\(modelName)): \(msg)",
                    source: "WhisperKitModelManager"
                )
                downloadState = .failed(message: msg)
            }
        }

        await downloadTask?.value
    }

    /// Cancel the current download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = .notDownloaded
    }
}

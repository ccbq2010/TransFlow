import Foundation
import WhisperKit
import CoreMedia

let modelFolder = "/Users/sichengyu/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo_954MB"
let log = { print("[whisper-test] " + $0) }

log("Start: \(Date())")
log("Model folder: \(modelFolder)")

// Probe 1: file size
let attrs = try! FileManager.default.attributesOfItem(atPath: modelFolder)
log("Folder exists, size=\(attrs[.size] ?? 0)")

// Probe 2: config.json content
let cfgURL = URL(fileURLWithPath: modelFolder).appending(path: "config.json")
if let data = try? Data(contentsOf: cfgURL),
   let str = String(data: data, encoding: .utf8) {
    log("config.json head: \(str.prefix(200))")
}

// Probe 3: try WhisperKit init with download: false
let t0 = Date()
log("Calling WhisperKit(config: modelFolder: download: false) — this may take 10-60s on first run")
do {
    let config = WhisperKitConfig(
        modelFolder: modelFolder,
        download: false
    )
    let wk = try await WhisperKit(config)
    log("SUCCESS in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s — WhisperKit loaded, modelState=\(wk.modelState)")

    // Try a quick transcription
    let fakeAudio: [Float] = Array(repeating: 0.0, count: 16000) // 1s silence
    let results = try await wk.transcribe(audioArray: fakeAudio, decodeOptions: nil)
    log("Transcribe (silence) returned \(results.count) result(s)")

} catch {
    log("FAILED in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(error)")
    log("Error type: \(type(of: error))")
    log("Error description: \(error.localizedDescription)")
    if let ns = error as NSError? {
        log("NSError domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
    }
}
log("End: \(Date())")

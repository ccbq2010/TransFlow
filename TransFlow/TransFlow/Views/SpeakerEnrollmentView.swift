import SwiftUI
import AVFoundation

/// Guided flow for enrolling a new speaker: record ~8s of speech and extract a voice embedding.
struct SpeakerEnrollmentView: View {
    let participantName: String
    let onComplete: ([Float]) -> Void
    let onCancel: () -> Void

    @State private var enrollmentService = SpeakerEnrollmentService()
    @State private var audioCapture: AudioCaptureService? = nil
    @State private var stopCapture: (@Sendable () -> Void)?
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var audioLevel: Float = 0
    @State private var recordingDuration: Double = 0
    @State private var errorMessage: String?
    @State private var timer: Timer?

    private let minimumDuration = SpeakerEnrollmentService.minimumDuration
    private let recommendedDuration = SpeakerEnrollmentService.recommendedDuration

    var body: some View {
        VStack(spacing: 24) {
            headerSection
            recordingSection
            Spacer()
            actionButtons
        }
        .padding(32)
        .frame(width: 420, height: 480)
        .task {
            await prepareService()
        }
        .onDisappear {
            stopRecording()
            timer?.invalidate()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("enroll.title")
                .font(.system(size: 18, weight: .semibold))
            Text(participantName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blue)

            Text("enroll.instruction")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Recording Section

    private var recordingSection: some View {
        VStack(spacing: 16) {
            // Audio level meter
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary.opacity(0.3))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isRecording ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: max(0, min(CGFloat(audioLevel) * geo.size.width, geo.size.width)))
                }
            }
            .frame(height: 8)

            // Duration counter
            Text(String(format: "%.1fs", recordingDuration))
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .foregroundStyle(isRecording ? .primary : .secondary)

            // Progress bar
            ProgressView(value: min(recordingDuration / recommendedDuration, 1.0))
                .progressViewStyle(.linear)
                .tint(.blue)
                .frame(height: 4)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("enroll.cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Spacer()

            if isRecording {
                Button(action: finishRecording) {
                    Text("enroll.stop")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!enrollmentService.hasEnoughAudio)
                .keyboardShortcut(.defaultAction)
            } else if isProcessing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: startRecording) {
                    Text("enroll.start")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Recording Control

    private func prepareService() async {
        do {
            try await enrollmentService.prepare()
        } catch {
            errorMessage = String(localized: "enroll.error.prepare_failed")
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        errorMessage = nil
        enrollmentService.reset()
        isRecording = true

        Task {
            let granted = await AudioCaptureService.requestPermission()
            guard granted else {
                await MainActor.run {
                    isRecording = false
                    errorMessage = String(localized: "error.mic_permission_denied")
                }
                return
            }
            let captureService = AudioCaptureService()
            let capture = captureService.startCapture(deviceUID: AppSettings.shared.selectedInputDeviceUID)
            await MainActor.run {
                self.audioCapture = captureService
                self.stopCapture = capture.stop
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    self.recordingDuration = self.enrollmentService.currentDuration
                }
            }

            for await chunk in capture.stream {
                enrollmentService.feedAudio(chunk.samples)
                await MainActor.run {
                    audioLevel = chunk.level
                }
            }
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        stopCapture?()
        stopCapture = nil
        audioCapture = nil
        isRecording = false
    }

    private func finishRecording() {
        stopRecording()
        isProcessing = true

        Task {
            do {
                let embedding = try enrollmentService.extractEmbedding()
                enrollmentService.cleanup()
                await MainActor.run {
                    isProcessing = false
                    onComplete(embedding)
                }
            } catch {
                enrollmentService.cleanup()
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

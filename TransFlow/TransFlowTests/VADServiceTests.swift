//
//  VADServiceTests.swift
//  TransFlowTests
//

import Testing
import Foundation
@testable import TransFlow

struct VADServiceTests {

    @Test @MainActor func emptySamplesReturnsNoSegments() {
        let vad = VADService()
        #expect(vad.detectSpeechSegments([]).isEmpty)
    }

    @Test @MainActor func pureSilenceReturnsNoSegments() {
        let vad = VADService(silenceThreshold: 0.01, sampleRate: 16000)
        // 1 秒静音（全零）
        let silence = [Float](repeating: 0.0, count: 16000)
        #expect(vad.detectSpeechSegments(silence).isEmpty)
    }

    @Test @MainActor func continuousSpeechDetectedAsSingleSegment() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        // 1 秒持续语音：正弦波幅值 0.1（远超阈值 0.01）
        let speech = (0..<16000).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        let segments = vad.detectSpeechSegments(speech)
        #expect(segments.count == 1)
        // 段应覆盖大部分样本
        let seg = segments[0]
        #expect(seg.upperBound - seg.lowerBound > 8000)
    }

    @Test @MainActor func silenceBetweenSpeechProducesTwoSegments() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        // 0.5s 语音 + 1s 静音 + 0.5s 语音
        let speechPart = (0..<8000).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        let silence = [Float](repeating: 0.0, count: 16000)
        let samples = speechPart + silence + speechPart
        let segments = vad.detectSpeechSegments(samples)
        #expect(segments.count == 2)
    }

    @Test @MainActor func extractSpeechRemovesSilence() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        let speechPart = (0..<8000).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        let silence = [Float](repeating: 0.0, count: 16000)
        let samples = speechPart + silence + speechPart
        let extracted = vad.extractSpeech(samples)
        // 提取后应短于原始（静音被移除），且非空
        #expect(!extracted.isEmpty)
        #expect(extracted.count < samples.count)
    }

    @Test @MainActor func shortNoiseBurstFiltered() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,  // 要求至少 0.3s
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        // 0.1s 短噪声（低于 minSpeechDuration）+ 静音
        let noise = [Float](repeating: 0.5, count: 1600)  // 0.1s
        let silence = [Float](repeating: 0.0, count: 16000)
        let samples = noise + silence
        #expect(vad.detectSpeechSegments(samples).isEmpty)
    }
}

#!/usr/bin/env python3
"""P3-1: Add i18n keys to Localizable.xcstrings"""
import json
import sys

xcstrings_path = sys.argv[1]

with open(xcstrings_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

new_keys = {
    # SpeechEngine
    "speech.error.language_not_supported %@": {
        "en": "Language %@ is not supported.",
        "zh-Hans": "语言 %@ 不受支持。"
    },
    "speech.error.speech_error %@": {
        "en": "Speech error: %@",
        "zh-Hans": "语音错误：%@"
    },
    "speech.error.engine_error %@": {
        "en": "Engine error: %@",
        "zh-Hans": "引擎错误：%@"
    },
    # UpdateChecker
    "update.error.no_pkg_asset": {
        "en": "No PKG asset found in release",
        "zh-Hans": "发布版本中未找到 PKG 安装包"
    },
    "update.error.invalid_url": {
        "en": "Invalid download URL",
        "zh-Hans": "无效的下载链接"
    },
    # AudioExtractorService
    "audio_extractor.error.unknown": {
        "en": "Unknown error",
        "zh-Hans": "未知错误"
    },
    "audio_extractor.error.incomplete_read": {
        "en": "Incomplete read",
        "zh-Hans": "读取不完整"
    },
    "audio_extractor.error.no_audio_track": {
        "en": "No audio track found in the file.",
        "zh-Hans": "文件中未找到音频轨道。"
    },
    "audio_extractor.error.extraction_failed %@": {
        "en": "Audio extraction failed: %@",
        "zh-Hans": "音频提取失败：%@"
    },
    # SpeakerEnrollmentService
    "enrollment.error.not_prepared": {
        "en": "Enrollment service not prepared. Call prepare() first.",
        "zh-Hans": "注册服务未准备就绪，请先调用 prepare()。"
    },
    "enrollment.error.insufficient_audio %f %f": {
        "en": "Need at least %.1fs of audio, got %.1fs.",
        "zh-Hans": "至少需要 %.1fs 的音频，当前仅有 %.1fs。"
    },
}

for key, translations in new_keys.items():
    if key not in data["strings"]:
        data["strings"][key] = {
            "extractionState": "manual",
            "localizations": {}
        }
        for lang, value in translations.items():
            data["strings"][key]["localizations"][lang] = {
                "stringUnit": {
                    "state": "translated",
                    "value": value
                }
            }

with open(xcstrings_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f"Added {len(new_keys)} i18n keys")

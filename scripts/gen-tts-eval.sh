#!/bin/bash
# gen-tts-eval.sh — 用 macOS TTS 生成英文+中文评测集
# 每条音频 16kHz mono PCM wav，配套 .ref.txt 黄金转录

set -e

EVAL_DIR="$(dirname "$0")/../TransFlow/TransFlowTests/Resources/eval"
EVAL_DIR="$(cd "$EVAL_DIR" && pwd)"
mkdir -p "$EVAL_DIR"

# ── 英文 (Samantha, en_US) ──
declare -a EN_TEXTS=(
"en_short_1:The quick brown fox jumps over the lazy dog."
"en_short_2:Hello world, this is a test of the speech recognition system."
"en_medium_1:Artificial intelligence is transforming how we work and live. Machine learning models can now understand language, generate images, and even write code. The possibilities are endless."
"en_medium_2:Welcome to the conference. Today we will discuss the future of renewable energy and its impact on global climate policy. Please take your seats."
"en_long_1:The history of computing is a story of constant innovation. From the early mechanical calculators of Pascal and Babbage, through the vacuum tube era of ENIAC, to the silicon revolution that put a computer on every desk, and now the age of quantum computing, each generation has built upon the last to create machines of extraordinary power and complexity."
"en_tech_1:WhisperKit is a Swift package that provides on-device speech recognition using Core ML models. It supports multiple languages and offers real-time streaming capabilities."
)

# ── 中文 (Tingting, zh_CN) ──
declare -a ZH_TEXTS=(
"zh_short_1:今天天气真不错，我们一起去公园散步吧。"
"zh_short_2:你好世界，这是一个语音识别系统的测试。"
"zh_medium_1:人工智能正在改变我们的工作和生活方式。机器学习模型现在已经能够理解语言、生成图像，甚至编写代码。未来的可能性是无限的。"
"zh_medium_2:欢迎参加本次会议。今天我们将讨论可再生能源的未来及其对全球气候政策的影响。请各位就座。"
"zh_long_1:计算机的历史是一部不断创新的故事。从帕斯卡和巴贝奇的早期机械计算器，到电子管时代的埃尼阿克，再到硅革命将计算机放在每个人的桌面上，以及现在的量子计算时代，每一代都建立在前一代的基础上，创造出非凡力量和复杂性的机器。"
"zh_tech_1:WhisperKit 是一个 Swift 包，使用 Core ML 模型提供设备端语音识别。它支持多种语言并提供实时流式处理能力。"
)

# ── 繁体中文 (Meijia, zh_TW) ──
declare -a ZH_TW_TEXTS=(
"zh_tw_1:臺灣的天氣很好，我們一起去公園散步吧。"
"zh_tw_2:歡迎參加今天的會議，我們將討論人工智慧的未來發展。"
)

generate() {
    local lang=$1
    local voice=$2
    shift 2
    for entry in "$@"; do
        local id="${entry%%:*}"
        local text="${entry#*:}"
        local wav="$EVAL_DIR/$id.wav"
        local ref="$EVAL_DIR/$id.ref.txt"

        # 跳过已存在的
        if [ -f "$wav" ] && [ -f "$ref" ]; then
            echo "  · skip $id (exists)"
            continue
        fi

        # 用 say 生成 AIFF，再用 ffmpeg 转 16kHz mono PCM wav
        local aiff="/tmp/${id}.aiff"
        say -v "$voice" -o "$aiff" "$text"
        ffmpeg -y -v error -i "$aiff" -ar 16000 -ac 1 -sample_fmt s16 "$wav"
        rm -f "$aiff"

        # 写黄金转录
        echo "$text" > "$ref"
        echo "  ✓ $id ($lang, $(du -h "$wav" | cut -f1))"
    done
}

echo "[EN] Generating English TTS (Samantha)..."
generate en Samantha "${EN_TEXTS[@]}"

echo "[ZH] Generating Chinese TTS (Tingting)..."
generate zh Tingting "${ZH_TEXTS[@]}"

echo "[ZH-TW] Generating Traditional Chinese TTS (Meijia)..."
generate zh Meijia "${ZH_TW_TEXTS[@]}"

# ── 更新 manifest.json ──
python3 - "$EVAL_DIR" << 'PYEOF'
import json, sys, os

eval_dir = sys.argv[1]
manifest_path = os.path.join(eval_dir, "manifest.json")

cases = [
    {"id": "en_short_1", "language": "en", "synthetic": True, "note": "macOS TTS (Samantha); 短句"},
    {"id": "en_short_2", "language": "en", "synthetic": True, "note": "macOS TTS (Samantha); 短句"},
    {"id": "en_medium_1", "language": "en", "synthetic": True, "note": "macOS TTS (Samantha); 中等长度"},
    {"id": "en_medium_2", "language": "en", "synthetic": True, "note": "macOS TTS (Samantha); 中等长度"},
    {"id": "en_long_1", "language": "en", "synthetic": True, "note": "macOS TTS (Samantha); 长句"},
    {"id": "en_tech_1", "language": "en", "synthetic": True, "note": "macOS TTS (Samantha); 技术词汇"},
    {"id": "zh_short_1", "language": "zh", "synthetic": True, "note": "macOS TTS (Tingting); 短句"},
    {"id": "zh_short_2", "language": "zh", "synthetic": True, "note": "macOS TTS (Tingting); 短句"},
    {"id": "zh_medium_1", "language": "zh", "synthetic": True, "note": "macOS TTS (Tingting); 中等长度"},
    {"id": "zh_medium_2", "language": "zh", "synthetic": True, "note": "macOS TTS (Tingting); 中等长度"},
    {"id": "zh_long_1", "language": "zh", "synthetic": True, "note": "macOS TTS (Tingting); 长句"},
    {"id": "zh_tech_1", "language": "zh", "synthetic": True, "note": "macOS TTS (Tingting); 技术词汇"},
    {"id": "zh_tw_1", "language": "zh", "synthetic": True, "note": "macOS TTS (Meijia); 繁体中文短句"},
    {"id": "zh_tw_2", "language": "zh", "synthetic": True, "note": "macOS TTS (Meijia); 繁体中文中等长度"},
]

manifest = {"version": 1, "description": "", "cases": []}
if os.path.exists(manifest_path):
    try:
        manifest = json.loads(open(manifest_path).read())
    except:
        pass

existing = {c.get("id") for c in manifest.get("cases", [])}
added = 0
for c in cases:
    if c["id"] not in existing:
        manifest.setdefault("cases", []).append(c)
        existing.add(c["id"])
        added += 1

if added:
    manifest["description"] = (
        "TransFlow 识别率评测集. 英文来自 LibriSpeech/JFK/TTS, 中文来自 AISHELL-1/TTS. "
        "synthetic=true 的 case 不计入代表性 WER，但用于验证识别率正确性。"
    )
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"\n✓ manifest.json: +{added} cases (total {len(manifest['cases'])})")
else:
    print("\n✓ manifest.json: all cases already present")
PYEOF

echo ""
echo "Done! Next: xcodebuild test -project TransFlow/TransFlow.xcodeproj -scheme TransFlow"
echo "  -configuration Debug -only-testing:TransFlowTests/AccuracyBenchmarks"

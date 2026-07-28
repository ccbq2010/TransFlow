#!/bin/bash
# audio-diag.sh
# 编译并运行音频诊断 — 枚举所有输入设备，对每个录制 5s，保存 WAV 到 ~/Documents/audio-diag/
# 用法：bash audio-diag.sh [seconds]
set -e

SECONDS=${1:-5}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/audio-diag.swift"
BIN="/tmp/audio-diag-bin"

echo "==> Compiling $SRC"
swiftc -O "$SRC" -framework AVFoundation -framework CoreAudio -framework AudioToolbox -o "$BIN"

echo "==> Running (record ${SECONDS}s per device — KEEP SPEAKING)"
"$BIN" "$SECONDS"

echo
echo "==> WAVs written to ~/Documents/audio-diag/"
ls -la ~/Documents/audio-diag/ 2>/dev/null
echo
echo "Listen to each WAV (afplay <path>) to confirm which device captures your voice."

#!/usr/bin/env bash
#
# make-eval-fixtures.sh — 一次性录入 TransFlow 语音识别评测集。
#
# 从你选定的真实麦克风录 N 条 utterance，每条配一个你提供的转录，
# 自动生成 eval/<id>.wav(16k mono) + eval/<id>.ref.txt，并追加到 manifest.json。
#
# 用法（在用户 macOS 本机，需 ffmpeg：brew install ffmpeg）：
#   1) 看设备：ffmpeg -f avfoundation -list_devices true -i ""
#   2) 准备 sources.tsv（制表符分隔）：  id \t language(en|zh) \t transcript
#   3) bash scripts/make-eval-fixtures.sh --device ":1" --seconds 6 --tsv eval/sources.tsv
#
# 说明：这一步必须人工（黄金转录只能人给）。录入约 10–15 条后，
#       自主测试 Agent 即可在完全离线、零人工下反复测/调。
#
set -euo pipefail

# ---- 默认值 ----
DEVICE=":default"
SECONDS=6
TSV=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVAL_DIR="$REPO_ROOT/TransFlow/TransFlowTests/Resources/eval"
MANIFEST="$EVAL_DIR/manifest.json"

# ---- 解析参数 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)  DEVICE="$2"; shift 2 ;;
    --seconds) SECONDS="$2"; shift 2 ;;
    --tsv)     TSV="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TSV" || ! -f "$TSV" ]]; then
  echo "用法: $0 --device \":1\" --seconds 6 --tsv eval/sources.tsv" >&2
  echo "sources.tsv 格式（制表符分隔）: id<TAB>language<TAB>transcript" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "❌ 未找到 ffmpeg。请先安装：brew install ffmpeg" >&2
  exit 1
fi

mkdir -p "$EVAL_DIR"

# ---- 逐行录入 ----
while IFS=$'\t' read -r id lang transcript || [[ -n "$id" ]]; do
  # 跳过空行 / # 注释行
  [[ -z "${id// }" ]] && continue
  [[ "$id" == \#* ]] && continue

  wav="$EVAL_DIR/$id.wav"
  ref="$EVAL_DIR/$id.ref.txt"

  echo "────────────────────────────────────────"
  echo "▶ [$id] ($lang) 准备录制 ${SECONDS}s …"
  echo "    请对着真实麦克风说出："
  echo "    「$transcript」"
  echo "    （设备=$DEVICE；若录坏，Ctrl-C 后重跑本行即可）"
  sleep 1
  ffmpeg -y -f avfoundation -i "$DEVICE" -t "$SECONDS" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$wav" </dev/null \
    || { echo "❌ 录制失败: $id" >&2; continue; }

  printf '%s' "$transcript" > "$ref"
  echo "✅ 已写 $wav + $ref"

  # 追加 manifest case（用 python 安全改 JSON，避免重复 id）
  python3 - "$MANIFEST" "$id" "$lang" <<'PY'
import json, sys
mfile, cid, clang = sys.argv[1], sys.argv[2], sys.argv[3]
with open(mfile) as f:
    data = json.load(f)
if any(c.get("id") == cid for c in data.get("cases", [])):
    print(f"  (manifest 已有 {cid}，跳过重复)")
else:
    data.setdefault("cases", []).append({
        "id": cid, "language": clang, "synthetic": False, "note": "人工录入"
    })
    with open(mfile, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"  + manifest 追加 case: {cid}")
PY
done < "$TSV"

echo "────────────────────────────────────────"
echo "✅ 录入完成。建议把 eval/ 下新文件 + sources.tsv 提交进仓库以便复现。"
echo "   之后跑基准（需先下载 WhisperKit large-v3-turbo 模型）："
echo "   cd TransFlow && xcodebuild test -scheme TransFlow -destination 'platform=macOS' \\"
echo "     -configuration Release -only-testing:TransFlowTests/AccuracyBenchmarks"

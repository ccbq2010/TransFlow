#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
fetch-eval-fixtures.py
======================

构建 TransFlow 识别率评测集 (TransFlow/TransFlowTests/Resources/eval/),
产出「音频 + 金标准文字」配对, 用于 WER/CER 自动评测。

数据源与策略（均经本机验证可用）:
  - 英文 : LibriSpeech test-clean (真实人声, 公有领域)
            * 优先走魔搭 ModelScope (k2-fsa/LibriSpeech) 的 `test-clean.tar.gz` (346MB),
              下载后只解压章节 1089/134686, 转成 16k 单声道 wav。
            * 回退: HuggingFace 镜像 hf-mirror.com / huggingface.co 的同名 tar 包。
            * 注意: 该仓库只提供 .tar.gz, 不提供单文件 flac, 故必须下载 tar 包再解压。
  - 中文 : macOS 自带 `say` TTS 合成 (真实普通话嗓音, 文本完美对齐, 零下载)
            * 说明: AISHELL-1 在可用镜像里要么只有 .csv 清单、要么整包 15.6GB,
              无法干净地拿到「单条音频+对应文本」配对, 故中文默认用 TTS 合成做
              流水线 CER 回归/冒烟; 若需真人普通话音频, 请用 scripts/make-eval-fixtures.sh
              配合 eval/sources.tsv 真人录音。

每个 case 产出:
  <eval>/<id>.wav      16kHz 单声道 PCM (WhisperKit 的输入格式)
  <eval>/<id>.ref.txt  黄金转录 (LibriSpeech=数据集自带文本; TTS=合成所用原文)
并在 manifest.json 追加条目。

依赖:
  - Python 3.10+（仅标准库; ModelScope 仅英文 tar 包下载时需要, 可选）
  - 系统已装 ffmpeg（TransFlow 用户环境已有 / 可 `brew install ffmpeg`）
  - 中文合成依赖 macOS `say` 命令（仅 macOS）
  - 英文下载需可访问 modelscope.cn 或 huggingface.co 镜像其一

用法:
  python3 scripts/fetch-eval-fixtures.py                 # 默认 8 条英文 + 8 条中文
  python3 scripts/fetch-eval-fixtures.py --en 10 --zh 6 # 自定义数量
  python3 scripts/fetch-eval-fixtures.py --dry-run       # 只打印, 不下载/不合成
  EVAL_SOURCE=modelscope python3 scripts/fetch-eval-fixtures.py   # 强制走魔搭
"""

import argparse
import json
import os
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
EVAL_DIR = (SCRIPT_DIR / ".." / "TransFlow" / "TransFlowTests" / "Resources" / "eval").resolve()
MANIFEST = EVAL_DIR / "manifest.json"

LIBRI_SPEAKER = "1089"
LIBRI_CHAPTER = "134686"
LIBRI_TARBALL = "test-clean.tar.gz"

# 中文合成用的内置句子 (与 eval/sources.tsv 的 zh 行一致)
ZH_SENTENCES = [
    ("zh_nihao", "你好，这是一个语音识别的测试。"),
    ("zh_tianqi", "今天上海的天气非常潮湿。"),
    ("zh_shuzi", "我的电话号码是五五二三八九零一。"),
    ("zh_daima", "请提交代码并运行构建流水线。"),
    ("zh_huiyi", "我们把会议安排在下周二下午三点。"),
    ("zh_kafei", "我想要一杯中杯的燕麦拿铁。"),
    ("zh_jishu", "我们需要优化模型的推理延迟。"),
    ("zh_yingwen", "The quick brown fox jumps over the lazy dog."),
]

# 优先中文嗓音 (macOS)。Tingting 在实测环境中可用。
ZH_VOICE_PREF = ["Tingting", "Yu", "Eddy", "Flo", "Zhao", "Mei", "Grandma"]


# ----------------------------------------------------------------------------
# 下载工具
# ----------------------------------------------------------------------------
def download_url(url: str, dest: Path, timeout: int = 120) -> bool:
    """下载单个 url 到 dest。成功返回 True。"""
    dest.parent.mkdir(parents=True, exist_ok=True)
    headers = {"User-Agent": "Mozilla/5.0 (TransFlow eval-fixture fetcher)"}
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
        if not data:
            raise ValueError("empty body")
        dest.write_bytes(data)
        return True
    except Exception as e:
        print(f"  ✗ 下载失败 {url}: {e}", file=sys.stderr)
        return False


def to_wav(src: Path, dst: Path) -> bool:
    """用 ffmpeg 把任意音频转成 16kHz 单声道 PCM wav。"""
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-i", str(src),
             "-ar", "16000", "-ac", "1", "-sample_fmt", "s16", str(dst)],
            check=True, capture_output=True,
        )
        return True
    except Exception as e:
        print(f"  ✗ ffmpeg 转换失败 {src}: {e}", file=sys.stderr)
        return False


# ----------------------------------------------------------------------------
# 英文: LibriSpeech test-clean (tar 包解压)
# ----------------------------------------------------------------------------
def _libri_tarball_path() -> Path | None:
    """拿到 test-clean.tar.gz 的本地路径: 优先 ModelScope SDK, 回退 HF 镜像直链。"""
    cache = Path("/tmp/ms_cache_eval")
    # 1) ModelScope SDK
    if os.environ.get("EVAL_SOURCE", "").lower() != "hf":
        try:
            from modelscope import snapshot_download
            local = snapshot_download(
                "k2-fsa/LibriSpeech", repo_type="dataset",
                allow_patterns=[LIBRI_TARBALL], cache_dir=str(cache),
            )
            p = Path(local) / LIBRI_TARBALL
            if p.exists():
                return p
        except Exception as e:
            print(f"  · ModelScope 不可用 ({e}); 回退 HF 镜像", file=sys.stderr)
    # 2) HF 镜像直链
    for base in ["https://hf-mirror.com", "https://huggingface.co"]:
        url = f"{base}/k2-fsa/LibriSpeech/resolve/main/{LIBRI_TARBALL}"
        dest = cache / LIBRI_TARBALL
        if download_url(url, dest, timeout=180):
            return dest
    return None


def fetch_librispeech(n: int, dry_run: bool) -> list[dict]:
    print(f"[EN] LibriSpeech test-clean  speaker={LIBRI_SPEAKER} chapter={LIBRI_CHAPTER}")
    tarball = None if dry_run else _libri_tarball_path()
    if not dry_run and not tarball:
        print("  ✗ 无法获取 test-clean.tar.gz (ModelScope/HF 均失败)", file=sys.stderr)
        return []
    chapter_prefix = f"LibriSpeech/test-clean/{LIBRI_SPEAKER}/{LIBRI_CHAPTER}/"
    # 解析 transcript
    transcript: dict[str, str] = {}
    if dry_run:
        # dry-run 用内置代表性句子占位
        sample = [
            "HE HOPED THERE WOULD BE STEW FOR DINNER TURNIPS AND CARROTS",
            "STUFF IT INTO YOU HIS BELLY COUNSELLED HIM",
            "AFTER EARLY NIGHTFALL THE YELLOW LAMPS WOULD LIGHT UP",
            "HELLO BERTIE ANY GOOD IN YOUR MIND",
            "NUMBER TEN FRESH NELLY IS WAITING ON YOU GOOD NIGHT HUSBAND",
            "THE MUSIC CAME NEARER AND HE RECALLED THE WORDS",
            "THE DULL LIGHT FELL MORE FAINTLY UPON THE PAGE",
            "A COLD LUCID INDIFFERENCE REIGNED IN HIS SOUL",
        ]
        for i, t in enumerate(sample[:n]):
            transcript[f"1089-134686-{i:04d}"] = t
    else:
        with tarfile.open(tarball) as tf:
            tn = f"{chapter_prefix}1089-134686.trans.txt"
            if tn not in tf.getnames():
                print(f"  ✗ tar 包内缺少 {tn}", file=sys.stderr)
                return []
            raw = tf.extractfile(tn).read().decode("utf-8", errors="replace")
            for line in raw.splitlines():
                line = line.strip()
                if not line:
                    continue
                utt, _, txt = line.partition(" ")
                if utt and txt:
                    transcript[utt] = txt

    utts = list(transcript.keys())[:n]
    print(f"  取到 {len(utts)} 条转录")
    done: list[dict] = []
    for utt in utts:
        wav = EVAL_DIR / f"en_{utt}.wav"
        ref = EVAL_DIR / f"en_{utt}.ref.txt"
        note = "LibriSpeech test-clean (真实人声, 公有领域)"
        if wav.exists() and ref.exists():
            print(f"  · 跳过已存在 en_{utt}")
            done.append({"id": f"en_{utt}", "language": "en", "synthetic": False, "note": note})
            continue
        if dry_run:
            print(f"  · (dry-run) 将解压 {utt}.flac -> en_{utt}.wav")
            done.append({"id": f"en_{utt}", "language": "en", "synthetic": False, "note": note})
            continue
        # 从 tar 包提取 flac 并转换
        flac_name = f"{chapter_prefix}{utt}.flac"
        try:
            with tarfile.open(tarball) as tf:
                tmp = Path("/tmp") / f"{utt}.flac"
                tf.extract(flac_name, "/tmp")
                src = Path("/tmp") / flac_name
                if not to_wav(src, wav):
                    continue
                src.unlink(missing_ok=True)
        except Exception as e:
            print(f"  ✗ 提取/转换失败 {utt}: {e}", file=sys.stderr)
            continue
        ref.write_text(transcript[utt].strip() + "\n", encoding="utf-8")
        print(f"  ✓ en_{utt}")
        done.append({"id": f"en_{utt}", "language": "en", "synthetic": False, "note": note})
    return done


# ----------------------------------------------------------------------------
# 中文: macOS `say` TTS 合成
# ----------------------------------------------------------------------------
def _pick_zh_voice() -> str | None:
    try:
        out = subprocess.run(["say", "--voice=?"], capture_output=True, text=True).stdout
    except Exception:
        return None
    for v in ZH_VOICE_PREF:
        if v in out:
            return v
    return None


def fetch_zh_tts(n: int, dry_run: bool) -> list[dict]:
    print("[ZH] macOS `say` TTS 合成 (真实普通话嗓音, 文本对齐)")
    voice = _pick_zh_voice()
    if not voice:
        print("  ✗ 系统无可用中文嗓音 (say --voice=?), 跳过中文", file=sys.stderr)
        return []
    print(f"  使用嗓音: {voice}")
    sentences = ZH_SENTENCES[:n]
    done: list[dict] = []
    for uid, text in sentences:
        wav = EVAL_DIR / f"{uid}.wav"
        ref = EVAL_DIR / f"{uid}.ref.txt"
        note = f"macOS TTS ({voice}) 合成普通话; 文本对齐, 用于 CER 回归"
        if wav.exists() and ref.exists():
            print(f"  · 跳过已存在 {uid}")
            done.append({"id": uid, "language": "zh", "synthetic": True, "note": note})
            continue
        if dry_run:
            print(f"  · (dry-run) 将合成: {uid}  «{text}»")
            done.append({"id": uid, "language": "zh", "synthetic": True, "note": note})
            continue
        aiff = Path("/tmp") / f"{uid}.aiff"
        try:
            subprocess.run(["say", "-v", voice, "-o", str(aiff), text],
                           check=True, capture_output=True)
            if not to_wav(aiff, wav):
                continue
            aiff.unlink(missing_ok=True)
        except Exception as e:
            print(f"  ✗ 合成失败 {uid}: {e}", file=sys.stderr)
            continue
        ref.write_text(text.strip() + "\n", encoding="utf-8")
        print(f"  ✓ {uid}")
        done.append({"id": uid, "language": "zh", "synthetic": True, "note": note})
    return done


# ----------------------------------------------------------------------------
# manifest 更新
# ----------------------------------------------------------------------------
def update_manifest(new_cases: list[dict]) -> None:
    if not new_cases:
        return
    manifest = {"version": 1, "description": "", "cases": []}
    if MANIFEST.exists():
        try:
            manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        except Exception:
            pass
    existing = {c.get("id") for c in manifest.get("cases", [])}
    added = 0
    for c in new_cases:
        if c["id"] in existing:
            continue
        manifest.setdefault("cases", []).append(c)
        existing.add(c["id"])
        added += 1
    if added:
        manifest["description"] = (
            "TransFlow 识别率评测集 (WER/CER). EN=LibriSpeech 真实人声; "
            "ZH=macOS TTS 合成(文本对齐, 仅回归/冒烟). 代表性仍需补充真实多人噪声场景."
        )
        MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8")
        print(f"\n✓ manifest.json 追加 {added} 条 (现有 {len(manifest['cases'])} 条)")


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="构建 TransFlow 识别率评测集 (EN 真实 / ZH TTS)")
    ap.add_argument("--en", type=int, default=8, help="英文条数 (默认 8, 真实 LibriSpeech)")
    ap.add_argument("--zh", type=int, default=8, help="中文条数 (默认 8, macOS TTS 合成)")
    ap.add_argument("--dry-run", action="store_true", help="只预览, 不下载/不合成")
    args = ap.parse_args()

    EVAL_DIR.mkdir(parents=True, exist_ok=True)

    en_cases = fetch_librispeech(args.en, args.dry_run) if args.en > 0 else []
    zh_cases = fetch_zh_tts(args.zh, args.dry_run) if args.zh > 0 else []

    if not args.dry_run:
        update_manifest(en_cases + zh_cases)

    total = len(en_cases) + len(zh_cases)
    print(f"\n完成: 英文 {len(en_cases)} 条 (真实), 中文 {len(zh_cases)} 条 (TTS 合成)"
          + (" (dry-run, 未写入)" if args.dry_run else ""))
    print("下一步: 在 App 本机跑  xcodebuild test -scheme TransFlow "
          "-only-testing:TransFlowTests/AccuracyBenchmarks")
    return 0 if total > 0 else 1


if __name__ == "__main__":
    sys.exit(main())

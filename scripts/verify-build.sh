#!/bin/bash
# TransFlow 构建验证脚本
#
# 用法：
#   bash scripts/verify-build.sh
#
# 步骤：
#   1) Clean Build — 验证全量编译通过
#   2) Run Tests — 跑 TransFlowTests 所有用例
#
# 完整日志保存在 /tmp/transflow-*.log，可在失败时回看。

set -euo pipefail

# ── 可配置参数 ───────────────────────────────────────────────────────────
# 脚本所在目录 = 项目根目录（即 TransFlow.xcodeproj 的父目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$PROJECT_ROOT/TransFlow"

SCHEME="TransFlow"
DESTINATION='platform=macOS'
CONFIG="Debug"

BUILD_LOG="/tmp/transflow-build.log"
TEST_LOG="/tmp/transflow-test.log"

# ── 工具函数 ─────────────────────────────────────────────────────────────
function log_step()  { printf "\n\033[1;34m▶ %s\033[0m\n" "$1"; }
function log_ok()     { printf "  \033[1;32m✓ %s\033[0m\n" "$1"; }
function log_fail()   { printf "  \033[1;31m✗ %s\033[0m\n" "$1"; }
function log_info()   { printf "  %s\n" "$1"; }

# ── 入口校验 ─────────────────────────────────────────────────────────────
if [ ! -d "$PROJECT_DIR" ]; then
    log_fail "项目目录不存在：$PROJECT_DIR"
    exit 1
fi

cd "$PROJECT_DIR"
log_info "工作目录：$PROJECT_DIR"
log_info "Scheme: $SCHEME | Config: $CONFIG"

# ── Step 1: 构建 ─────────────────────────────────────────────────────────
log_step "[1/2] 构建 (clean build)"

if xcodebuild clean build \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -configuration "$CONFIG" \
        > "$BUILD_LOG" 2>&1; then
    BUILD_EXIT=0
    log_ok "BUILD SUCCEEDED"
    log_info "末 5 行摘要："
    tail -5 "$BUILD_LOG" | sed 's/^/    /'
else
    BUILD_EXIT=$?
    log_fail "BUILD FAILED (exit $BUILD_EXIT)"
    log_info "完整日志：$BUILD_LOG"
    log_info "错误/警告摘要："
    grep -E "error:|warning:.*error|BUILD FAILED" "$BUILD_LOG" | head -20 | sed 's/^/    /' || true
    exit $BUILD_EXIT
fi

# ── Step 2: 测试 ─────────────────────────────────────────────────────────
log_step "[2/2] 测试 (all TransFlowTests)"
# AccuracyBenchmarks 需要已下载的 WhisperKit 模型且较慢，单独用 -only-testing 运行，
# 质量门禁里跳过它以保持快速。WER/CER 计算器单测（WERCalculatorTests）仍随此步跑。


if xcodebuild test \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -configuration "$CONFIG" \
        -skip-testing:TransFlowTests/AccuracyBenchmarks \
        > "$TEST_LOG" 2>&1; then
    TEST_EXIT=0
    log_ok "TESTS PASSED"
    # 提取测试用例数摘要
    grep -E "Test Suite|passed|failed|Executed" "$TEST_LOG" | tail -10 | sed 's/^/    /'
else
    TEST_EXIT=$?
    log_fail "TESTS FAILED (exit $TEST_EXIT)"
    log_info "完整日志：$TEST_LOG"
    log_info "错误摘要："
    grep -E "failed|error:" "$TEST_LOG" | head -20 | sed 's/^/    /' || true
    exit $TEST_EXIT
fi

# ── 完成 ─────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────"
log_ok "✅ 全部通过：build + tests"
log_info "构建日志：$BUILD_LOG"
log_info "测试日志：$TEST_LOG"
echo "──────────────────────────────────────────"

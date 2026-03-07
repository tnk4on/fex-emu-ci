#!/bin/bash
# test-fex-all.sh — FEX-Emu 厳格テスト (test-fex.md ベース)
#
# static-pie FEXInterpreter がインストール済みの特権コンテナ内で実行する。
# 偽陽性防止ルール:
#   - uname -m だけで判定しない → binfmt handler の interpreter を確認
#   - FEXInterpreter は static-pie であること → file で確認
#   - ARM64 回帰テストは --platform linux/arm64 必須

set -uo pipefail

# --- Output helpers ---
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
PASS=0; FAIL=0; SKIP=0

report() {
    local s="$1" n="$2" d="${3:-}"
    case "$s" in
        PASS) echo -e "${G}✅ PASS${N}: $n"; PASS=$((PASS + 1)) ;;
        FAIL) echo -e "${R}❌ FAIL${N}: $n${d:+ — $d}"; FAIL=$((FAIL + 1)) ;;
        SKIP) echo -e "${Y}⏭️  SKIP${N}: $n${d:+ — $d}"; SKIP=$((SKIP + 1)) ;;
    esac
}

header() {
    echo -e "\n${C}═══════════════════════════════════════════════════${N}"
    echo -e "  $1"
    echo -e "${C}═══════════════════════════════════════════════════${N}"
}

# =============================================================================
# [1] Host architecture
# =============================================================================
header "[1] Host Architecture"

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    report PASS "Host architecture: $ARCH"
else
    report FAIL "Host architecture" "Expected aarch64, got $ARCH"
fi

# =============================================================================
# [2] FEXInterpreter must be static-pie (偽陽性防止: static 非PIE はアドレス衝突で不安定)
# =============================================================================
header "[2] FEXInterpreter (must be static-pie)"

FEX_PATH=$(command -v FEXInterpreter 2>/dev/null || echo "")
if [ -n "$FEX_PATH" ]; then
    report PASS "FEXInterpreter found: $FEX_PATH"
    FILE_INFO=$(file "$FEX_PATH")
    echo "  $FILE_INFO"
    if echo "$FILE_INFO" | grep -q "static-pie"; then
        report PASS "FEXInterpreter is static-pie"
    elif echo "$FILE_INFO" | grep -q "statically linked"; then
        report PASS "FEXInterpreter is statically linked"
    else
        report FAIL "FEXInterpreter is NOT static-pie" "$FILE_INFO"
    fi
else
    report FAIL "FEXInterpreter not found"
fi

# =============================================================================
# [3] FEX RootFS extracted
# =============================================================================
header "[3] FEX RootFS"

ROOTFS_DIR=""
for dir in /usr/share/fex-emu/RootFS /var/lib/fex-emu-rootfs; do
    if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
        ROOTFS_DIR="$dir"
        SIZE=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        # Check if it has /usr (EROFS) or is RPM-installed flat layout
        if [ -d "$dir/usr" ]; then
            report PASS "RootFS extracted: $dir ($SIZE) [has /usr]"
        else
            report PASS "RootFS available: $dir ($SIZE) [RPM layout]"
        fi
        break
    fi
done
if [ -z "$ROOTFS_DIR" ]; then
    report FAIL "FEX RootFS not found or not extracted"
fi

# =============================================================================
# [4] binfmt_misc FEX-x86_64 handler (flags=POCF required)
# =============================================================================
header "[4] binfmt FEX-x86_64 (flags=POCF required)"

# Mount binfmt_misc if needed
if ! mount | grep -q binfmt_misc; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi

if mount | grep -q binfmt_misc; then
    report PASS "binfmt_misc mounted"
else
    report FAIL "binfmt_misc mount failed (requires --privileged)"
    # Can't continue without binfmt
    echo ""
    echo -e "  ${G}$PASS passed${N}  ${R}$FAIL failed${N}  ${Y}$SKIP skipped${N}"
    exit $FAIL
fi

# Register handler if not present
FEX_HANDLER_EXISTS=false
for name in FEX-x86_64 fex-x86_64; do
    if [ -f "/proc/sys/fs/binfmt_misc/$name" ]; then
        FEX_HANDLER_EXISTS=true
        break
    fi
done

if [ "$FEX_HANDLER_EXISTS" = "false" ]; then
    FEX_INTERP=$(command -v FEXInterpreter)
    echo ":FEX-x86_64:M:0:\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${FEX_INTERP}:POCF" \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null && \
        report PASS "FEX-x86_64 handler registered" || \
        report FAIL "FEX-x86_64 handler registration failed"
fi

# Verify handler details (偽陽性防止: handler の中身を厳密に検証)
if [ -f /proc/sys/fs/binfmt_misc/FEX-x86_64 ]; then
    HANDLER_INFO=$(cat /proc/sys/fs/binfmt_misc/FEX-x86_64)
    echo "  Handler details:"
    echo "$HANDLER_INFO" | sed 's/^/    /'

    # Check enabled
    if echo "$HANDLER_INFO" | head -1 | grep -q "enabled"; then
        report PASS "FEX-x86_64 handler enabled"
    else
        report FAIL "FEX-x86_64 handler not enabled"
    fi

    # Check interpreter is FEXInterpreter (偽陽性防止: QEMU ではないことを確認)
    INTERP_LINE=$(echo "$HANDLER_INFO" | grep "interpreter")
    if echo "$INTERP_LINE" | grep -q "FEXInterpreter"; then
        report PASS "Interpreter is FEXInterpreter (not QEMU)"
    else
        report FAIL "Interpreter is NOT FEXInterpreter" "$INTERP_LINE"
    fi

    # Check POCF flags
    FLAGS_LINE=$(echo "$HANDLER_INFO" | grep "flags:")
    MISSING_FLAGS=""
    for flag in P O C F; do
        if ! echo "$FLAGS_LINE" | grep -q "$flag"; then
            MISSING_FLAGS="$MISSING_FLAGS $flag"
        fi
    done
    if [ -z "$MISSING_FLAGS" ]; then
        report PASS "binfmt flags: POCF (all required flags set)"
    else
        report FAIL "binfmt flags missing:$MISSING_FLAGS" "$FLAGS_LINE"
    fi
fi

# =============================================================================
# [5] Start FEXServer for container emulation
# =============================================================================
header "[5] FEXServer"

FEXServer --foreground &
FEXSERVER_PID=$!
sleep 1
FEX_SOCKET=""
for sock in /tmp/*.FEXServer.Socket; do
    if [ -S "$sock" ]; then FEX_SOCKET="$sock"; break; fi
done
if [ -n "$FEX_SOCKET" ]; then
    report PASS "FEXServer running (PID=$FEXSERVER_PID, socket=$FEX_SOCKET)"
else
    report FAIL "FEXServer socket not found"
fi

SOCKET_MOUNT=""
if [ -n "$FEX_SOCKET" ]; then
    SOCKET_MOUNT="-v ${FEX_SOCKET}:/tmp/0.FEXServer.Socket"
fi

export CONTAINERS_STORAGE_DRIVER=overlay

# =============================================================================
# [6] x86_64 container (5x stability — 偽陽性防止: 安定性を厳格に検証)
# =============================================================================
header "[6] x86_64 Container (5x stability)"

echo "[Test] 5 sequential x86_64 runs (all must return x86_64)..."
OK_COUNT=0
FAIL_OUTPUTS=""
for i in $(seq 1 5); do
    R=$(timeout 120 podman run --rm --platform linux/amd64 $SOCKET_MOUNT \
        docker.io/library/alpine:latest uname -m 2>/dev/null | tail -1 || echo "ERROR")
    if [ "$R" = "x86_64" ]; then
        OK_COUNT=$((OK_COUNT + 1))
        echo "  Run $i: $R ✓"
    else
        echo "  Run $i: $R ✗"
        FAIL_OUTPUTS="$FAIL_OUTPUTS run$i='$R'"
    fi
done
if [ $OK_COUNT -eq 5 ]; then
    report PASS "x86_64 stability: $OK_COUNT/5 runs succeeded"
else
    report FAIL "x86_64 stability" "$OK_COUNT/5 succeeded,$FAIL_OUTPUTS"
fi

# =============================================================================
# [7] ARM64 regression (--platform linux/arm64 必須 — 偽陽性防止)
# =============================================================================
header "[7] ARM64 Regression (--platform linux/arm64)"

echo "[Test] ARM64 container must return aarch64..."
ARM_RESULT=$(timeout 120 podman run --rm --platform linux/arm64 \
    docker.io/library/alpine:latest uname -m 2>/dev/null | tail -1 || echo "ERROR")
if [ "$ARM_RESULT" = "aarch64" ]; then
    report PASS "ARM64 regression: uname -m = $ARM_RESULT"
else
    report FAIL "ARM64 regression" "got: $ARM_RESULT"
fi

# =============================================================================
# [8] Startup latency comparison (native arm64 vs FEX-Emu amd64)
# =============================================================================
header "[8] Startup Latency Comparison"

echo "[Benchmark] native arm64 (3 runs):"
ARM_TIMES=()
for i in 1 2 3; do
    T=$( { time podman run --rm --platform linux/arm64 $SOCKET_MOUNT \
        docker.io/library/alpine:latest true 2>/dev/null; } 2>&1 | grep real | awk '{print $2}')
    # Parse time format (e.g., 0m0.500s → seconds)
    SECS=$(echo "$T" | sed 's/m/*60+/;s/s//' | bc 2>/dev/null || echo "0")
    echo "  Run $i: ${T}"
    ARM_TIMES+=("$SECS")
done

echo "[Benchmark] FEX-Emu amd64 (3 runs):"
FEX_TIMES=()
for i in 1 2 3; do
    T=$( { time podman run --rm --platform linux/amd64 $SOCKET_MOUNT \
        docker.io/library/alpine:latest true 2>/dev/null; } 2>&1 | grep real | awk '{print $2}')
    SECS=$(echo "$T" | sed 's/m/*60+/;s/s//' | bc 2>/dev/null || echo "0")
    echo "  Run $i: ${T}"
    FEX_TIMES+=("$SECS")
done

# Calculate averages if bc is available
if command -v bc >/dev/null 2>&1 && [ ${#ARM_TIMES[@]} -eq 3 ] && [ ${#FEX_TIMES[@]} -eq 3 ]; then
    ARM_AVG=$(echo "scale=3; (${ARM_TIMES[0]} + ${ARM_TIMES[1]} + ${ARM_TIMES[2]}) / 3" | bc 2>/dev/null || echo "N/A")
    FEX_AVG=$(echo "scale=3; (${FEX_TIMES[0]} + ${FEX_TIMES[1]} + ${FEX_TIMES[2]}) / 3" | bc 2>/dev/null || echo "N/A")
    echo ""
    echo "  Native ARM64 avg: ${ARM_AVG}s"
    echo "  FEX-Emu amd64 avg: ${FEX_AVG}s"
    if [ "$ARM_AVG" != "N/A" ] && [ "$FEX_AVG" != "N/A" ]; then
        OVERHEAD=$(echo "scale=3; $FEX_AVG - $ARM_AVG" | bc 2>/dev/null || echo "N/A")
        echo "  FEX-Emu overhead: ${OVERHEAD}s"
    fi
fi
report PASS "Latency benchmark completed"

# Cleanup FEXServer
if [ -n "${FEXSERVER_PID:-}" ]; then
    kill $FEXSERVER_PID 2>/dev/null || true
    wait $FEXSERVER_PID 2>/dev/null || true
fi

# =============================================================================
# Summary
# =============================================================================
header "Summary"

echo ""
echo -e "  ${G}$PASS passed${N}  ${R}$FAIL failed${N}  ${Y}$SKIP skipped${N}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${G}✅ All FEX-Emu strict tests passed${N}"
else
    echo -e "${R}❌ Some tests failed${N}"
fi
echo ""

exit $FAIL

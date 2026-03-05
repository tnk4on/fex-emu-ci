#!/bin/bash
# test-fex-all.sh — Tier 1 + Tier 2 FEX-Emu 統合テスト
#
# static-pie FEXInterpreter がインストール済みの特権コンテナ内で実行する。
#
# Tier 1: FEX-Emu インストール検証 + 直接 x86_64 実行
# Tier 2: binfmt_misc 登録 + Podman x86_64 コンテナテスト

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
# Tier 1: FEX-Emu インストール検証
# =============================================================================
header "Tier 1: FEX-Emu Installation Verification"

# 1-1: Host architecture
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    report PASS "Host architecture: $ARCH"
else
    report FAIL "Host architecture" "Expected aarch64, got $ARCH"
fi

# 1-2: OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    report PASS "OS: $PRETTY_NAME"
else
    report FAIL "Cannot identify OS"
fi

# 1-3: FEXInterpreter binary
FEX_PATH=$(command -v FEXInterpreter 2>/dev/null || echo "")
if [ -n "$FEX_PATH" ]; then
    report PASS "FEXInterpreter found: $FEX_PATH"
else
    report FAIL "FEXInterpreter not found"
fi

# 1-4: FEXInterpreter static-pie check
if [ -n "$FEX_PATH" ]; then
    FILE_INFO=$(file "$FEX_PATH")
    if echo "$FILE_INFO" | grep -q "static-pie"; then
        report PASS "FEXInterpreter is static-pie"
    elif echo "$FILE_INFO" | grep -q "statically linked"; then
        report PASS "FEXInterpreter is statically linked"
    else
        report FAIL "FEXInterpreter is NOT static-pie" "$FILE_INFO"
    fi
fi

# 1-5: FEX RootFS
ROOTFS_DIR=""
for dir in /usr/share/fex-emu/RootFS /var/lib/fex-emu-rootfs; do
    if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
        ROOTFS_DIR="$dir"
        SIZE=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        report PASS "RootFS: $dir ($SIZE)"
        break
    fi
done
if [ -z "$ROOTFS_DIR" ]; then
    report FAIL "FEX RootFS not found"
fi

# 1-6: x86_64 直接実行
if [ -n "$FEX_PATH" ]; then
    X86_BINS=(
        "/usr/share/fex-emu/RootFS/usr/bin/uname"
        "/var/lib/fex-emu-rootfs/usr/bin/uname"
    )
    X86_BIN=""
    for bin in "${X86_BINS[@]}"; do
        if [ -x "$bin" ]; then X86_BIN="$bin"; break; fi
    done

    if [ -n "$X86_BIN" ]; then
        RESULT=$("$FEX_PATH" "$X86_BIN" -m 2>&1 || echo "ERROR")
        if [ "$RESULT" = "x86_64" ]; then
            report PASS "Direct x86_64 execution: uname -m = $RESULT"
        else
            report FAIL "Direct x86_64 execution" "got: $RESULT"
        fi
    else
        report SKIP "Direct x86_64 execution" "No x86_64 uname binary found"
    fi
else
    report SKIP "Direct x86_64 execution" "FEXInterpreter not available"
fi

# =============================================================================
# Tier 2: binfmt_misc + Podman コンテナテスト
# =============================================================================
header "Tier 2: binfmt_misc + Podman Container Tests"

# 2-1: binfmt_misc mount
if ! mount | grep -q binfmt_misc; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi
if mount | grep -q binfmt_misc; then
    report PASS "binfmt_misc mounted"
else
    report FAIL "binfmt_misc mount failed (requires --privileged)"
    echo ""
    echo -e "  ${G}$PASS passed${N}  ${R}$FAIL failed${N}  ${Y}$SKIP skipped${N}"
    exit $FAIL
fi

# 2-2: FEX handler registration
FEX_HANDLER_EXISTS=false
for name in FEX-x86_64 fex-x86_64; do
    if [ -f "/proc/sys/fs/binfmt_misc/$name" ]; then
        FEX_HANDLER_EXISTS=true
        report PASS "FEX binfmt handler already registered: $name"
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

# 2-3: Handler verification
if [ -f /proc/sys/fs/binfmt_misc/FEX-x86_64 ]; then
    STATUS=$(head -1 /proc/sys/fs/binfmt_misc/FEX-x86_64)
    if echo "$STATUS" | grep -q "enabled"; then
        report PASS "FEX-x86_64 handler enabled"
    else
        report FAIL "FEX-x86_64 handler not enabled" "$STATUS"
    fi

    FLAGS=$(grep "flags:" /proc/sys/fs/binfmt_misc/FEX-x86_64 || echo "")
    if echo "$FLAGS" | grep -q "F"; then
        report PASS "binfmt F flag set (fix-binary)"
    else
        report SKIP "binfmt F flag" "Not set"
    fi
fi

# 2-4: Podman x86_64 container
export CONTAINERS_STORAGE_DRIVER=overlay
echo ""
echo "[Test] x86_64 container (--platform linux/amd64)..."
TMPOUT=$(mktemp); TMPERR=$(mktemp)
timeout 120 podman run --rm --platform linux/amd64 \
    docker.io/library/alpine:latest uname -m >"$TMPOUT" 2>"$TMPERR" || true
RESULT=$(tail -1 "$TMPOUT")
if [ -n "$(cat $TMPERR)" ]; then
    echo "  stderr (last 5):"
    tail -5 "$TMPERR" | sed 's/^/    /'
fi
rm -f "$TMPOUT" "$TMPERR"
if [ "$RESULT" = "x86_64" ]; then
    report PASS "x86_64 container: uname -m = $RESULT"
else
    report FAIL "x86_64 container" "stdout='$RESULT'"
fi

# 2-5: ARM64 regression
echo "[Test] ARM64 regression (--platform linux/arm64)..."
ARM_RESULT=$(timeout 120 podman run --rm --platform linux/arm64 \
    docker.io/library/alpine:latest uname -m 2>/dev/null | tail -1 || echo "ERROR")
if [ "$ARM_RESULT" = "aarch64" ]; then
    report PASS "ARM64 regression: uname -m = $ARM_RESULT"
else
    report FAIL "ARM64 regression" "got: $ARM_RESULT"
fi

# 2-6: Stability (3 runs)
echo "[Test] Stability (3 sequential x86_64 runs)..."
OK_COUNT=0
for i in $(seq 1 3); do
    R=$(timeout 60 podman run --rm --platform linux/amd64 \
        docker.io/library/alpine:latest uname -m 2>/dev/null | tail -1 || echo "ERROR")
    if [ "$R" = "x86_64" ]; then OK_COUNT=$((OK_COUNT + 1)); fi
done
if [ $OK_COUNT -eq 3 ]; then
    report PASS "Stability: $OK_COUNT/3 x86_64 runs succeeded"
else
    report FAIL "Stability" "$OK_COUNT/3 runs succeeded"
fi

# =============================================================================
# Summary
# =============================================================================
header "Summary"

echo ""
echo -e "  ${G}$PASS passed${N}  ${R}$FAIL failed${N}  ${Y}$SKIP skipped${N}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${G}✅ All FEX-Emu tests passed${N}"
else
    echo -e "${R}❌ Some tests failed${N}"
fi
echo ""

exit $FAIL

#!/bin/bash
# build-kernel.sh — TSO-patched kernel RPM builder using Fedora kernel SRPM
# Same build method as the build server (rpmbuild + kernel.spec)
set -euo pipefail

FEDORA_VERSION="${FEDORA_VERSION:-43}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/patches"

echo "=== TSO Kernel RPM Build (Fedora SRPM method) ==="
echo "Fedora: ${FEDORA_VERSION}"

# 1. Install build dependencies
echo "=== Installing build tools ==="
dnf install -y --setopt=install_weak_deps=false \
    rpm-build dnf-plugins-core git \
    && dnf clean all

# 2. Download Fedora kernel SRPM
echo "=== Downloading Fedora kernel SRPM ==="
cd /tmp
dnf download --source kernel
SRPM=$(ls kernel-*.src.rpm | head -1)
echo "Downloaded: ${SRPM}"

# 3. Install SRPM (populates ~/rpmbuild/)
echo "=== Installing SRPM ==="
rpm -i "${SRPM}"
KERNEL_VERSION=$(rpm -qp --queryformat '%{VERSION}' "${SRPM}")
KERNEL_RELEASE=$(rpm -qp --queryformat '%{RELEASE}' "${SRPM}")
echo "Kernel version: ${KERNEL_VERSION}-${KERNEL_RELEASE}"

# 4. Install build dependencies from spec
# Disable sub-packages not needed for TSO kernel (core/modules/devel only)
# - debuginfo/debug: massive debug RPMs exceed CI runner resources
# - bpftools/selftests: compilation errors in CI (iou-zcrx.c header mismatch)
# - perf/tools/doc: not needed for kernel deployment
echo "=== Installing kernel build dependencies ==="
dnf builddep -y --spec ~/rpmbuild/SPECS/kernel.spec \
    --define "buildid .tso" \
    --without debuginfo \
    --without debug \
    --without bpftools \
    --without selftests \
    --without perf \
    --without tools \
    --without doc

# 5. Copy TSO patches to SOURCES
echo "=== Adding TSO patches ==="
cp "${PATCH_DIR}"/000*.patch ~/rpmbuild/SOURCES/
ls -la ~/rpmbuild/SOURCES/000*.patch

# 6. Patch kernel.spec to include TSO patches
echo "=== Patching kernel.spec ==="
SPEC=~/rpmbuild/SPECS/kernel.spec

# Add Patch9001-9005 definitions after the last existing Patch line
LAST_PATCH_LINE=$(grep -n '^Patch[0-9]' "${SPEC}" | tail -1 | cut -d: -f1)
sed -i "${LAST_PATCH_LINE} a\\
Patch9001: 0001-prctl-Introduce-PR_-SET-GET-_MEM_MODEL.patch\\
Patch9002: 0002-arm64-Implement-PR_-GET-SET-_MEM_MODEL-for-always-TS.patch\\
Patch9003: 0003-arm64-Introduce-scaffolding-to-add-ACTLR_EL1-to-thre.patch\\
Patch9004: 0004-arm64-Implement-Apple-IMPDEF-TSO-memory-model-contro.patch\\
Patch9005: 0005-KVM-arm64-Expose-TSO-capability-to-guests-and-contex.patch" "${SPEC}"

# Add ApplyOptionalPatch lines after the last existing ApplyOptionalPatch
LAST_APPLY_LINE=$(grep -n 'ApplyOptionalPatch' "${SPEC}" | tail -1 | cut -d: -f1)
sed -i "${LAST_APPLY_LINE} a\\
ApplyOptionalPatch 0001-prctl-Introduce-PR_-SET-GET-_MEM_MODEL.patch\\
ApplyOptionalPatch 0002-arm64-Implement-PR_-GET-SET-_MEM_MODEL-for-always-TS.patch\\
ApplyOptionalPatch 0003-arm64-Introduce-scaffolding-to-add-ACTLR_EL1-to-thre.patch\\
ApplyOptionalPatch 0004-arm64-Implement-Apple-IMPDEF-TSO-memory-model-contro.patch\\
ApplyOptionalPatch 0005-KVM-arm64-Expose-TSO-capability-to-guests-and-contex.patch" "${SPEC}"

echo "Spec patched. Verifying:"
grep -n 'Patch900\|0001-prctl\|0005-KVM' "${SPEC}"

# 7. Add TSO Kconfig options to all aarch64 config files
# Fedora's %prep validates that all new Kconfig options are explicitly set
echo "=== Setting TSO Kconfig options in config files ==="
for cfg in ~/rpmbuild/SOURCES/kernel-aarch64*.config; do
    echo "  Updating: $(basename $cfg)"
    echo "CONFIG_ARM64_MEMORY_MODEL_CONTROL=y" >> "$cfg"
    echo "CONFIG_ARM64_ACTLR_STATE=y" >> "$cfg"
done

# 7. Build kernel RPMs
echo "=== Building kernel RPMs ==="
echo "Disk space before build:"
df -h /

rpmbuild -bb \
    --define "buildid .tso" \
    --without debuginfo \
    --without debug \
    --without bpftools \
    --without selftests \
    --without perf \
    --without tools \
    --without doc \
    --target aarch64 \
    "${SPEC}" 2>&1

echo "Disk space after build:"
df -h /

# 8. Collect output RPMs
echo "=== Collecting RPM packages ==="
mkdir -p "${OUTPUT_DIR}"
find ~/rpmbuild/RPMS/aarch64/ -name "kernel*.rpm" ! -name "*debug*" -exec cp {} "${OUTPUT_DIR}/" \;
ls -lh "${OUTPUT_DIR}/"

echo "=== Kernel RPM build complete ==="

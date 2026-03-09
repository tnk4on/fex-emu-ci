#!/bin/bash
# build-kernel.sh — TSO-patched kernel RPM builder for GitHub Actions
# Runs inside a Fedora container on ubuntu-24.04-arm runner
set -euo pipefail

KERNEL_BRANCH="${KERNEL_BRANCH:-bits/220-tso}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/AsahiLinux/linux.git}"
FEDORA_VERSION="${FEDORA_VERSION:-43}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== TSO Kernel RPM Build ==="
echo "Branch: ${KERNEL_BRANCH}"
echo "Fedora: ${FEDORA_VERSION}"

# 1. Install build dependencies
echo "=== Installing build dependencies ==="
dnf install -y --setopt=install_weak_deps=false \
    gcc make flex bison bc elfutils-libelf-devel \
    openssl openssl-devel perl dwarves \
    rpm-build rsync kmod hostname \
    && dnf clean all

# 2. Clone kernel source (shallow)
echo "=== Cloning kernel source ==="
git clone --depth 1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" /src/linux
cd /src/linux

KERNEL_VERSION=$(make kernelversion)
echo "Kernel version: ${KERNEL_VERSION}"

# 3. Get Fedora kernel config as base
echo "=== Fetching Fedora kernel config ==="
if [ -f /boot/config-$(uname -r) ]; then
    cp /boot/config-$(uname -r) .config
else
    # Download Fedora kernel config from koji
    KOJI_URL="https://kojipkgs.fedoraproject.org/packages/kernel/${KERNEL_VERSION}/200.fc${FEDORA_VERSION}/data/arch_configs/kernel-aarch64-fedora.config"
    if curl -fsSL -o .config "${KOJI_URL}" 2>/dev/null; then
        echo "Downloaded Fedora config from koji"
    else
        echo "Koji config not available, using running kernel config"
        zcat /proc/config.gz > .config 2>/dev/null || make defconfig
    fi
fi

# 4. Enable TSO Kconfig options
echo "=== Enabling TSO kernel options ==="
scripts/config --enable CONFIG_ARM64_MEMORY_MODEL_CONTROL
scripts/config --enable CONFIG_ARM64_ACTLR_STATE
# Ensure KVM support is enabled
scripts/config --enable CONFIG_KVM
scripts/config --enable CONFIG_KVM_ARM_HOST

# 5. Update config with new options
make olddefconfig

# Verify TSO options
echo "=== Verifying TSO config ==="
grep -E 'ARM64_MEMORY_MODEL_CONTROL|ARM64_ACTLR_STATE' .config

# 6. Build kernel RPM packages
echo "=== Building kernel RPM packages ==="
# Use make rpm-pkg for direct RPM generation from kernel source
# Limit jobs to avoid OOM on constrained environments
JOBS=$(nproc)
echo "Building with ${JOBS} parallel jobs"
make -j${JOBS} rpm-pkg \
    LOCALVERSION="" \
    KDEB_PKGVERSION="${KERNEL_VERSION}-1" \
    2>&1 | tail -20

# 7. Collect output RPMs
echo "=== Collecting RPM packages ==="
mkdir -p "${OUTPUT_DIR}"
find /root/rpmbuild/RPMS/aarch64/ -name "kernel*.rpm" -exec cp {} "${OUTPUT_DIR}/" \;
ls -lh "${OUTPUT_DIR}/"

echo "=== Kernel RPM build complete ==="

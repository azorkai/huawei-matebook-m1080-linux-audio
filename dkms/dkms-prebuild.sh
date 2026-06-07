#!/usr/bin/env bash
#
# DKMS PRE_BUILD hook for matebook-m1080-audio.
#
# DKMS runs this from the module's build directory with the target kernel
# version as $1. It fetches the matching mainline kernel source, applies the
# M1080 quirk patches, prepares the build tree against the *installed* kernel's
# config + symbols, and pins UTS_RELEASE so the resulting .ko loads cleanly.
#
# The kernel tarball is cached under /var/cache so repeated builds (and
# different module versions) don't re-download it.

set -euo pipefail

kernelver="${1:?usage: dkms-prebuild.sh <kernelver>}"
base="${kernelver%%-*}"          # e.g. 7.0.10
major="${base%%.*}"              # e.g. 7

log() { echo "[m1080] $*"; }

cache="/var/cache/matebook-m1080-audio"
mkdir -p "$cache"
tarball="$cache/linux-$base.tar.xz"
url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-$base.tar.xz"

if [ ! -s "$tarball" ]; then
    log "downloading kernel source $base from kernel.org ..."
    curl -fL --retry 3 --retry-delay 2 -o "$tarball.partial" "$url"
    mv "$tarball.partial" "$tarball"
fi

log "extracting source ..."
rm -rf ksrc
mkdir ksrc
tar xf "$tarball" -C ksrc --strip-components=1

log "applying M1080 quirk patches ..."
for p in patches/*.patch; do
    patch -p1 -d ksrc < "$p"
done

cd ksrc

# Use the *target* kernel's own config so the module ABI lines up. Fall back to
# the running kernel's /proc/config.gz only if the headers package is missing it.
if [ -r "/lib/modules/$kernelver/build/.config" ]; then
    log "using /lib/modules/$kernelver/build/.config"
    cp "/lib/modules/$kernelver/build/.config" .config
elif [ -r /proc/config.gz ]; then
    log "falling back to /proc/config.gz"
    zcat /proc/config.gz > .config
else
    log "ERROR: no kernel config available for $kernelver" >&2
    exit 1
fi

# Reuse the installed kernel's symbol CRCs so the modules are ABI-compatible
# without rebuilding the whole kernel.
if [ ! -r "/lib/modules/$kernelver/build/Module.symvers" ]; then
    log "ERROR: Module.symvers missing — install the kernel headers for $kernelver" >&2
    exit 1
fi
cp "/lib/modules/$kernelver/build/Module.symvers" .

# Match the toolchain the kernel was actually built with. CachyOS (and some
# other distros) build with Clang/LLD; mainline Arch uses GCC. DKMS appends the
# same LLVM=1 to its MAKE step when CONFIG_CC_IS_CLANG is set, so every stage
# here has to agree or the prepared tree carries flags the other compiler
# rejects (e.g. clang chokes on -mrecord-mcount).
llvm_flag=()
if grep -q '^CONFIG_CC_IS_CLANG=y' .config; then
    llvm_flag=(LLVM=1)
    log "kernel built with Clang/LLD — using LLVM=1"
else
    log "kernel built with GCC"
fi

log "preparing build tree ..."
make "${llvm_flag[@]}" olddefconfig >/dev/null
make "${llvm_flag[@]}" -j"$(nproc)" modules_prepare >/dev/null

# Pin vermagic to the exact target so modprobe accepts the module unforced.
echo "#define UTS_RELEASE \"$kernelver\"" > include/generated/utsrelease.h

log "prebuild complete for $kernelver"

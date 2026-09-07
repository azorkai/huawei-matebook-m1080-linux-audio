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
# different module versions) don't re-download it. Source fetching, including
# mirror fallback and offline recovery, lives in lib/kernel-source.sh.

set -euo pipefail

kernelver="${1:?usage: dkms-prebuild.sh <kernelver>}"
base="${kernelver%%-*}"          # e.g. 7.0.10

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/kernel-source.sh
source "$here/lib/kernel-source.sh"

cache="${M1080_CACHE:-/var/cache/matebook-m1080-audio}"

m1080_fetch_source "$base" "$cache"
src_version="$M1080_TARBALL_VERSION"

m1080_log "extracting linux-$src_version source ..."
rm -rf ksrc
mkdir ksrc
tar xf "$M1080_TARBALL" -C ksrc --strip-components=1

m1080_log "applying M1080 quirk patches ..."
for p in "$here"/patches/*.patch; do
    patch -p1 -d ksrc < "$p"
done

cd ksrc

# Use the *target* kernel's own config so the module ABI lines up. Fall back to
# the running kernel's /proc/config.gz only if the headers package is missing it.
if [ -r "/lib/modules/$kernelver/build/.config" ]; then
    m1080_log "using /lib/modules/$kernelver/build/.config"
    cp "/lib/modules/$kernelver/build/.config" .config
elif [ -r /proc/config.gz ]; then
    m1080_log "falling back to /proc/config.gz"
    zcat /proc/config.gz > .config
else
    m1080_log "ERROR: no kernel config available for $kernelver" >&2
    exit 1
fi

# Reuse the installed kernel's symbol CRCs so the modules are ABI-compatible
# without rebuilding the whole kernel.
if [ ! -r "/lib/modules/$kernelver/build/Module.symvers" ]; then
    m1080_log "ERROR: Module.symvers missing — install the kernel headers for $kernelver" >&2
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
    m1080_log "kernel built with Clang/LLD — using LLVM=1"
else
    m1080_log "kernel built with GCC"
fi

m1080_log "preparing build tree ..."
make "${llvm_flag[@]}" olddefconfig >/dev/null
make "${llvm_flag[@]}" -j"$(nproc)" modules_prepare >/dev/null

# Pin vermagic to the exact target so modprobe accepts the module unforced.
echo "#define UTS_RELEASE \"$kernelver\"" > include/generated/utsrelease.h

m1080_log "prebuild complete for $kernelver (source linux-$src_version)"

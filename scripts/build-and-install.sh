#!/usr/bin/env bash
#
# Build and install the M1080 audio quirk modules for the running kernel.
#
# This is the manual fallback. The recommended path is scripts/install-dkms.sh,
# which does the same thing automatically on every kernel upgrade. Use this when
# you don't want DKMS, or to debug a build.
#
# Re-run after every kernel upgrade. ~30 seconds once the source is cached.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/patches"
WORK="${WORK:-$HOME/.cache/matebook-m1080-build}"

KVER_FULL="$(uname -r)"
KVER="${KVER_FULL%%-*}"
KMAJOR="${KVER%%.*}"

echo "Running kernel  : $KVER_FULL"
echo "Base version    : $KVER"
echo "Patches         : $PATCH_DIR"
echo "Work directory  : $WORK"
echo

# --- sanity checks ---------------------------------------------------------
for cmd in curl tar make bc zstd xz patch sudo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing tool: $cmd" >&2
        exit 1
    fi
done

if [ ! -d "/lib/modules/$KVER_FULL/build" ]; then
    echo "Kernel headers for $KVER_FULL not installed." >&2
    echo "Install them first (e.g. 'sudo pacman -S linux-cachyos-headers')." >&2
    exit 1
fi

KCONFIG="/lib/modules/$KVER_FULL/build/.config"
if [ ! -r "$KCONFIG" ]; then
    echo "Kernel .config missing at $KCONFIG" >&2
    exit 1
fi

# --- match the kernel's toolchain ------------------------------------------
# CachyOS and friends build with Clang/LLD; mainline Arch uses GCC. The module
# MUST be built the same way or the prepared tree carries flags the other
# compiler rejects (clang trips over -mrecord-mcount, gcc over Clang-only opts).
# This was the most common reason the old script "didn't work" for people.
LLVM_FLAG=()
if grep -q '^CONFIG_CC_IS_CLANG=y' "$KCONFIG"; then
    echo "Kernel built with Clang/LLD -> building with LLVM=1"
    LLVM_FLAG=(LLVM=1)
    for t in clang ld.lld llvm-objcopy; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "Missing tool: $t (needed for a Clang-built kernel)" >&2
            echo "Install the LLVM toolchain (e.g. 'sudo pacman -S llvm clang lld')." >&2
            exit 1
        fi
    done
else
    echo "Kernel built with GCC -> building with GCC"
    if ! command -v gcc >/dev/null 2>&1; then
        echo "Missing tool: gcc" >&2
        exit 1
    fi
fi
echo

# --- fetch matching kernel source ------------------------------------------
mkdir -p "$WORK"
cd "$WORK"

SRC_DIR="linux-$KVER"
TARBALL="linux-$KVER.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/$TARBALL"

if [ ! -d "$SRC_DIR" ]; then
    if [ ! -s "$TARBALL" ]; then
        echo "Downloading $URL ..."
        curl -fL --retry 3 --progress-bar -o "$TARBALL.partial" "$URL"
        mv "$TARBALL.partial" "$TARBALL"
    fi
    echo "Extracting $TARBALL ..."
    tar xf "$TARBALL"
fi

cd "$SRC_DIR"

# --- apply patches (idempotent) --------------------------------------------
for p in "$PATCH_DIR"/*.patch; do
    name="$(basename "$p")"
    if patch -p1 --dry-run -R --silent < "$p" >/dev/null 2>&1; then
        echo "Already applied: $name"
    elif patch -p1 --dry-run --silent < "$p" >/dev/null 2>&1; then
        echo "Applying $name"
        patch -p1 < "$p" >/dev/null
    else
        echo "ERROR: $name does not apply cleanly to linux-$KVER." >&2
        echo "The source layout may have changed; please open an issue." >&2
        exit 1
    fi
done

# --- reuse the installed kernel's config + symbol versions -----------------
echo "Using $KCONFIG"
cp "$KCONFIG" .config
cp "/lib/modules/$KVER_FULL/build/Module.symvers" .

echo "Running olddefconfig ..."
make "${LLVM_FLAG[@]}" olddefconfig >/dev/null

echo "Preparing build (modules_prepare) ..."
make "${LLVM_FLAG[@]}" -j"$(nproc)" modules_prepare >/dev/null

# Pin UTS_RELEASE so vermagic matches the installed kernel; otherwise modprobe
# refuses the module. uname -r already carries the full local suffix.
echo "#define UTS_RELEASE \"$KVER_FULL\"" > include/generated/utsrelease.h

# --- build only the two modules we care about ------------------------------
echo "Building snd-acp-config.ko and snd-acp-legacy-mach.ko ..."
make "${LLVM_FLAG[@]}" -j"$(nproc)" M=sound/soc/amd modules >/dev/null

NEW_CFG="sound/soc/amd/snd-acp-config.ko"
NEW_MACH="sound/soc/amd/acp/snd-acp-legacy-mach.ko"

for f in "$NEW_CFG" "$NEW_MACH"; do
    if [ ! -f "$f" ]; then
        echo "Build did not produce $f" >&2
        exit 1
    fi
done

# --- install with backup ---------------------------------------------------
DEST_DIR="/lib/modules/$KVER_FULL/kernel/sound/soc/amd"

install_module() {
    local src="$1"
    local dest="$2"
    echo "  -> $dest"
    if [ -f "$dest" ] && [ ! -f "$dest.bak" ]; then
        sudo cp -- "$dest" "$dest.bak"
    fi
    sudo zstd -19 -q -f -- "$src" -o "$dest.new"
    sudo mv -- "$dest.new" "$dest"
}

echo "Installing modules (sudo required):"
install_module "$NEW_CFG"  "$DEST_DIR/snd-acp-config.ko.zst"
install_module "$NEW_MACH" "$DEST_DIR/acp/snd-acp-legacy-mach.ko.zst"

echo "Running depmod ..."
sudo depmod -a

echo
echo "Verify (should print the running kernel version):"
echo "    modinfo snd_acp_legacy_mach | grep vermagic"
echo
echo "Then reboot:"
echo "    sudo systemctl reboot"

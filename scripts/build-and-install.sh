#!/usr/bin/env bash
#
# Build and install the M1080 audio quirk modules for the running kernel.
# Re-run this after every kernel upgrade. Takes about 30 seconds end-to-end.

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
for cmd in curl tar make gcc bc zstd xz patch sudo; do
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

# --- fetch matching kernel source ------------------------------------------
mkdir -p "$WORK"
cd "$WORK"

SRC_DIR="linux-$KVER"
TARBALL="linux-$KVER.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/$TARBALL"

if [ ! -d "$SRC_DIR" ]; then
    if [ ! -f "$TARBALL" ]; then
        echo "Downloading $URL ..."
        curl -fL --progress-bar -o "$TARBALL" "$URL"
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
        echo "ERROR: $name does not apply cleanly." >&2
        exit 1
    fi
done

# --- reuse the installed kernel's config + symbol versions -----------------
echo "Importing /proc/config.gz ..."
zcat /proc/config.gz > .config
cp "/lib/modules/$KVER_FULL/build/Module.symvers" .

echo "Running olddefconfig ..."
make olddefconfig >/dev/null

echo "Preparing build (modules_prepare) ..."
make -j"$(nproc)" modules_prepare >/dev/null

# Force UTS_RELEASE so vermagic embedded in the .ko matches the installed
# kernel exactly. Without this, modprobe refuses the module.
echo "#define UTS_RELEASE \"$KVER_FULL\"" > include/generated/utsrelease.h

# --- build only the two modules we care about ------------------------------
echo "Building snd-acp-config.ko and snd-acp-legacy-mach.ko ..."
make -j"$(nproc)" M=sound/soc/amd modules >/dev/null

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
    echo "  → $dest"
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
echo "Done. Verify with:"
echo "    modinfo snd_acp_legacy_mach | grep vermagic"
echo
echo "Then reboot:"
echo "    sudo systemctl reboot"

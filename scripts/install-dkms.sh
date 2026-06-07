#!/usr/bin/env bash
#
# Install the M1080 audio fix as a DKMS module. After this runs once, the fix
# is rebuilt and reinstalled automatically on every kernel upgrade — no manual
# step ever again.
#
# Requires: dkms, the kernel headers for each kernel you boot, plus the usual
# build tools (gcc, make, bc, patch, curl, tar, xz). Run as a normal user; it
# uses sudo where needed.

set -euo pipefail

NAME="matebook-m1080-audio"
VER="1.0.0"
SRC="/usr/src/$NAME-$VER"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# --- prerequisite checks ---------------------------------------------------
if ! command -v dkms >/dev/null 2>&1; then
    echo "dkms is not installed."
    echo "  Arch/CachyOS : sudo pacman -S dkms"
    echo "  Debian/Ubuntu: sudo apt install dkms"
    echo "  Fedora       : sudo dnf install dkms"
    exit 1
fi

missing=()
for cmd in gcc make bc patch curl tar xz; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing build tools: ${missing[*]}" >&2
    exit 1
fi

KVER="$(uname -r)"
if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "Kernel headers for $KVER are not installed." >&2
    echo "Install them (e.g. 'sudo pacman -S linux-cachyos-headers') and re-run." >&2
    exit 1
fi

# --- stage the DKMS source tree -------------------------------------------
echo "Staging DKMS source at $SRC ..."
sudo rm -rf "$SRC"
sudo install -d "$SRC/patches"
sudo install -m 0644 "$REPO/dkms/dkms.conf"        "$SRC/dkms.conf"
sudo install -m 0755 "$REPO/dkms/dkms-prebuild.sh" "$SRC/dkms-prebuild.sh"
sudo install -m 0644 "$REPO/patches/"*.patch       "$SRC/patches/"

# --- (re)register and build ------------------------------------------------
# Remove any stale registration of the same version first.
if sudo dkms status -m "$NAME" -v "$VER" | grep -q .; then
    echo "Removing previous DKMS registration ..."
    sudo dkms remove -m "$NAME" -v "$VER" --all || true
fi

echo "Adding to DKMS ..."
sudo dkms add -m "$NAME" -v "$VER"

echo "Building and installing for $KVER (this downloads kernel source once) ..."
sudo dkms install -m "$NAME" -v "$VER" -k "$KVER" --force

echo
echo "DKMS status:"
sudo dkms status -m "$NAME"
echo
echo "Done. Reboot to load the patched modules:"
echo "    sudo systemctl reboot"
echo
echo "From now on every kernel upgrade rebuilds this automatically."

#!/usr/bin/env bash
#
# Diagnose the M1080 audio fix on this machine and say what to do next.
#
# The failure this is built for is the quiet one: a DKMS build that failed during
# a kernel upgrade leaves the module "added" rather than "installed", the message
# scrolls past in the middle of a pacman transaction, and the speakers just stop
# working. Nothing tells you why. Run this and it will.
#
# Also the right thing to paste into an issue — it is read-only and needs no root.

set -uo pipefail

NAME="matebook-m1080-audio"
VER="1.0.0"
KVER="$(uname -r)"
BASE="${KVER%%-*}"

ok()   { echo "  [ ok ] $*"; }
warn() { echo "  [warn] $*"; }
bad()  { echo "  [FAIL] $*"; }

verdict=""
set_verdict() { [ -z "$verdict" ] && verdict="$1"; }

# Modules ship compressed and the scheme varies by distro.
module_text() {
    case "$1" in
        *.zst) zstdcat -- "$1" 2>/dev/null ;;
        *.xz)  xzcat   -- "$1" 2>/dev/null ;;
        *.gz)  zcat    -- "$1" 2>/dev/null ;;
        *)     cat     -- "$1" 2>/dev/null ;;
    esac
}

# Count matches rather than `grep -q`: with pipefail set, grep -q exits on the
# first hit, the decompressor upstream dies of SIGPIPE, and the whole pipeline
# reports failure even though the string was found. grep -c drains its input.
pipe_count() { grep -c "$1" 2>/dev/null || true; }

echo "== hardware =="
board="$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo '?')"
prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo '?')"
rev="$(cat /sys/class/dmi/id/product_version 2>/dev/null || echo '?')"
echo "  board_vendor    : $board"
echo "  product_name    : $prod"
echo "  product_version : $rev"
if [ "$prod" = "HVY-WXX9" ] && [ "$rev" = "M1080" ]; then
    ok "this is the board this repo targets"
else
    warn "not HVY-WXX9/M1080 — these patches match on those exact strings"
    warn "if your speakers are silent, open an issue with the three lines above"
fi

echo
echo "== kernel =="
echo "  running kernel  : $KVER"
if [ -d "/lib/modules/$KVER/build" ]; then
    ok "headers present at /lib/modules/$KVER/build"
else
    bad "kernel headers for $KVER are MISSING — DKMS cannot build without them"
    set_verdict "Install the headers for your kernel (e.g. sudo pacman -S linux-cachyos-headers), then re-run ./scripts/install-dkms.sh"
fi

echo
echo "== dkms =="
if ! command -v dkms >/dev/null 2>&1; then
    warn "dkms not installed (fine if you use the manual build)"
else
    status="$(dkms status -m "$NAME" -v "$VER" 2>/dev/null)"
    if [ -z "$status" ]; then
        warn "$NAME is not registered with DKMS"
        set_verdict "Run ./scripts/install-dkms.sh to install the fix permanently"
    else
        echo "$status" | sed 's/^/  /'
        if grep -q "$KVER.*installed" <<<"$status"; then
            ok "built and installed for the running kernel"
        else
            bad "registered but NOT installed for $KVER — this is why there is no sound"
            log="/var/lib/dkms/$NAME/$VER/build/make.log"
            if [ -r "$log" ]; then
                echo
                echo "  last lines of $log:"
                tail -n 12 "$log" | sed 's/^/    /'
            else
                echo "  build log not readable as this user: sudo tail -40 $log"
            fi
            set_verdict "Rebuild it: sudo dkms install -m $NAME -v $VER -k $KVER --force"
        fi
    fi
fi

echo
echo "== modules on disk =="
for m in snd_acp_config snd_acp_legacy_mach; do
    path="$(modinfo -n "$m" 2>/dev/null)"
    if [ -z "$path" ]; then
        bad "$m not found for $KVER"
        continue
    fi
    # A patched module carries the M1080 DMI string; the stock one does not.
    # That is the only check that actually proves the fix is in place.
    hits="$(module_text "$path" | strings 2>/dev/null | pipe_count 'M1080')"
    if [ "${hits:-0}" -gt 0 ]; then
        ok "$m is PATCHED  ($path)"
    else
        bad "$m is the STOCK module, no M1080 quirk  ($path)"
        set_verdict "The patched module is not installed. Run ./scripts/install-dkms.sh"
    fi
done

echo
echo "== sound card =="
cards="$(aplay -l 2>/dev/null || true)"
if grep -qi 'es83' <<<"$cards"; then
    ok "ES8316 card present:"
    grep -i 'es83' <<<"$cards" | sed 's/^/    /'
else
    bad "no ES8316 card — only these playback devices exist:"
    grep '^card' <<<"$cards" | sed 's/^/    /' || echo "    (none)"
    set_verdict "${verdict:-The quirk is not taking effect. Reboot after installing, then re-run this script}"
fi

echo
echo "== pipewire =="
if command -v wpctl >/dev/null 2>&1; then
    sinks="$(wpctl status 2>/dev/null | sed -n '/Sinks:/,/^ *[├└]/p' | grep -E '^\s*\W*\s*[0-9]+\.' || true)"
    if [ -n "$sinks" ]; then
        echo "$sinks" | sed 's/^/  /'
        if grep -q '\*.*[Ss]peaker' <<<"$sinks"; then
            ok "speakers are the default sink"
        elif grep -qi 'speaker' <<<"$sinks"; then
            warn "a speaker sink exists but is not the default"
            set_verdict "Point PipeWire at the speakers: wpctl set-default <id of the speaker sink>"
        fi
        if grep -q 'MUTED' <<<"$sinks"; then
            warn "the default sink is MUTED"
        fi
    else
        warn "no audio sinks at all"
    fi
else
    warn "wpctl not found (not using PipeWire?)"
fi

echo
echo "== verdict =="
if [ -n "$verdict" ]; then
    echo "  $verdict"
    exit 1
fi
echo "  Everything checks out. If audio is still wrong, it is a mixer/routing"
echo "  issue rather than the quirk — check your desktop's sound settings."

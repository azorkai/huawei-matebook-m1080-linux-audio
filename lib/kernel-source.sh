# shellcheck shell=bash
#
# Shared helper: obtain a kernel source tarball for a given base version.
#
# This exists because fetching the source is the single most fragile step in the
# whole fix. It runs unattended from a pacman/dpkg DKMS hook, often seconds after
# a kernel upgrade, and any hiccup — DNS not up yet, VPN mid-reconnect, kernel.org
# rate limiting — used to abort the build with a bare curl error. The module then
# stayed unbuilt and the speakers stayed silent, sometimes for weeks, because
# nobody reads the middle of a pacman transaction log.
#
# So: try several mirrors, verify what we cached is actually intact, and if the
# network is genuinely unreachable fall back to a nearby cached source in the same
# stable series rather than failing outright.
#
# Sets M1080_TARBALL to the resulting path. Sets M1080_TARBALL_VERSION to the
# version actually used, which may differ from the requested one when the
# fallback kicked in.

m1080_log() { echo "[m1080] $*"; }
m1080_warn() { echo "[m1080] WARNING: $*" >&2; }

# Integrity-check a tarball. A truncated or half-written download is worse than
# no download at all: it gets cached and then every later build fails on it.
m1080_tarball_ok() {
    local f="$1"
    [ -s "$f" ] || return 1
    xz -t -- "$f" >/dev/null 2>&1
}

# Strip a version down to its stable series: 7.1.4 -> 7.1, 7.1 -> 7.1
m1080_series() { printf '%s' "$1" | cut -d. -f1,2; }

# Pick the cached tarball closest to $1 within the same stable series. Prefers
# the newest version at or below the target, else the oldest above it.
m1080_nearest_cached() {
    local want="$1" cache="$2"
    local series below above v f
    series="$(m1080_series "$want")"

    below=""; above=""
    for f in "$cache"/linux-"$series".tar.xz "$cache"/linux-"$series".*.tar.xz; do
        [ -e "$f" ] || continue
        m1080_tarball_ok "$f" || continue
        v="$(basename "$f" .tar.xz)"; v="${v#linux-}"
        if [ "$v" = "$want" ]; then continue; fi
        if [ "$(printf '%s\n%s\n' "$v" "$want" | sort -V | head -1)" = "$v" ]; then
            # v < want: keep the largest such v
            if [ -z "$below" ] || [ "$(printf '%s\n%s\n' "$v" "$below" | sort -V | tail -1)" = "$v" ]; then
                below="$v"
            fi
        else
            # v > want: keep the smallest such v
            if [ -z "$above" ] || [ "$(printf '%s\n%s\n' "$v" "$above" | sort -V | head -1)" = "$v" ]; then
                above="$v"
            fi
        fi
    done

    if [ -n "$below" ]; then printf '%s' "$below"; return 0; fi
    if [ -n "$above" ]; then printf '%s' "$above"; return 0; fi
    return 1
}

# m1080_fetch_source <base_version> <cache_dir>
m1080_fetch_source() {
    local base="$1" cache="$2"
    local major="${base%%.*}"
    local tarball="$cache/linux-$base.tar.xz"
    local name="linux-$base.tar.xz"

    mkdir -p "$cache"

    # An operator-supplied tarball wins over everything: this is the escape hatch
    # for air-gapped machines and for anyone who just wants to pre-seed the cache.
    if [ -n "${M1080_TARBALL_OVERRIDE:-}" ]; then
        if ! m1080_tarball_ok "$M1080_TARBALL_OVERRIDE"; then
            m1080_log "ERROR: M1080_TARBALL_OVERRIDE=$M1080_TARBALL_OVERRIDE is not a readable xz archive" >&2
            return 1
        fi
        m1080_log "using operator-supplied source $M1080_TARBALL_OVERRIDE"
        M1080_TARBALL="$M1080_TARBALL_OVERRIDE"
        M1080_TARBALL_VERSION="$base"
        return 0
    fi

    # Already cached and intact.
    if m1080_tarball_ok "$tarball"; then
        m1080_log "using cached source $base"
        M1080_TARBALL="$tarball"
        M1080_TARBALL_VERSION="$base"
        return 0
    fi
    # Cached but corrupt — drop it so we retry cleanly instead of failing forever.
    if [ -e "$tarball" ]; then
        m1080_warn "cached $name is corrupt, re-downloading"
        rm -f -- "$tarball"
    fi

    # kernel.org fronts the same tree behind several names. When one is
    # unresolvable or blackholed the others usually still answer, so walk them.
    local mirrors=(
        "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/$name"
        "https://mirrors.edge.kernel.org/pub/linux/kernel/v${major}.x/$name"
        "https://www.kernel.org/pub/linux/kernel/v${major}.x/$name"
    )
    [ -n "${M1080_MIRROR:-}" ] && mirrors=("${M1080_MIRROR%/}/v${major}.x/$name" "${mirrors[@]}")

    local url
    for url in "${mirrors[@]}"; do
        m1080_log "downloading kernel source $base from ${url#https://}"
        if curl -fL --connect-timeout 15 --retry 3 --retry-delay 3 --retry-all-errors \
                -o "$tarball.partial" "$url"; then
            if m1080_tarball_ok "$tarball.partial"; then
                mv -- "$tarball.partial" "$tarball"
                M1080_TARBALL="$tarball"
                M1080_TARBALL_VERSION="$base"
                return 0
            fi
            m1080_warn "download from ${url#https://} was incomplete"
        fi
        rm -f -- "$tarball.partial"
    done

    # Every mirror failed. Rather than leave the machine silent, build from the
    # nearest source we already have in this stable series. The module ABI comes
    # from the *target* kernel's Module.symvers and .config, not from this tree,
    # and these two DMI quirk tables barely change within a series — so this
    # nearly always produces a working module.
    local fallback
    if [ "${M1080_NO_FALLBACK:-0}" != "1" ] && fallback="$(m1080_nearest_cached "$base" "$cache")"; then
        m1080_warn "kernel.org unreachable — falling back to cached linux-$fallback source"
        m1080_warn "the build targets $base; if audio misbehaves, re-run once you are online:"
        m1080_warn "  sudo dkms install -m matebook-m1080-audio -v 1.0.0 -k \$(uname -r) --force"
        M1080_TARBALL="$cache/linux-$fallback.tar.xz"
        M1080_TARBALL_VERSION="$fallback"
        return 0
    fi

    cat >&2 <<EOF
[m1080] ERROR: could not obtain kernel source $base.

  Every kernel.org mirror failed and there is no cached source for the
  $(m1080_series "$base") series to fall back on. This is a network problem on
  this machine, not a problem with the patches — check DNS/VPN first:

      curl -I https://cdn.kernel.org/

  Once you are online again, build the module with:

      sudo dkms install -m matebook-m1080-audio -v 1.0.0 -k $(uname -r) --force

  Or, on a machine with no internet access at all, download
  linux-$base.tar.xz elsewhere and pre-seed the cache:

      sudo cp linux-$base.tar.xz $cache/

EOF
    return 1
}

# Huawei MateBook (HVY-WXX9 / M1080) Linux Audio Fix

Enable the internal speakers on Huawei MateBook D laptops with the **HVY-WXX9**
board and **M1080** product revision. If you installed a modern Linux distro and
the speakers stay silent while HDMI/Bluetooth output works fine, this is the fix.

Confirmed on AMD Ryzen 5 4600H (Renoir) MateBook D16 running CachyOS, and used by
other M1080 owners on the same hardware. It applies cleanly to any current Arch /
Manjaro / EndeavourOS / Fedora / Ubuntu kernel — the change is just a DMI quirk
for the M1080 revision, nothing else.

> **TL;DR:** install DKMS once and never think about it again:
> ```bash
> git clone https://github.com/azorkai/huawei-matebook-m1080-linux-audio.git
> cd huawei-matebook-m1080-linux-audio
> ./scripts/install-dkms.sh
> sudo systemctl reboot
> ```

## Is this you?

```bash
cat /sys/class/dmi/id/product_name   # -> HVY-WXX9
cat /sys/class/dmi/id/product_version # -> M1080
aplay -l                              # only HDMI devices, no analog playback
```

If `product_version` is M1010, M1020 or M1040 instead, mainline already supports
you — update your kernel. This repo is specifically for **M1080**, which upstream
doesn't recognise yet.

## The problem

The kernel carries DMI quirks for several MateBook revisions (M1010, M1020,
M1040) across two tables:

- `sound/soc/amd/acp-config.c` — picks the legacy ACP audio backend
- `sound/soc/amd/acp/acp3x-es83xx/acp3x-es83xx.c` — loads the ES8316 codec quirk

On an **M1080** board neither table matches, so the `acp3x-es83xx` platform
device never gets a driver bound and there's no analog playback PCM. You end up
with only HDMI sinks and silent speakers.

This repo adds one more entry to each table — identical in shape to the existing
M1040 entries — so the kernel finally recognises the M1080 and exposes the
speakers. PipeWire then picks up a sink called **Audio Coprocessor Speakers**.

The two patches total 22 added lines and touch nothing else:

- [`patches/0001-...acp-config...patch`](patches/0001-ASoC-amd-acp-config-add-M1080-DMI-quirk-for-HVY-WXX9.patch)
- [`patches/0002-...acp3x-es83xx...patch`](patches/0002-ASoC-amd-acp3x-es83xx-add-M1080-DMI-quirk-for-HVY-WXX9.patch)

## Recommended: DKMS (rebuilds itself on every kernel update)

This is the right answer to *"the sound broke again after a kernel update."*
DKMS rebuilds and reinstalls the patched modules automatically whenever a new
kernel is installed — you do nothing.

**Requirements**

- `dkms`
- kernel headers for every kernel you boot (`linux-cachyos-headers`,
  `linux-headers`, `linux-lts-headers`, …)
- build tools: `gcc` **or** the LLVM toolchain (`clang lld llvm`) depending on
  how your kernel was built — the scripts detect this automatically
- `bc make patch curl tar xz zstd`

On Arch/CachyOS:

```bash
sudo pacman -S --needed dkms bc make patch curl tar xz zstd
# Clang-built kernel (CachyOS default)? also:
sudo pacman -S --needed llvm clang lld
```

**Install**

```bash
git clone https://github.com/azorkai/huawei-matebook-m1080-linux-audio.git
cd huawei-matebook-m1080-linux-audio
./scripts/install-dkms.sh
sudo systemctl reboot
```

The first build downloads the matching kernel source from kernel.org once (cached
under `/var/cache/matebook-m1080-audio`). After that, `dkms status` shows:

```
matebook-m1080-audio/1.0.0, <your-kernel>, x86_64: installed
```

and it rebuilds silently on every future kernel upgrade.

**Uninstall**

```bash
sudo dkms remove -m matebook-m1080-audio -v 1.0.0 --all
sudo systemctl reboot
```

## Alternative: one-shot manual build

If you don't want DKMS, build and install the two modules directly. You have to
re-run this after every kernel upgrade.

```bash
git clone https://github.com/azorkai/huawei-matebook-m1080-linux-audio.git
cd huawei-matebook-m1080-linux-audio
./scripts/build-and-install.sh
sudo systemctl reboot
```

The script auto-detects your kernel's compiler (GCC vs Clang/LLD), pulls the
matching kernel source, applies the patches, reuses your installed kernel's
`.config` + `Module.symvers`, builds only the two modules, and installs them with
`.bak` backups of the originals.

> **Note for CachyOS / Clang-built kernels:** the modules must be compiled with
> the *same* toolchain as the kernel. Both scripts handle this for you now — an
> earlier version always used GCC, which is why the manual build failed for some
> people on Clang-built kernels. If you hit a build error full of
> `clang: error: unknown argument` or `unsupported option '-mrecord-mcount'`,
> you're on an old copy of the script; `git pull` and retry.

## After rebooting: no sound yet?

The card is there but PipeWire may still default to HDMI. Point it at the
speakers:

```bash
wpctl status                       # find "Audio Coprocessor Speakers" id
wpctl set-default <id>             # e.g. wpctl set-default 44
```

Or just pick it in your desktop's audio settings. WirePlumber remembers the
choice across reboots. Confirm the card exists with:

```bash
aplay -l | grep -i es8316          # -> card 1: ... ES8316 HiFi-0
```

## Manual build, step by step

For the curious or for distros without the scripts:

```bash
KVER_FULL=$(uname -r)                 # e.g. 7.0.10-2-cachyos
KVER=${KVER_FULL%%-*}                 # e.g. 7.0.10
KCFG=/lib/modules/$KVER_FULL/build/.config

# toolchain: LLVM=1 only if the kernel was built with Clang
LLVM=()
grep -q '^CONFIG_CC_IS_CLANG=y' "$KCFG" && LLVM=(LLVM=1)

# 1. matching kernel source
curl -O https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz
tar xf linux-$KVER.tar.xz && cd linux-$KVER

# 2. patches (adjust the path to wherever you cloned the repo)
patch -p1 < /path/to/repo/patches/0001-*.patch
patch -p1 < /path/to/repo/patches/0002-*.patch

# 3. reuse installed kernel config + symbols
cp "$KCFG" .config
cp /lib/modules/$KVER_FULL/build/Module.symvers .
make "${LLVM[@]}" olddefconfig
make "${LLVM[@]}" -j$(nproc) modules_prepare

# 4. pin vermagic to the installed kernel
echo "#define UTS_RELEASE \"$KVER_FULL\"" > include/generated/utsrelease.h

# 5. build only the two modules
make "${LLVM[@]}" -j$(nproc) M=sound/soc/amd modules

# 6. install with backups
DEST=/lib/modules/$KVER_FULL/kernel/sound/soc/amd
sudo cp -n $DEST/snd-acp-config.ko.zst{,.bak}
sudo cp -n $DEST/acp/snd-acp-legacy-mach.ko.zst{,.bak}
sudo zstd -19 -f sound/soc/amd/snd-acp-config.ko          -o $DEST/snd-acp-config.ko.zst
sudo zstd -19 -f sound/soc/amd/acp/snd-acp-legacy-mach.ko -o $DEST/acp/snd-acp-legacy-mach.ko.zst
sudo depmod -a
sudo systemctl reboot
```

## How it works (one paragraph)

The ACP3x machine driver on AMD Renoir/Cezanne is generic — the codec, GPIO
pinout and DMIC topology are selected at probe time from DMI quirk lists.
`snd-acp-config` returns `FLAG_AMD_LEGACY` for matched entries, handing control
to the legacy ACP stack instead of SOF. Then `acp3x-es83xx` looks up its own
table and pulls in the `ES83XX_ENABLE_DMIC` flag, wiring the speaker + digital
mic DAI link. Without a matching row in **both** tables the platform device never
gets a driver, and the card never appears. We add the missing M1080 row to each.

## Upstreaming

These quirks belong in mainline so nobody needs this repo. The DMI strings differ
per unit, so a clean upstream patch wants confirmation from a couple of M1080
owners. **If this fixed your audio, please open an issue with your**
`cat /sys/class/dmi/id/{product_name,product_version,board_vendor}` **output** —
that's exactly the sign-off reviewers ask for, and it lets me send a proper
`git format-patch` to the ALSA / linux-sound list.

## Hardware confirmed

| Model                | product_name | product_version | Codec  | Status  |
|----------------------|--------------|-----------------|--------|---------|
| MateBook D16 (2022)  | HVY-WXX9     | M1080           | ES8316 | Working |

Add a row via PR if yours differs.

## License

Patches and scripts are [GPL-2.0](LICENSE), matching the kernel they target.

## Acknowledgements

The quirk structure comes straight from the upstream M1010/M1020/M1040 work by
Marian Postevca and others. This is one more row, plus the packaging to keep it
alive across kernel updates. Thanks to **@ieatcasiowatches** for confirming the
fix on a second M1080 unit and reporting the Clang build issue.

---

*Keywords: Huawei MateBook D16 no sound Linux, HVY-WXX9 audio fix, M1080 speakers
not working, AMD Renoir ES8316 codec Linux, MateBook D14 D15 D16 Ryzen audio,
CachyOS Manjaro Arch silent speakers, acp3x-es83xx M1080 DMI quirk, DKMS,
snd-acp-legacy-mach Huawei, sound breaks after kernel update.*

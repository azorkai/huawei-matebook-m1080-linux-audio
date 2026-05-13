# Huawei MateBook (HVY-WXX9 / M1080) Linux Audio Fix

Two small kernel patches that enable the internal speakers on Huawei MateBook D laptops with the **HVY-WXX9** board and **M1080** product revision. If you installed any modern Linux distribution and your speakers stay silent while HDMI/Bluetooth output works fine, this repo is probably what you're looking for.

The fix has been confirmed working on AMD Ryzen 5 4600H (Renoir) hardware running CachyOS with kernel 7.0.5, but it should apply cleanly to any current Arch / Manjaro / EndeavourOS / Fedora / Ubuntu system — the patches only add a DMI quirk for the M1080 hardware revision, nothing else.

## The problem

The mainline Linux kernel carries DMI quirks for several Huawei MateBook revisions: **M1010**, **M1020**, **M1040**. When the audio stack boots, it walks two DMI tables looking for a match — one in `sound/soc/amd/acp-config.c` (decides the audio backend flavour), and a second one in `sound/soc/amd/acp/acp3x-es83xx/acp3x-es83xx.c` (loads the codec quirk for the ES8316/ES8336 codec sitting on the AMD ACP block).

If your board reports `M1080` (which several MateBook D14/D15/D16 units from late-2022 onwards do), neither table matches. The result:

- `card1: acp` shows up with the digital microphone (`pcm0c`) but no playback PCM
- `aplay -l` lists only HDMI outputs
- Your default sink in PipeWire becomes some HDMI port
- You hear nothing from the laptop speakers

You can confirm this is your case with:

```bash
sudo dmidecode -s system-version    # should print "M1080"
cat /sys/class/dmi/id/product_name  # should print "HVY-WXX9"
```

## What this repo does

It adds one more entry to each of those two DMI tables — same shape as the existing M1010/M1020/M1040 entries — so the kernel finally recognises your laptop, registers the `acp3x-es83xx` platform driver against the ES8316 codec, and exposes a real analog playback PCM. Once that happens PipeWire automatically picks up a sink called **Audio Coprocessor Speakers** and routes audio to it.

There are exactly two patches:

- [`0001-ASoC-amd-acp-config-add-M1080-DMI-quirk-for-HVY-WXX9.patch`](patches/0001-ASoC-amd-acp-config-add-M1080-DMI-quirk-for-HVY-WXX9.patch) — 14 added lines
- [`0002-ASoC-amd-acp3x-es83xx-add-M1080-DMI-quirk-for-HVY-WXX9.patch`](patches/0002-ASoC-amd-acp3x-es83xx-add-M1080-DMI-quirk-for-HVY-WXX9.patch) — 8 added lines

No kernel modules are reworked, no new C is written, the symbol surface is unchanged. If your stock kernel already has `snd-acp-config` and `snd-acp-legacy-mach`, the rebuilt versions are 100% binary-compatible drop-ins.

## Quick install

You need `bc`, `gcc`, `make`, `zstd`, `xz`, `curl`, the kernel headers package for your running kernel, and `sudo` rights to drop two `.ko.zst` files under `/lib/modules`.

```bash
git clone https://github.com/azorkai/huawei-matebook-m1080-linux-audio.git
cd huawei-matebook-m1080-linux-audio
./scripts/build-and-install.sh
sudo systemctl reboot
```

The script auto-detects your running kernel version, pulls the matching stable tarball from kernel.org, applies the two patches, re-uses your installed kernel's `.config` and `Module.symvers`, builds **only** `snd-acp-config.ko` and `snd-acp-legacy-mach.ko`, then installs them next to your existing kernel modules with `.bak` backups.

After the reboot, check:

```bash
aplay -l                 # card1 should now list "ES8316 HiFi-0" playback
wpctl status | head -30  # default sink should be "Audio Coprocessor Speakers"
```

Drop a YouTube tab into your browser and you should be hearing it.

## Manual build

If you'd rather not run the script, the recipe is:

```bash
# 1. Fetch the kernel source that matches your running kernel
KVER=$(uname -r | cut -d- -f1)
curl -O https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz
tar xf linux-$KVER.tar.xz
cd linux-$KVER

# 2. Apply the patches
patch -p1 < ../patches/0001-ASoC-amd-acp-config-add-M1080-DMI-quirk-for-HVY-WXX9.patch
patch -p1 < ../patches/0002-ASoC-amd-acp3x-es83xx-add-M1080-DMI-quirk-for-HVY-WXX9.patch

# 3. Reuse your installed kernel's config + symbol versions
zcat /proc/config.gz > .config
cp /lib/modules/$(uname -r)/build/Module.symvers .
make olddefconfig
make -j$(nproc) modules_prepare

# 4. Force vermagic to match the installed kernel so the module loads
#    without any --force flag. uname -r already includes the suffix.
echo "#define UTS_RELEASE \"$(uname -r)\"" > include/generated/utsrelease.h

# 5. Build only the two affected modules (about 20 seconds on a Ryzen 4600H)
make -j$(nproc) M=sound/soc/amd modules

# 6. Drop them into place, keeping a backup of the originals
DEST=/lib/modules/$(uname -r)/kernel/sound/soc/amd
for pair in \
    "sound/soc/amd/snd-acp-config.ko             $DEST/snd-acp-config.ko.zst" \
    "sound/soc/amd/acp/snd-acp-legacy-mach.ko    $DEST/acp/snd-acp-legacy-mach.ko.zst"; do
    set -- $pair
    sudo cp -n "$2" "$2.bak"           # only the first install creates a backup
    sudo zstd -19 -q -f "$1" -o "$2"
done
sudo depmod -a
sudo systemctl reboot
```

## Uninstall / rollback

The script keeps the stock modules as `*.ko.zst.bak`. To put them back:

```bash
sudo bash -c '
cd /lib/modules/$(uname -r)/kernel/sound/soc/amd
mv -f snd-acp-config.ko.zst.bak snd-acp-config.ko.zst
mv -f acp/snd-acp-legacy-mach.ko.zst.bak acp/snd-acp-legacy-mach.ko.zst
depmod -a
'
sudo systemctl reboot
```

If something goes wrong before you ever get this far — kernel panics, no display, anything — boot the LTS kernel from GRUB and run the rollback from there. CachyOS ships `linux-cachyos-lts` by default, which is reason enough to keep it installed.

## Will I have to redo this after a kernel update?

Yes. The new kernel ships brand-new versions of these two modules whose `vermagic` no longer matches the patched copies you installed. After every kernel bump, re-run `./scripts/build-and-install.sh` and reboot — it's a one-shot, ~30 seconds end-to-end.

If you want this automated, drop a pacman hook that triggers the script on every `linux-cachyos` upgrade. I'll add a sample hook to this repo at some point.

## Why not just upstream this?

I plan to. Mainline reviewers normally want the laptop owner to sign off on the DMI string and a Reported-by tag, and I'd like to gather one or two more user confirmations from different M1080 units before sending a proper `git format-patch`. If you have an M1080 and this fixes your audio, opening an issue on this repo with your `dmidecode` output would help a lot.

## Hardware confirmed

| Model              | DMI product_name | DMI product_version | Codec  | Status |
|--------------------|------------------|---------------------|--------|--------|
| MateBook D16 (2022)| HVY-WXX9         | M1080               | ES8316 | Working |

If yours is different, please send a PR adding the row.

## How it works (one paragraph for the curious)

The ACP3x machine driver on the AMD Renoir/Cezanne SoC is generic — the actual codec, the GPIO pinout, the DMIC topology, all of that is selected at probe time from a DMI quirk list. `snd-acp-config` returns `FLAG_AMD_LEGACY` for entries in its table, which makes the legacy ACP stack take over (instead of SOF). Then `acp3x-es83xx` looks up the second table and pulls in the `ES83XX_ENABLE_DMIC` driver_data flag, which configures the dual-DAI link (speaker + digital mic). Without a matching row in **both** tables, the `acp3x-es83xx` platform device never gets a driver bound and the card never appears.

## License

The patches and scripts are released under [GPL-2.0](LICENSE), matching the Linux kernel license they target.

## Acknowledgements

The structure of the DMI quirk entries comes straight from upstream commits by Mario Limonciello and Cristian Ciocaltea, who landed the original M1010/M1020/M1040 support. This is just one more row.

---

*Keywords for search: Huawei MateBook D16 no sound Linux, HVY-WXX9 audio fix, M1080 speakers not working, AMD Renoir ES8316 codec Linux, MateBook D14 D15 D16 Ryzen audio, CachyOS Manjaro Arch MateBook silent speakers, acp3x-es83xx M1080 DMI quirk, snd-acp-legacy-mach Huawei.*

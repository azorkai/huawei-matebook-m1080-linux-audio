# Upstream submission — prepared, NOT sent

A `git format-patch` series for the two M1080 DMI quirks, ready to review before
it goes to the mailing list. **Nothing here has been sent anywhere.**

| File | |
|------|---|
| `0000-cover-letter.patch` | Cover letter |
| `0001-…acp-config….patch` | `sound/soc/amd/acp-config.c` — select the legacy ACP backend |
| `0002-…acp3x-es83xx….patch` | `sound/soc/amd/acp/acp3x-es83xx/acp3x-es83xx.c` — ES8316 codec quirk |

22 added lines, no behaviour change on any other machine — both entries take
effect only on an exact three-way DMI match.

`scripts/checkpatch.pl --no-signoff` reports **0 errors, 0 warnings** on all
three files.

## Before sending — three things still to settle

**1. The `Tested-by:` tags are missing, and that is the main thing holding this
back.** Two M1080 owners have confirmed the fix (issue #3), which is exactly the
sign-off reviewers want. But kernel tags need a real name and email address, and
what we have are GitHub handles. Ask each confirming owner how they want to be
credited — `Tested-by: Real Name <email>` — and add the tags to both patches
before sending. Do not invent them.

**2. Confirm the `Signed-off-by:` identity.** The patches currently carry
`azorkai <e.guven@hotmail.com.tr>`, taken from this repo's git config. The SoB is
a legal statement under the Developer's Certificate of Origin, so it should be
the name and address you actually want on the kernel record — and it must match
the `From:` of the mail you send.

**3. Rebase onto the tree you're targeting.** These were generated against the
`sound/soc/amd` files from Linux 7.1.4. ASoC patches go to Mark Brown's tree, so
rebase onto `sound.git` `for-next` and re-run `checkpatch.pl` before sending:

```bash
git clone https://git.kernel.org/pub/scm/linux/kernel/git/broonie/sound.git
cd sound && git checkout for-next
git am /path/to/upstream/000[12]-*.patch
```

If `git am` applies cleanly, regenerate the series from there with
`git format-patch -2 --cover-letter` so the diff context matches the target tree.

## Recipients

From `scripts/get_maintainer.pl` on both touched files (identical for each):

```
Vijendar Mukunda <Vijendar.Mukunda@amd.com>
Venkata Prasad Potturu <venkataprasad.potturu@amd.com>
Liam Girdwood <lgirdwood@gmail.com>
Mark Brown <broonie@kernel.org>
Jaroslav Kysela <perex@perex.cz>
Takashi Iwai <tiwai@suse.com>
linux-sound@vger.kernel.org
linux-kernel@vger.kernel.org
```

## Sending

Once the three points above are settled:

```bash
# dry run first — prints the mails without sending anything
git send-email --dry-run --to=linux-sound@vger.kernel.org \
  --cc=Vijendar.Mukunda@amd.com \
  --cc=venkataprasad.potturu@amd.com \
  --cc=lgirdwood@gmail.com \
  --cc=broonie@kernel.org \
  --cc=perex@perex.cz \
  --cc=tiwai@suse.com \
  --cc=linux-kernel@vger.kernel.org \
  upstream/*.patch
```

Drop `--dry-run` to send for real. `git send-email` needs SMTP configured;
plain-text only, and don't let a client wrap lines or the patches won't apply.

After sending, link the lore.kernel.org thread in issue #3 so the owners who
confirmed the hardware can follow it to merge.

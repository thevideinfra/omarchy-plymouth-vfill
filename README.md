# omarchy-plymouth-vfill

An Omarchy boot splash where the logo fills from the bottom up as the system
boots, instead of the stock horizontal progress bar.

## Why a separate theme

Omarchy's own Plymouth theme lives at `/usr/share/plymouth/themes/omarchy` and
is owned by the `omarchy-settings` package, so every upgrade overwrites it. This
installs under its own name instead:

- `omarchy-plymouth-set` only ever writes `themes/omarchy`.
- Pacman owns only the files under `themes/omarchy`.
- `omarchy-theme-set` does not touch Plymouth at all.

So nothing upstream rewrites `omarchy-vfill`, and keeping it in step with the
desktop theme becomes this project's job.

## Install

```bash
git clone <repo> ~/Projects/omarchy-plymouth-vfill
cd ~/Projects/omarchy-plymouth-vfill
./install.sh
```

Reboot to see it.

The installer first asks how the boot splash should keep up with your desktop
theme, then asks for your password once, copies its scripts root-owned into
`/usr/local/lib/omarchy-vfill/`, installs the theme as `omarchy-vfill`, and
rebuilds the initramfs. The checkout is only the installation source; the
root-run code never runs from it. Re-running it after a `git pull` republishes
the updated theme files.

For a scripted install, answer the question up front and nothing is prompted:

```bash
./install.sh --mode theme-set   # or: reboot, manual
```

The installer detects an earlier hook-patch installation of the same idea and
offers to remove it first; leaving both in place would mean two mechanisms
fighting over the splash. Removing it runs `omarchy plymouth reset`, which asks
for your password itself and rebuilds the initramfs, so a migration prompts
twice and rebuilds twice.

## Keeping the splash in step with your theme

Nothing upstream recolours `omarchy-vfill`, so something has to. Recolouring
means a root-privileged initramfs rebuild of roughly 90 seconds, and the three
modes differ only in when you pay for it. Pick one at install time; re-run
`./install.sh` to change your mind, which removes the previous mode's
artefacts.

| Mode | What updates the splash | What it costs |
| --- | --- | --- |
| `theme-set` | A hook at `~/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh`, whenever the theme's colours change | An authentication prompt and a ~90 s rebuild at each theme change that actually alters the splash |
| `reboot` | The **Reboot with updated boot splash** launcher entry, or `/usr/local/bin/omarchy-vfill-reboot` | Nothing until you reboot, and the reboot takes ~90 s longer when the theme changed |
| `manual` | Nothing; you run the command below | Nothing, until you forget |

`theme-set` is the default. Its hook checks first with `--check`, which needs no
privileges and writes nothing, so a theme change that alters nothing the splash
bakes in costs nothing — no prompt, no rebuild. If that check cannot read the
theme at all, the hook says so and does nothing, rather than treating a broken
theme as one that needs no work.

`reboot` only reboots if the update succeeded; if it failed or you cancelled the
password prompt, it says so and the machine stays up. It runs in a terminal so
you can watch the rebuild.

### The manual command

Whichever mode you installed, this always works:

```bash
sudo /usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme --force
```

That asks for your password once and rebuilds the initramfs (roughly 90
seconds).

### Where the logo comes from

The logo comes from the active theme's `unlock.png` when it ships one, and
otherwise from Omarchy's `logo.svg` recoloured to the theme accent (the
foreground, if the theme has no accent). Not every theme ships `unlock.png` —
`aurora`, `dracula` and `texas-longhorns` do not.

A theme's own `unlock.png` is copied into the theme as it is — it is never
handed to ImageMagick — so what guards it is a size cap and an ownership check:
one larger than 8 MiB is skipped with a message in favour of the `logo.svg`
fallback, as is one whose size cannot even be read, and the file that is
actually opened has to be a regular file the invoking user owns, so a symlink
pointing at something else is refused rather than published into the initramfs.

The ImageMagick calls are capped too (memory, map, disk, dimensions and time),
and that matters because the recolour runs as root — but what they render is
package-owned artwork: Omarchy's `logo.svg` and the prompt furniture from
`/usr/share/omarchy`.

## Uninstall

```bash
./uninstall.sh
```

Restores Omarchy's stock splash.

It removes `/usr/local/lib/omarchy-vfill/`, the `omarchy-vfill` theme, and
whichever mode's artefacts are present — the theme-set hook,
`/usr/local/bin/omarchy-vfill-reboot` and its desktop entry — then rebuilds the
initramfs.

## Requirements

- Plymouth
- ImageMagick (`magick`) — already an effective Omarchy dependency
- One of: `limine-mkinitcpio`, `mkinitcpio`, `dracut`

## Tested

| Path | Status |
| --- | --- |
| `limine-mkinitcpio` (UKI) | Tested on real hardware |
| `mkinitcpio -P` | **Untested** — written from documentation |
| `dracut --force` | **Untested** — written from documentation |

Developed against Omarchy 4.0.4, Plymouth 26.134.222, on an AMD GPU with
`amdgpu`. If you run one of the untested paths, please report what happened.

## Known limitations

- There is a black gap between Plymouth exiting and the desktop appearing. That
  is a DRM handover blank and is outside this project; it is not caused by the
  fill.
- The SDDM greeter is not retinted. `omarchy-plymouth-set` retints it alongside
  Plymouth; this project deliberately does not.
- Omarchy's own Plymouth reset (`omarchy plymouth reset`, or the Unlock/logo
  menu that calls it) sets the default theme back to `omarchy`, turning vfill
  off. Nothing notices automatically. Restore it with the same command used
  after any theme change:
  `sudo /usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme --force`.

## Tests

```bash
bash test/all
```

No root and no Plymouth required. The privileged publish path is exercised
inside an unprivileged user namespace (`unshare -r`) against scratch
directories, with `plymouth-set-default-theme` and the initramfs tool stubbed.

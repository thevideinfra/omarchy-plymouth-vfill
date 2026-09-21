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

The installer asks for your password once, copies its scripts root-owned into
`/usr/local/lib/omarchy-vfill/`, installs the theme as `omarchy-vfill`, and
rebuilds the initramfs. The checkout is only the installation source; the
root-run code never runs from it. Re-running it after a `git pull` republishes
the updated theme files.

The installer detects an earlier hook-patch installation of the same idea and
offers to remove it first; leaving both in place would mean two mechanisms
fighting over the splash. Removing it runs `omarchy plymouth reset`, which asks
for your password itself and rebuilds the initramfs, so a migration prompts
twice and rebuilds twice.

## Updating after a theme change

The splash does not change automatically. After `omarchy theme set`, or
picking a theme another way, update it by hand:

```bash
sudo /usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme --force
```

That asks for your password once and rebuilds the initramfs (roughly 90
seconds).

The logo comes from the active theme's `unlock.png` when it ships one, and
otherwise from Omarchy's `logo.svg` recoloured to the theme foreground. Not
every theme ships `unlock.png` — `aurora`, `dracula` and `texas-longhorns` do
not.

## Uninstall

```bash
./uninstall.sh
```

Restores Omarchy's stock splash.

It removes `/usr/local/lib/omarchy-vfill/`, the `omarchy-vfill` theme, and any
theme-set hook left by an earlier install, then rebuilds the initramfs.

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

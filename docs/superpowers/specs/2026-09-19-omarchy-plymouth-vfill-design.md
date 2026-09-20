# omarchy-plymouth-vfill — design

## Goal

Package the vertical logo fill boot splash as a standalone, installable Plymouth
theme for Omarchy that survives package upgrades and follows the active Omarchy
theme's colours.

During boot the Omarchy logo fills from the bottom up as progress advances,
instead of the stock horizontal progress bar under the password prompt.

## Background

The fill currently runs on the author's machine as a patch applied to Omarchy's
own Plymouth theme by a `theme-set` / `post-update` hook. That approach is
fragile, and has already failed twice:

- `/usr/share/plymouth/themes/omarchy/omarchy.script` is owned by the
  `omarchy-settings` package. Every upgrade overwrites it. The 4.0.3 → 4.0.4
  upgrade silently reverted the theme, and the reapply hook then re-patched with
  an older variant of the script, which is what the machine has been booting
  since.
- The hook patches by matching exact anchor text. Upstream refactored the script
  (adding a `layout()` function for display hotplug), so the anchors only match
  some versions.

Three facts make a standalone theme immune to all of this:

- `omarchy-plymouth-set` hardcodes `/usr/share/plymouth/themes/omarchy` and
  `/usr/share/sddm/themes/omarchy`. It writes nowhere else.
- Pacman owns only the files under `themes/omarchy`.
- `omarchy-theme-set` contains no Plymouth references at all. Omarchy never
  retints Plymouth on a theme change; that only happens when the user runs
  `omarchy plymouth set-by-theme` by hand, which additionally requires the theme
  to ship an `unlock.png`.

A theme installed under a different name is therefore touched by nothing, and
keeping it in sync with the desktop theme becomes this project's job.

## Components

### Theme

Installed to `/usr/share/plymouth/themes/omarchy-vfill/`:

```
omarchy-vfill.plymouth
omarchy-vfill.script
logo.png  entry.png  lock.png  bullet.png
```

`omarchy-vfill.script` is taken from the `plymouth-vertical-logo-fill` branch of
the author's Omarchy fork (open upstream as PR #12040). That variant includes a
`layout()` function that re-centres on display hotplug, and implements the fill
as `position_fill()`: a second sprite holding `logo.image.Crop(0, top, width,
height)` anchored to the logo's bottom edge, with the full logo behind it dimmed
to act as the track.

It is vendored as a complete script, not applied as a patch. There are no
anchors to match and nothing upstream can invalidate.

`fake_progress_duration` stays at the upstream default of 15 seconds.

### `install.sh`

Idempotent. Stages the theme into the target directory, applies the current
theme's colours, sets the default Plymouth theme, rebuilds the initramfs, and
installs the `theme-set` hook.

Detects and offers to remove a previous hook-patch installation (see Migration).

### `uninstall.sh`

Removes the theme directory and the hook, restores the previously recorded
default Plymouth theme (`omarchy` unless the marker says otherwise), and
rebuilds the initramfs.

### `bin/omarchy-vfill-retheme`

Recolours the installed theme from the active Omarchy theme and rebuilds the
initramfs. Runs as root. Invoked by the hook, and usable by hand.

### `hooks/theme-set.sh`

Installed into `~/.config/omarchy/hooks/theme-set.d/`. Runs as the user, checks
whether a retheme is actually needed, and only then elevates via `pkexec` to run
`omarchy-vfill-retheme`.

## Retheme logic

The installed theme directory carries a marker file recording the values baked
into it:

```
background=#140F1F
foreground=#DFEDE5
logo_source=/home/ks/.local/state/omarchy/current/theme/unlock.png
logo_sha256=<hash>
```

On `theme-set` the hook reads the active theme's `colors.toml`, resolves the
logo source, and compares. Identical on every field means exit 0 with no output
and no authentication prompt. Any difference triggers a recolour.

Colour extraction from `colors.toml` uses an anchored match so that
`dark_background` and `lighter_background` cannot be mistaken for `background`.

A recolour:

1. Recolours `entry.png`, `lock.png` and `bullet.png` to the foreground colour
   with `magick ... +level-colors`, matching what `omarchy-plymouth-set` does for
   Omarchy's own theme.
2. Selects the logo: the active theme's `unlock.png` when it exists, otherwise
   `/usr/share/omarchy/logo.svg` rendered and recoloured to the foreground.
   `logo.svg` is greyscale plus alpha, so it recolours cleanly at any size.
   On this machine `aurora`, `dracula` and `texas-longhorns` ship no
   `unlock.png`; every other installed theme does.
3. Rewrites `Window.SetBackgroundTopColor` / `...BottomColor` in the script to
   the theme background. These take three floats in the range 0–1, not hex, so
   the colour is converted the same way `omarchy-plymouth-set` does
   (`#140F1F` becomes `0.078, 0.059, 0.122`).
4. Writes the marker and rebuilds the initramfs.

The logo is used at whatever size it comes in. The script reads the image's own
dimensions rather than assuming 800x188, because theme logos vary (tokyo-night
ships 1108x523).

## Portability

Initramfs rebuild follows Omarchy's own precedent in `omarchy-plymouth-set`,
with a third branch added:

1. `limine-mkinitcpio` if present
2. otherwise `mkinitcpio -P`
3. otherwise `dracut --force`

**Only the `limine-mkinitcpio` path can be tested here.** The other two are
written from documentation and are marked untested in the README. This is
recorded rather than glossed over, because a wrong initramfs command produces an
unbootable splash and the user deserves to know which paths carry that risk.

Privilege escalation follows the Omarchy convention: `sudo` when a terminal is
available for the prompt, `pkexec` otherwise. The hook always uses `pkexec`,
since it runs from a desktop event with no controlling terminal.

Dependencies: `plymouth`, `imagemagick` (`magick`), and one of the initramfs
tools above. `magick` is already an effective Omarchy dependency —
`omarchy-plymouth-set` invokes it unconditionally.

## Migration from the existing hook-patch setup

`install.sh` detects the previous installation and, with the user's consent:

1. Removes `~/.config/omarchy/plymouth-vfill/`.
2. Removes `reapply-hook.sh` from both `~/.config/omarchy/hooks/theme-set.d/`
   and `~/.config/omarchy/hooks/post-update.d/`.
3. Runs `omarchy plymouth reset` to restore Omarchy's stock theme, so the
   packaged theme is left untouched and only `omarchy-vfill` carries the fill.

Without this, two mechanisms would compete for the boot splash.

The pre-existing `/etc/systemd/system/plymouth-quit.service.d/retain-splash.conf`
drop-in is unrelated and is left alone.

## Testing

1. **Offline render.** Composite the hold and full-fill frames with ImageMagick
   using the installed assets, to confirm colours and logo selection without
   rebooting.
2. **Script load.** Run `plymouthd --debug` against the installed theme and
   confirm the script parses and executes with no errors. The daemon buffers its
   log, so it is read after the daemon exits.
3. **Retheme.** Switch to a theme that ships `unlock.png` and one that does not,
   and confirm the hook stays silent when nothing changed and recolours when it
   did.
4. **Reboot.** One reboot to confirm the real boot path.
5. **Uninstall.** Confirm the machine returns to the stock splash.

Nothing is pushed to GitHub until the machine test passes.

## Out of scope

- The black gap between Plymouth quitting and the desktop appearing. Established
  separately: it is a DRM handover blank, fixable on DP-1 by making Plymouth
  release the device with `plymouth deactivate` instead of quitting, but not on
  DP-3, because amdgpu rejects every high-refresh EDID timing supplied as a
  kernel `video=` mode and Plymouth therefore runs that panel at 59.95Hz.
- SDDM greeter theming. `omarchy-plymouth-set` retints the SDDM theme alongside
  Plymouth; this project deliberately does not, since the greeter is disabled
  under autologin on the target machine.
- Any post-login or session splash.

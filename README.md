# omarchy-plymouth-vfill

An Omarchy boot splash where the logo fills from the bottom up as the system
boots, instead of the stock horizontal progress bar.

![The stock splash with its horizontal bar beside the same splash with the logo
filling from the bottom up](images/before-after.png)

The fill uses whatever artwork the active theme supplies, so it follows your
desktop theme rather than imposing one:

![The fill at 55% under the tokyo-night, lumon, vantablack and catppuccin
themes](images/theme-coverage.png)

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
git clone https://github.com/thevideinfra/omarchy-plymouth-vfill.git ~/Projects/omarchy-plymouth-vfill
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

`auto` needs a second flag as well — `./install.sh --mode auto --i-understand` —
so no script can turn the password prompt off by accident. See
[Mode `auto`](#mode-auto-passwordless) for what it costs you.

The installer detects an earlier hook-patch installation of the same idea and
offers to remove it first; leaving both in place would mean two mechanisms
fighting over the splash. Removing it runs `omarchy plymouth reset`, which asks
for your password itself and rebuilds the initramfs, so a migration prompts
twice and rebuilds twice.

## Keeping the splash in step with your theme

Nothing upstream recolours `omarchy-vfill`, so something has to. Recolouring
means a root-privileged initramfs rebuild of a few moments, and the four
modes differ only in when you pay for it, and whether you are asked first. Pick
one at install time; re-run `./install.sh` to change your mind, which removes the
previous mode's artefacts.

| Mode | What updates the splash | What it costs |
| --- | --- | --- |
| `theme-set` | A hook at `~/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh`, whenever the theme's colours change | An authentication prompt and a ~90 s rebuild at each theme change that actually alters the splash |
| `reboot` | The **Plymouth vfill reboot** launcher entry, or `/usr/local/bin/omarchy-vfill-reboot` | Nothing until you reboot, and the reboot takes ~90 s longer when the theme changed |
| `manual` | Nothing; you run the command below | Nothing, until you forget |
| `auto` | The same hook as `theme-set` | No prompt and no ~90 s wait you have to sit through — paid for with a polkit rule that gives one command passwordless root |

`theme-set` is the default. Its hook checks first with `--check`, which needs no
privileges and writes nothing, so a theme change that alters nothing the splash
bakes in costs nothing — no prompt, no rebuild. If that check cannot read the
theme at all, the hook says so and does nothing, rather than treating a broken
theme as one that needs no work.

The hook's escalated half passes no arguments at all, in `theme-set` as well as
in `auto`: mode `auto`'s polkit rule approves only the argument-free invocation,
and the hook is the same file in both modes. So the recolour always follows the
theme under the home directory in your passwd entry, not `$HOME`. The two differ
only in a session whose `HOME` was changed, where the `--check` that decides
whether to escalate looks at `$HOME` while the recolour that follows looks at the
passwd home.

`reboot` only reboots if the update succeeded; if it failed or you cancelled the
password prompt, it says so and the machine stays up. It runs in a terminal so
you can watch the rebuild.

`manual` installs nothing that runs by itself; you run the command below when
you notice the splash is stale.

<a id="mode-auto-passwordless"></a>

### Mode `auto` — no password prompt

`auto` installs the same hook as `theme-set`, plus
`/etc/polkit-1/rules.d/49-omarchy-vfill.rules` (root-owned, 0644), which lets
`pkexec` run one exact command without authenticating. In plain terms:

- Any process running as you, in an active local session, may run
  `/usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme` as root with no
  prompt — that exact command and no arguments. The rule requires both the
  program and the whole command line to be that one path, so any other command
  line — the same program with any argument at all — stops matching the rule and
  falls back to a password prompt. The command line is yours to choose; what it
  buys you without a password is only this one. The program itself is root-owned,
  so what runs under that approval is not yours to change. Run with no arguments
  it recolours the splash from your own current Omarchy theme, which it finds from
  the home directory in your passwd entry.
- It can therefore trigger unlimited initramfs rebuilds: disk and CPU churn.
- It writes the boot image; the current image survives until a rebuild succeeds.
- Remove it with `./uninstall.sh`, or by switching to another mode.

The arguments matter, which is why they are not approved. `--theme-dir <path>`
names the directory the retheme reads `colors.toml` and `unlock.png` from; a rule
that approved it would let any process running as you have root publish colours
and artwork of its choosing into the live theme and the next initramfs, with no
prompt. So the hook escalates with no arguments at all, and `install.sh`'s own
call and `omarchy-vfill-reboot` — both of which do pass arguments — stop matching
the rule and authenticate as they always did.

What keeps this safe, in the end, is that one script being correct. The rule
grants root to one invocation of `omarchy-vfill-retheme` and nothing else, so
every bug in that script — anything it would run, write or trust — becomes a bug
that runs as root without anyone being asked first. If you are not willing to make that bet on this project's
code, use `theme-set`, which does exactly the same work and asks you each time.

`auto` is never the default and never reachable by pressing Enter: interactively
it is option 4 and you have to type `yes` in full; non-interactively it needs
`--mode auto --i-understand`. The installer refuses it outright when the rule
could not work anyway — no `polkitd`, no `/etc/polkit-1/rules.d` (polkit older
than 0.106), or an invoking user who is not in group `wheel` — and refuses it
when the shipped rule is not byte for byte the rule `install.sh` expects, rather
than granting passwordless root to whatever it actually says.

### The manual command

Whichever mode you installed, this always works:

```bash
sudo /usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme --force
```

That asks for your password once and rebuilds the initramfs (a few moments).

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
`/usr/local/bin/omarchy-vfill-reboot` and its desktop entry, and
`/etc/polkit-1/rules.d/49-omarchy-vfill.rules` — then rebuilds the initramfs.
The polkit rule is removed from `/etc/polkit-1/rules.d` whether or not it was
ever installed there, so no mode leaves passwordless root behind.

## Requirements

- Plymouth
- ImageMagick (`magick`) — already an effective Omarchy dependency
- One of: `limine-mkinitcpio` (current Omarchy) or `mkinitcpio` (older Omarchy)

## Omarchy only

This installs onto an Omarchy system and nowhere else. It reads Omarchy's
active theme, follows Omarchy's own Plymouth conventions, and rebuilds the
initramfs the way Omarchy does.

On a machine with neither `limine-mkinitcpio` nor `mkinitcpio`, the installer
refuses rather than guessing. There is deliberately no `dracut` fallback: a
bare `dracut --force` rebuilds an image named for the running kernel, which is
not necessarily the file the bootloader loads, so it would report success while
the splash never changed.

## Tested

| Path | Status |
| --- | --- |
| `limine-mkinitcpio` (UKI) | Tested on real hardware |
| `mkinitcpio -P` | **Untested** — written from documentation |

Developed against Omarchy 4.0.4, Plymouth 26.134.222, on an AMD GPU with
`amdgpu`. If you run the `mkinitcpio -P` path, please report what happened.

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

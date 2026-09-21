#!/bin/bash

# Install the omarchy-vfill Plymouth theme.
#
# Everything root executes or sources is copied root-owned into
# /usr/local/lib/omarchy-vfill/ in one privileged transaction; the checkout
# under $HOME is only ever the installation source, never something root runs
# or sources directly. See ruling-6-root-owned-install.md.
#
# Idempotent: re-running reinstalls from the current source and republishes the
# theme with --force, so updated theme files take effect even when the colours
# and logo have not changed.
#
# The splash does not follow theme changes automatically. After changing the
# Omarchy theme, update it by hand with:
#   sudo /usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme --force

set -uo pipefail

if ((EUID == 0)); then
  echo "install: run as your normal user, not as root" >&2
  exit 1
fi

REPO=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
HOOK_DIR="$HOME/.config/omarchy/hooks/theme-set.d"
HOOK_DEST="$HOOK_DIR/omarchy-vfill.sh"
LEGACY_DIR="$HOME/.config/omarchy/plymouth-vfill"
PREFIX=/usr/local/lib/omarchy-vfill
THEME_DIR="$HOME/.local/state/omarchy/current/theme"

source "$REPO/lib/vfill.sh"

for required in magick plymouth-set-default-theme; do
  command -v "$required" >/dev/null || {
    echo "install: missing required command: $required" >&2
    exit 1
  }
done

vfill_initramfs_command >/dev/null || {
  echo "install: no supported initramfs tool (limine-mkinitcpio, mkinitcpio, dracut)" >&2
  exit 1
}

# The earlier approach patched Omarchy's own packaged theme from a hook. Leaving
# it in place would mean two mechanisms fighting over the boot splash.
if [[ -d $LEGACY_DIR ]] || [[ -f $HOOK_DIR/reapply-hook.sh ]]; then
  echo "install: a previous hook-patch installation is present."
  echo "  It patched Omarchy's packaged theme, which package upgrades overwrite."
  echo "  This will remove it and restore Omarchy's stock theme before continuing."
  echo "  That restore rebuilds the initramfs once; this install rebuilds it again."
  read -r -p "  Remove it? [y/N] " reply
  [[ $reply == [yY] ]] || {
    echo "install: aborted; nothing was changed" >&2
    exit 1
  }

  rm -rf -- "$LEGACY_DIR"
  rm -f -- "$HOOK_DIR/reapply-hook.sh" \
    "$HOME/.config/omarchy/hooks/post-update.d/reapply-hook.sh"

  if command -v omarchy >/dev/null; then
    echo "install: restoring Omarchy's stock Plymouth theme"
    omarchy plymouth reset
  fi
fi

# An earlier version of this project installed a theme-set hook that
# recoloured the splash automatically. That hook is no longer rendered; drop
# a leftover one so re-running install on an upgraded machine removes it.
if [[ -f $HOOK_DEST ]]; then
  echo "install: removing the automatic theme-set hook from an earlier install"
  echo "  (recolouring is now manual; see the command printed at the end)"
  rm -f -- "$HOOK_DEST"
fi

run_root() {
  if [[ -t 0 ]]; then
    sudo "$@"
  else
    pkexec "$@"
  fi
}

echo "install: staging the theme into $PREFIX and applying it (requires root)"

# The retheme script runs as root, so it and everything it sources must live
# where the user cannot write. The checkout is only the installation source.
run_root /bin/bash -c '
  set -euo pipefail
  prefix="$1" repo="$2" theme_dir="$3"

  install -d -m 0755 -o root -g root "$prefix" "$prefix/bin" "$prefix/lib" "$prefix/theme"
  install -m 0755 -o root -g root "$repo/bin/omarchy-vfill-retheme" "$prefix/bin/omarchy-vfill-retheme"
  install -m 0644 -o root -g root "$repo/lib/vfill.sh" "$prefix/lib/vfill.sh"
  install -m 0644 -o root -g root \
    "$repo/theme/omarchy-vfill.plymouth" "$repo/theme/omarchy-vfill.script" "$prefix/theme/"

  exec "$prefix/bin/omarchy-vfill-retheme" --force --theme-dir "$theme_dir"
' bash "$PREFIX" "$REPO" "$THEME_DIR" || {
  echo "install: privileged install/retheme step failed; nothing else was changed" >&2
  exit 1
}

echo "install: done. Reboot to see the new boot splash."
echo "install: after changing the Omarchy theme, update the splash by hand with:"
echo "install:   sudo $PREFIX/bin/omarchy-vfill-retheme --force"

#!/bin/bash

# Remove the omarchy-vfill theme and hook, and hand the boot splash back to
# Omarchy's own theme.

set -uo pipefail

if ((EUID == 0)); then
  echo "uninstall: run as your normal user, not as root" >&2
  exit 1
fi

REPO=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
THEME_DEST=/usr/share/plymouth/themes/omarchy-vfill
PREFIX=/usr/local/lib/omarchy-vfill
HOOK_DEST="$HOME/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh"

source "$REPO/lib/vfill.sh"

# Remove the hook first, so a theme change mid-uninstall cannot trigger a
# retheme against a half-removed install.
rm -f -- "$HOOK_DEST"

# Detected as the user; the root shell below deliberately sources nothing
# from the checkout.
rebuild=$(vfill_initramfs_command) || {
  echo "uninstall: no initramfs tool found" >&2
  exit 1
}
read -r -a rebuild_cmd <<<"$rebuild"

run_root() {
  if [[ -t 0 ]]; then
    sudo "$@"
  else
    pkexec "$@"
  fi
}

# Restore the default theme before deleting the theme directory, so there is
# never a moment where the configured default does not exist.
run_root /bin/bash -c '
  set -uo pipefail
  theme_dest="$1" prefix="$2"
  shift 2

  plymouth-set-default-theme omarchy || exit 1
  rm -rf -- "$theme_dest" "$prefix"
  "$@"
' bash "$THEME_DEST" "$PREFIX" "${rebuild_cmd[@]}"

echo "uninstall: done. The stock Omarchy splash returns on the next boot."

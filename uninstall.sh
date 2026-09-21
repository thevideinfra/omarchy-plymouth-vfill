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
HOOK_DIR="$HOME/.config/omarchy/hooks/theme-set.d"
HOOK_DEST="$HOOK_DIR/omarchy-vfill.sh"
# omarchy-hook (/usr/share/omarchy/bin/omarchy-hook) runs every regular file
# in theme-set.d/ except ones ending in .sample, so renaming within that
# directory would still execute. Staging one level up, outside theme-set.d/,
# keeps it out of that glob and out of the literal hooks/theme-set path
# omarchy-hook also checks, so it genuinely cannot run while staged -- and
# the move is a plain mv, trivial to undo if the transaction below fails.
HOOK_STAGED="$HOME/.config/omarchy/hooks/omarchy-vfill.sh.uninstalling"

source "$REPO/lib/vfill.sh"

# Move the hook aside rather than deleting it: a theme change mid-uninstall
# must not retheme against a half-removed install, but a failed or cancelled
# privileged transaction below must not silently leave the theme installed
# with nothing keeping it current -- so the hook needs to come back in that
# case.
hook_staged=false
if [[ -f $HOOK_DEST ]]; then
  mv -- "$HOOK_DEST" "$HOOK_STAGED" || {
    echo "uninstall: failed to move the hook aside" >&2
    exit 1
  }
  hook_staged=true
fi

restore_hook() {
  $hook_staged || return 0
  mv -- "$HOOK_STAGED" "$HOOK_DEST"
}

# Detected as the user; the root shell below deliberately sources nothing
# from the checkout.
rebuild=$(vfill_initramfs_command) || {
  echo "uninstall: no initramfs tool found" >&2
  restore_hook
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
if run_root /bin/bash -c '
  set -uo pipefail
  theme_dest="$1" prefix="$2"
  shift 2

  plymouth-set-default-theme omarchy || exit 1
  rm -rf -- "$theme_dest" "$prefix"
  "$@"
' bash "$THEME_DEST" "$PREFIX" "${rebuild_cmd[@]}"; then
  $hook_staged && rm -f -- "$HOOK_STAGED"
  echo "uninstall: done. The stock Omarchy splash returns on the next boot."
else
  restore_hook
  echo "uninstall: did not complete -- authentication was cancelled or the privileged step failed." >&2
  echo "uninstall: the theme is still installed and the hook is still in place." >&2
  exit 1
fi

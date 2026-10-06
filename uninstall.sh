#!/bin/bash

# Remove the omarchy-vfill theme, and hand the boot splash back to Omarchy's
# own theme.
#
# Every mode's artefacts go, whichever mode is recorded in $PREFIX/mode: the
# theme-set hook under $HOME, mode reboot's root-owned command and desktop
# entry, and mode auto's polkit rule. The mode file itself lives inside $PREFIX
# and goes with it. Nothing reads the mode file to decide -- removing an
# artefact that is not there is free, and that way a mode file lost or never
# written still leaves nothing behind.

set -uo pipefail

if ((EUID == 0)); then
  echo "uninstall: run as your normal user, not as root" >&2
  exit 1
fi

REPO=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
THEME_DEST=/usr/share/plymouth/themes/omarchy-vfill
PREFIX=/usr/local/lib/omarchy-vfill
# Mode reboot's root-owned artefacts. They live outside $PREFIX, so removing
# the prefix does not take them with it; they have to be named. Passed into
# the privileged transaction as arguments, so the tests can replay it against
# scratch paths.
REBOOT_BIN=/usr/local/bin/omarchy-vfill-reboot
DESKTOP_ENTRY=/usr/local/share/applications/omarchy-vfill-reboot.desktop
# Mode auto's polkit rule, removed whether or not it is there -- as with every
# other artefact, the recorded mode is not consulted. Overridable only so the
# tests can point it at a scratch directory instead of the real
# /etc/polkit-1/rules.d, exactly like VFILL_THEME_DEST in
# bin/omarchy-vfill-retheme; see the same note in install.sh.
POLKIT_RULE=${VFILL_POLKIT_RULES_DIR:-/etc/polkit-1/rules.d}/49-omarchy-vfill.rules
# The same lock bin/omarchy-vfill-retheme takes, so an uninstall never
# interleaves with a retheme still publishing or rebuilding.
LOCK_FILE=/run/lock/omarchy-vfill.lock
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

# Recover from an earlier interrupted run. A staged file with no live hook
# was left behind mid-uninstall and never made it back; put it back before
# doing anything else. A staged file alongside a live hook is stale -- the
# live hook is the real one -- so just drop the leftover copy.
if [[ -f $HOOK_STAGED && ! -f $HOOK_DEST ]]; then
  echo "uninstall: recovering a hook left staged by an earlier interrupted run"
  mv -- "$HOOK_STAGED" "$HOOK_DEST" || {
    echo "uninstall: failed to recover the staged hook" >&2
    exit 1
  }
elif [[ -f $HOOK_STAGED && -f $HOOK_DEST ]]; then
  echo "uninstall: removing a stale staged hook copy from an earlier interrupted run"
  rm -f -- "$HOOK_STAGED"
fi

# A hook is present when the install was in mode theme-set. Move it aside
# rather than deleting it outright: a
# theme change mid-uninstall must not retheme against a half-removed install,
# but a failed, cancelled, or interrupted privileged transaction below must
# not silently leave the theme installed with nothing keeping it current -- so
# the hook needs to come back in that case.
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

# outcome tracks whether the staging window has already been resolved (the
# transaction finished, one way or the other), so a signal that lands after
# that point -- e.g. during the final echo -- never re-restores a hook that a
# successful run has already deleted, and the handler below knows not to act.
outcome=pending

# A foreground Ctrl-C at the sudo/pkexec password prompt reaches this
# script's whole process group, not just the child, so the window between
# staging the hook and resolving the transaction needs its own signal
# handling: without it, that is the most common way to strand the hook at
# HOOK_STAGED, never restored and never executed again.
on_signal() {
  local sig="$1"
  trap '' INT TERM HUP
  if [[ $outcome == pending ]]; then
    outcome=interrupted
    restore_hook
    if $hook_staged; then
      echo "uninstall: interrupted; restored the hook. Parts of the theme may already be removed; re-run ./uninstall.sh to finish." >&2
    else
      echo "uninstall: interrupted. Parts of the theme may already be removed; re-run ./uninstall.sh to finish." >&2
    fi
  fi
  case "$sig" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
    *) exit 1 ;;
  esac
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# Detected as the user; the root shell below deliberately sources nothing
# from the checkout.
rebuild=$(vfill_initramfs_command) || {
  echo "uninstall: no initramfs tool found" >&2
  outcome=failed
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
# never a moment where the configured default does not exist. The .new.* and
# .old.* siblings are what an interrupted retheme can strand beside it.
if run_root /bin/bash -c '
  set -uo pipefail
  shopt -s nullglob
  theme_dest="$1" prefix="$2" lock_file="$3" reboot_bin="$4" desktop_entry="$5"
  polkit_rule="$6"
  shift 6

  exec {lock_fd}>>"$lock_file" || exit 1
  flock "$lock_fd" || exit 1

  plymouth-set-default-theme omarchy || exit 1
  rm -rf -- "$theme_dest" "$theme_dest".new.* "$theme_dest".old.* "$prefix" || exit 1
  rm -f -- "$reboot_bin" "$desktop_entry" "$polkit_rule" || exit 1
  "$@"
' bash "$THEME_DEST" "$PREFIX" "$LOCK_FILE" "$REBOOT_BIN" "$DESKTOP_ENTRY" \
  "$POLKIT_RULE" "${rebuild_cmd[@]}"; then
  outcome=succeeded
  trap - INT TERM HUP
  $hook_staged && rm -f -- "$HOOK_STAGED"
  echo "uninstall: done. The stock Omarchy splash returns on the next boot."
else
  outcome=failed
  trap - INT TERM HUP
  restore_hook
  echo "uninstall: did not complete -- authentication was cancelled or the privileged step failed." >&2
  $hook_staged && echo "uninstall: the hook has been put back." >&2
  echo "uninstall: parts of the theme may already be removed; re-run ./uninstall.sh to finish." >&2
  exit 1
fi

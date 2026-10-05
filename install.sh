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
# How the splash keeps up with the desktop theme is the user's choice, made
# here and recorded in $PREFIX/mode so a re-install and the uninstaller know
# which artefacts exist:
#
#   theme-set  a theme-set hook updates it when the colours change
#   reboot     the "Reboot with updated boot splash" action updates it
#   manual     nothing does; the user runs the retheme command
#
# Whichever mode is chosen, this always works:
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
# Root-owned, so they are installed and removed by the privileged transaction
# below rather than here. Passed into it as arguments so the tests can replay
# that transaction against scratch paths.
REBOOT_BIN=/usr/local/bin/omarchy-vfill-reboot
DESKTOP_ENTRY=/usr/local/share/applications/omarchy-vfill-reboot.desktop

source "$REPO/lib/vfill.sh"

MODE=""

while (($# > 0)); do
  case "$1" in
    --mode)
      shift
      MODE="${1:-}"
      ;;
    *)
      echo "install: unknown option: $1" >&2
      echo "install: usage: ./install.sh [--mode theme-set|reboot|manual]" >&2
      exit 1
      ;;
  esac
  shift
done

# Validated before anything is inspected or changed, so a typo costs nothing.
if [[ -n $MODE ]]; then
  case "$MODE" in
    theme-set | reboot | manual) ;;
    *)
      echo "install: unknown mode: $MODE" >&2
      echo "install: expected one of: theme-set, reboot, manual" >&2
      exit 1
      ;;
  esac
fi

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

# Ask only when --mode did not already answer. A bad answer is re-asked rather
# than guessed at: each mode costs the user something different (a password
# prompt per theme change, a slower reboot, or remembering a command), so
# picking one for them is worse than asking again.
#
# No answer at all -- an empty or closed stdin, as in a scripted install --
# takes the default rather than looping forever.
if [[ -z $MODE ]]; then
  echo "How should the boot splash follow your desktop theme?"
  echo "  1) At theme change — authenticate when the theme's colours change (default)"
  echo "  2) Before reboot — update it from the \"Reboot with updated boot splash\" action"
  echo "  3) Manually — run the update command yourself"

  while [[ -z $MODE ]]; do
    if ! read -r -p "  Choice [1]: " reply; then
      echo "install: no answer given; using the default (at theme change)"
      MODE=theme-set
      break
    fi

    case "${reply:-1}" in
      1) MODE=theme-set ;;
      2) MODE=reboot ;;
      3) MODE=manual ;;
      *) echo "  Please answer 1, 2 or 3." ;;
    esac
  done
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
#
# Every root-owned artefact of every mode is settled inside this one
# transaction -- the mode file, and the reboot command and its desktop entry,
# installed for mode reboot and removed for the others -- so switching modes
# on a re-install still costs the user exactly one authentication.
run_root /bin/bash -c '
  set -euo pipefail
  prefix="$1" repo="$2" theme_dir="$3" mode="$4" reboot_bin="$5" desktop_entry="$6"

  install -d -m 0755 -o root -g root "$prefix" "$prefix/bin" "$prefix/lib" "$prefix/theme"
  install -m 0755 -o root -g root "$repo/bin/omarchy-vfill-retheme" "$prefix/bin/omarchy-vfill-retheme"
  install -m 0644 -o root -g root "$repo/lib/vfill.sh" "$prefix/lib/vfill.sh"
  install -m 0644 -o root -g root \
    "$repo/theme/omarchy-vfill.plymouth" "$repo/theme/omarchy-vfill.script" "$prefix/theme/"

  # Records what is installed, for the next install and for the uninstaller.
  # Root-owned 0644: the user may read which mode is active, not change it.
  printf "%s\n" "$mode" | install -m 0644 -o root -g root /dev/stdin "$prefix/mode"

  if [[ $mode == reboot ]]; then
    install -d -m 0755 -o root -g root "$(dirname "$reboot_bin")" "$(dirname "$desktop_entry")"
    install -m 0755 -o root -g root "$repo/bin/omarchy-vfill-reboot" "$reboot_bin"
    install -m 0644 -o root -g root "$repo/share/omarchy-vfill-reboot.desktop" "$desktop_entry"
  else
    rm -f -- "$reboot_bin" "$desktop_entry"
  fi

  exec "$prefix/bin/omarchy-vfill-retheme" --force --theme-dir "$theme_dir"
' bash "$PREFIX" "$REPO" "$THEME_DIR" "$MODE" "$REBOOT_BIN" "$DESKTOP_ENTRY" || {
  echo "install: privileged install/retheme step failed; nothing else was changed" >&2
  exit 1
}

# The hook lives under $HOME and is the user's own file, so it is settled here
# rather than in the transaction -- and only now, because until the transaction
# succeeded there was no installed retheme for it to point at. A hook left by a
# previous install in a different mode is removed for the same reason it is
# installed: the mode file and the artefacts on disk have to agree.
if [[ $MODE == theme-set ]]; then
  install -d -m 0755 "$HOOK_DIR" || {
    echo "install: failed to create $HOOK_DIR" >&2
    exit 1
  }
  vfill_render_hook "$REPO/hooks/theme-set.sh" "$PREFIX/bin/omarchy-vfill-retheme" >"$HOOK_DEST" || {
    echo "install: failed to render the theme-set hook" >&2
    exit 1
  }
  chmod 0755 "$HOOK_DEST"
elif [[ -f $HOOK_DEST ]]; then
  echo "install: removing the theme-set hook from a previous install"
  rm -f -- "$HOOK_DEST"
fi

echo "install: done. Reboot to see the new boot splash."

case "$MODE" in
  theme-set)
    echo "install: mode: at theme change. $HOOK_DEST"
    echo "install:   updates the splash when the theme's colours change, asking for your"
    echo "install:   password and rebuilding the initramfs (about 90 seconds) when it does."
    echo "install:   A theme change that alters nothing it bakes in costs nothing at all."
    ;;
  reboot)
    echo "install: mode: before reboot. Nothing happens on a theme change; choose"
    echo "install:   \"Reboot with updated boot splash\" from your launcher (or run"
    echo "install:   $REBOOT_BIN) and the splash is brought up to"
    echo "install:   date first -- about 90 seconds -- and the machine reboots only if that worked."
    ;;
  manual)
    echo "install: mode: manually. Nothing updates the splash for you."
    ;;
esac

echo "install: whatever the mode, you can always update the splash by hand with:"
echo "install:   sudo $PREFIX/bin/omarchy-vfill-retheme --force"

#!/bin/bash

# Omarchy theme-set hook: keep the omarchy-vfill boot splash in step with the
# desktop theme.
#
# Runs as the user. --check needs no privileges and performs no writes, so when
# nothing relevant changed this exits silently and no authentication prompt ever
# appears. Only a real change escalates.
#
# --check exit codes: 0 a retheme is needed, 3 already current, anything else an
# error. A theme-set hook must never fail a theme change, so every outcome
# except 0 exits 0 -- but an error says so on stderr rather than passing for
# "already current", and an error never prompts for a password either.

set -uo pipefail

RETHEME=__RETHEME_PATH__
THEME_DIR="$HOME/.local/state/omarchy/current/theme"

[[ -x $RETHEME ]] || exit 0

"$RETHEME" --check --theme-dir "$THEME_DIR"
check_status=$?

case $check_status in
  0) ;;
  3) exit 0 ;;
  *)
    echo "omarchy-vfill: boot splash not updated: the check failed (exit $check_status)" >&2
    exit 0
    ;;
esac

command -v omarchy-notification-send >/dev/null &&
  omarchy-notification-send "Boot splash" "Recolouring for the new theme" 2>/dev/null

pkexec "$RETHEME" --theme-dir "$THEME_DIR"

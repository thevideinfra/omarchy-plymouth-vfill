#!/bin/bash

# Omarchy theme-set hook: keep the omarchy-vfill boot splash in step with the
# desktop theme.
#
# Runs as the user. --check needs no privileges and performs no writes, so when
# nothing relevant changed this exits silently and no authentication prompt ever
# appears. Only a real change escalates.

set -uo pipefail

RETHEME=__RETHEME_PATH__
THEME_DIR="$HOME/.local/state/omarchy/current/theme"

[[ -x $RETHEME ]] || exit 0

# Exit 0 from --check means a retheme is needed.
"$RETHEME" --check --theme-dir "$THEME_DIR" || exit 0

command -v omarchy-notification-send >/dev/null &&
  omarchy-notification-send "Boot splash" "Recolouring for the new theme" 2>/dev/null

pkexec "$RETHEME" --theme-dir "$THEME_DIR"

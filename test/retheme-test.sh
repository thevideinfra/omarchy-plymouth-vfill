#!/bin/bash

# Exercises only the unprivileged --check path of bin/omarchy-vfill-retheme.
# Never runs the script without --check, never runs it as root, and never
# touches /usr/share: VFILL_THEME_DEST always points at a scratch directory.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

RETHEME="$ROOT/bin/omarchy-vfill-retheme"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

theme_dir="$scratch/theme"
mkdir -p "$theme_dir"
cat >"$theme_dir/colors.toml" <<'EOF'
background = "#140F1F"
foreground = "#DFEDE5"
EOF
magick -size 40x10 xc:white -alpha set "$theme_dir/unlock.png"

logo="$theme_dir/unlock.png"

# --check exits 0 (retheme needed) when the destination has no marker.
dest1="$scratch/dest-no-marker"
mkdir -p "$dest1"
VFILL_THEME_DEST="$dest1" "$RETHEME" --check --theme-dir "$theme_dir"
assert_equals "0" "$?" "--check exits 0 when the destination has no marker"

# --check exits 1 (not needed) when the destination holds a matching marker.
dest2="$scratch/dest-matching-marker"
mkdir -p "$dest2"
vfill_write_marker "$dest2/.vfill-marker" "140F1F" "DFEDE5" "$logo"
VFILL_THEME_DEST="$dest2" "$RETHEME" --check --theme-dir "$theme_dir"
assert_equals "1" "$?" "--check exits 1 when the destination has a matching marker"

# --theme-dir wins over a misleading HOME.
dest3="$scratch/dest-home-precedence"
mkdir -p "$dest3"
output=$(HOME=/nonexistent VFILL_THEME_DEST="$dest3" "$RETHEME" --check --theme-dir "$theme_dir" 2>&1)
status=$?
assert_equals "0" "$status" \
  "--theme-dir wins over HOME: --check succeeds (retheme needed) rather than erroring"
[[ $output != *"/nonexistent"* ]] ||
  fail "--theme-dir wins over HOME: output must never mention /nonexistent" "$output"
pass "--theme-dir wins over HOME: output never mentions /nonexistent"

# An unknown option exits non-zero.
dest4="$scratch/dest-unknown-option"
mkdir -p "$dest4"
VFILL_THEME_DEST="$dest4" "$RETHEME" --check --bogus-option 2>/dev/null
status=$?
[[ $status -ne 0 ]] || fail "an unknown option exits non-zero"
pass "an unknown option exits non-zero"

# --check writes nothing: the scratch destination is unchanged afterwards.
dest5="$scratch/dest-no-writes"
mkdir -p "$dest5"
before=$(find "$dest5" -mindepth 1 | sort)
VFILL_THEME_DEST="$dest5" "$RETHEME" --check --theme-dir "$theme_dir" >/dev/null 2>&1
after=$(find "$dest5" -mindepth 1 | sort)
assert_equals "$before" "$after" "--check writes nothing to the destination"

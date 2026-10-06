#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

command -v magick >/dev/null || fail "magick is available"

pixel_hex() {
  magick "$1" -format '%[hex:p{2,2}]' info: | cut -c1-6
}

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

theme_dir="$scratch/theme"
omarchy_path="$scratch/omarchy"
dest="$scratch/dest"
mkdir -p "$theme_dir" "$omarchy_path/default/plymouth" "$dest"

cat >"$theme_dir/colors.toml" <<'EOF'
background = "#140F1F"
foreground = "#DFEDE5"
EOF

magick -size 40x10 xc:white -alpha set "$theme_dir/unlock.png"
for asset in entry.png lock.png bullet.png; do
  magick -size 8x8 xc:white -alpha set "$omarchy_path/default/plymouth/$asset"
done

vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" ||
  fail "staging succeeds"
pass "staging succeeds"

for asset in omarchy-vfill.script omarchy-vfill.plymouth logo.png entry.png lock.png bullet.png .vfill-marker; do
  [[ -f $dest/$asset ]] || fail "staging produces $asset"
done
pass "staging produces every required asset"

[[ -f $dest/progress_bar.png ]] &&
  fail "staging does not copy the unused progress bar assets"
pass "staging does not copy the unused progress bar assets"

for asset in entry.png lock.png bullet.png; do
  assert_equals "DFEDE5" "$(pixel_hex "$dest/$asset")" \
    "$asset is recoloured to the foreground"
done

assert_equals "Window.SetBackgroundTopColor(0.078, 0.059, 0.122);" \
  "$(grep -m1 '^Window.SetBackgroundTopColor' "$dest/omarchy-vfill.script")" \
  "the background is written into the staged script"

assert_equals "Window.SetBackgroundBottomColor(0.078, 0.059, 0.122);" \
  "$(grep -m1 '^Window.SetBackgroundBottomColor' "$dest/omarchy-vfill.script")" \
  "the bottom background matches the top"

vfill_marker_matches "$dest/.vfill-marker" "140F1F" "DFEDE5" "$theme_dir/unlock.png" "DFEDE5" ||
  fail "the staged marker reflects what was baked in"
pass "the staged marker reflects what was baked in"

# A theme with no unlock.png must still stage, using the omarchy fallback.
rm "$theme_dir/unlock.png"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="1215" height="285"><rect width="1215" height="285" fill="#888"/></svg>\n' \
  >"$omarchy_path/logo.svg"
rm -rf "${dest:?}"/*
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" ||
  fail "staging succeeds for a theme without unlock.png"
pass "staging succeeds for a theme without unlock.png"
[[ -f $dest/logo.png ]] || fail "the fallback logo is rendered to logo.png"
pass "the fallback logo is rendered to logo.png"

assert_equals "800" "$(magick identify -format '%w' "$dest/logo.png")" \
  "the fallback logo is 800 wide, matching stock unlock.png"
assert_equals "188" "$(magick identify -format '%h' "$dest/logo.png")" \
  "the fallback logo keeps its aspect ratio (188 high)"

assert_equals "DFEDE5" "$(pixel_hex "$dest/logo.png")" \
  "the fallback logo is recoloured to the foreground"

# When the theme's colors.toml has an accent, the fallback logo is recoloured
# to it instead of the foreground. Restore the file afterwards so the rest of
# this test still exercises the no-accent (foreground) path.
cp "$theme_dir/colors.toml" "$theme_dir/colors.toml.bak"
cat >>"$theme_dir/colors.toml" <<'EOF'
accent = "#8BE9FD"
EOF
rm -rf "${dest:?}"/*
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" ||
  fail "staging succeeds for a theme with an accent"
pass "staging succeeds for a theme with an accent"

assert_equals "8BE9FD" "$(pixel_hex "$dest/logo.png")" \
  "the fallback logo is recoloured to the accent when the theme has one"

mv "$theme_dir/colors.toml.bak" "$theme_dir/colors.toml"

# An explicit fifth-argument logo must win over the theme directory's own
# unlock.png, not just supply a value when the directory has none. This is
# what closes the TOCTOU window in bin/omarchy-vfill-retheme: the caller
# resolves (and, for unlock.png, verifies) the logo exactly once and passes
# it through, so vfill_stage_theme must never re-resolve and re-discover a
# file that could have changed since.
magick -size 40x10 xc:white -alpha set "$theme_dir/unlock.png"
assert_equals "FFFFFF" "$(pixel_hex "$theme_dir/unlock.png")" \
  "prerequisite: the theme directory's own unlock.png is white"

rm -rf "${dest:?}"/*
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" "$omarchy_path/logo.svg" ||
  fail "staging succeeds when an explicit fifth-argument logo is given"
pass "staging succeeds when an explicit fifth-argument logo is given"

assert_equals "DFEDE5" "$(pixel_hex "$dest/logo.png")" \
  "the fifth-argument logo (the svg fallback) wins over the theme's own unlock.png"

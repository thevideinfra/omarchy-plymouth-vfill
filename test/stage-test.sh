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

# A sixth argument says where the logo's BYTES come from, while the fifth still
# names the logo. That is what lets the privileged retheme stage, publish and hash
# a verified copy of the theme's unlock.png without root ever opening the user's
# path again -- to copy it or to hash it for the marker. The two files here are
# deliberately different, so staging from the path instead of the copy is visible.
copy_src="$scratch/verified-copy.png"
magick -size 40x10 xc:"#8BE9FD" -alpha set "$copy_src"
assert_equals "FFFFFF" "$(pixel_hex "$theme_dir/unlock.png")" \
  "prerequisite: the theme's own unlock.png is white"
assert_equals "8BE9FD" "$(pixel_hex "$copy_src")" \
  "prerequisite: the stand-in verified copy is not"

rm -rf "${dest:?}"/*
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" \
  "$theme_dir/unlock.png" "$copy_src" ||
  fail "staging succeeds with a separate content file"
pass "staging succeeds with a separate content file"

assert_equals "8BE9FD" "$(pixel_hex "$dest/logo.png")" \
  "the staged logo is the bytes of the sixth argument, not of the logo path"
assert_equals "$theme_dir/unlock.png" \
  "$(sed -nE 's/^logo_source=(.*)$/\1/p' "$dest/.vfill-marker")" \
  "the marker still records the logo path as its source"
assert_equals "$(sha256sum "$copy_src" | cut -d' ' -f1)" \
  "$(sed -nE 's/^logo_sha256=(.*)$/\1/p' "$dest/.vfill-marker")" \
  "the marker hashes the sixth argument, so root never re-reads the path to hash it"

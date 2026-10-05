#!/bin/bash

# The theme is rendered from user-supplied artwork (a theme's unlock.png), so
# the work is capped two ways: every magick call carries resource limits, and
# an oversized unlock.png is refused in favour of the bundled fallback logo
# rather than failing the whole run.
#
# magick is stubbed here so the limits can be read off the real argv without
# rendering anything, and so the oversize cases need no multi-megabyte image.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

stubs="$scratch/stubs"
calls="$scratch/magick-calls"
mkdir -p "$stubs"

cat >"$stubs/magick" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$VFILL_TEST_MAGICK_CALLS"
# Keep staging going: the last argument is always the output file.
out="${*: -1}"
[[ -e $out ]] || : >"$out"
exit 0
STUB
chmod +x "$stubs/magick"
export VFILL_TEST_MAGICK_CALLS="$calls"
PATH="$stubs:$PATH"

EXPECTED_LIMITS="-limit memory 128MiB -limit map 256MiB -limit disk 256MiB -limit width 4096 -limit height 4096 -limit time 20"

theme_dir="$scratch/theme"
omarchy_path="$scratch/omarchy"
dest="$scratch/dest"
mkdir -p "$theme_dir" "$omarchy_path/default/plymouth" "$dest"

cat >"$theme_dir/colors.toml" <<'EOF'
background = "#140F1F"
foreground = "#DFEDE5"
EOF

for asset in entry.png lock.png bullet.png; do
  printf 'fake png\n' >"$omarchy_path/default/plymouth/$asset"
done
printf '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>\n' >"$omarchy_path/logo.svg"
printf 'fake png\n' >"$theme_dir/unlock.png"

# --- Every magick call carries the resource limits. ------------------------

: >"$calls"
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" ||
  fail "staging succeeds with the magick stub"
pass "staging succeeds with the magick stub"

mapfile -t recorded <"$calls"
assert_equals "3" "${#recorded[@]}" \
  "staging a theme with its own unlock.png makes three magick calls"

for call in "${recorded[@]}"; do
  [[ $call == *"$EXPECTED_LIMITS"* ]] ||
    fail "every magick call for the prompt furniture carries the resource limits" "$call"
done
pass "every magick call for the prompt furniture carries the resource limits"

# The svg fallback path adds two more calls; those need the limits too, and
# they are the ones that actually rasterise untrusted-shaped input.
rm -f -- "$theme_dir/unlock.png"
rm -rf -- "${dest:?}"/*
: >"$calls"
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" ||
  fail "staging succeeds for a theme without unlock.png"
pass "staging succeeds for a theme without unlock.png"

mapfile -t recorded <"$calls"
assert_equals "5" "${#recorded[@]}" \
  "staging the svg fallback makes five magick calls"

for call in "${recorded[@]}"; do
  [[ $call == *"$EXPECTED_LIMITS"* ]] ||
    fail "every magick call on the fallback path carries the resource limits" "$call"
done
pass "every magick call on the fallback path carries the resource limits"

# --- An oversized unlock.png is refused, with a clear message. -------------

truncate -s $((8 * 1024 * 1024 + 1)) "$theme_dir/unlock.png"
message=$(vfill_resolve_logo "$theme_dir" "$omarchy_path" 2>&1 >"$scratch/resolved")
assert_equals "0" "$?" "resolving still succeeds when unlock.png is oversized"
assert_equals "$omarchy_path/logo.svg" "$(<"$scratch/resolved")" \
  "an oversized unlock.png resolves to the fallback logo instead"
[[ $message == *"$theme_dir/unlock.png"* ]] ||
  fail "the refusal names the oversized file" "$message"
pass "the refusal names the oversized file"
[[ $message == *"8 MiB"* ]] ||
  fail "the refusal names the 8 MiB limit" "$message"
pass "the refusal names the 8 MiB limit"

# The limit is a ceiling, not an exclusive bound: exactly 8 MiB is fine.
truncate -s $((8 * 1024 * 1024)) "$theme_dir/unlock.png"
assert_equals "$theme_dir/unlock.png" \
  "$(vfill_resolve_logo "$theme_dir" "$omarchy_path" 2>/dev/null)" \
  "an unlock.png of exactly 8 MiB is still accepted"

# A whole staging run falls back rather than failing, and the marker records
# the logo that was actually baked in.
truncate -s $((9 * 1024 * 1024)) "$theme_dir/unlock.png"
rm -rf -- "${dest:?}"/*
: >"$calls"
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" 2>/dev/null ||
  fail "staging falls back rather than failing when unlock.png is oversized"
pass "staging falls back rather than failing when unlock.png is oversized"

assert_equals "$omarchy_path/logo.svg" \
  "$(sed -nE 's/^logo_source=(.*)$/\1/p' "$dest/.vfill-marker")" \
  "the staged marker records the fallback logo, not the oversized unlock.png"

# The size check must follow symlinks, the same way the [[ -f ]] test and the
# eventual read do -- otherwise a symlink to a huge file would slip past it.
rm -f -- "$theme_dir/unlock.png"
truncate -s $((9 * 1024 * 1024)) "$scratch/huge.png"
ln -s "$scratch/huge.png" "$theme_dir/unlock.png"
assert_equals "$omarchy_path/logo.svg" \
  "$(vfill_resolve_logo "$theme_dir" "$omarchy_path" 2>/dev/null)" \
  "a symlink to an oversized file is refused too"

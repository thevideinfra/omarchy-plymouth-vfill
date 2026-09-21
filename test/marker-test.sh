#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/theme-with-logo" "$scratch/theme-without-logo" "$scratch/omarchy"
printf 'fake png\n' >"$scratch/theme-with-logo/unlock.png"
printf 'fake svg\n' >"$scratch/omarchy/logo.svg"

assert_equals "$scratch/theme-with-logo/unlock.png" \
  "$(vfill_resolve_logo "$scratch/theme-with-logo" "$scratch/omarchy")" \
  "a theme shipping unlock.png supplies the logo"

assert_equals "$scratch/omarchy/logo.svg" \
  "$(vfill_resolve_logo "$scratch/theme-without-logo" "$scratch/omarchy")" \
  "a theme without unlock.png falls back to omarchy logo.svg"

marker="$scratch/.vfill-marker"
logo="$scratch/theme-with-logo/unlock.png"

vfill_write_marker "$marker" "140F1F" "DFEDE5" "$logo"
[[ -f $marker ]] || fail "the marker file is written"
pass "the marker file is written"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" ||
  fail "identical values match the marker"
pass "identical values match the marker"

vfill_marker_matches "$marker" "282A36" "DFEDE5" "$logo" &&
  fail "a changed background does not match"
pass "a changed background does not match"

vfill_marker_matches "$marker" "140F1F" "FFFFFF" "$logo" &&
  fail "a changed foreground does not match"
pass "a changed foreground does not match"

# Same path, different bytes: the hash must notice.
printf 'different bytes\n' >"$logo"
vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" &&
  fail "an edited logo with an unchanged path does not match"
pass "an edited logo with an unchanged path does not match"

vfill_marker_matches "$scratch/absent-marker" "140F1F" "DFEDE5" "$logo" &&
  fail "a missing marker never matches"
pass "a missing marker never matches"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$scratch/absent-logo.png" &&
  fail "a missing logo file never matches"
pass "a missing logo file never matches"

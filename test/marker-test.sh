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
logo_color="8BE9FD"

vfill_write_marker "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color"
[[ -f $marker ]] || fail "the marker file is written"
pass "the marker file is written"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" ||
  fail "identical values match the marker"
pass "identical values match the marker"

vfill_marker_matches "$marker" "282A36" "DFEDE5" "$logo" "$logo_color" &&
  fail "a changed background does not match"
pass "a changed background does not match"

vfill_marker_matches "$marker" "140F1F" "FFFFFF" "$logo" "$logo_color" &&
  fail "a changed foreground does not match"
pass "a changed foreground does not match"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" "FFFFFF" &&
  fail "a changed logo colour does not match"
pass "a changed logo colour does not match"

# Same path, different bytes: the hash must notice.
printf 'different bytes\n' >"$logo"
vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" &&
  fail "an edited logo with an unchanged path does not match"
pass "an edited logo with an unchanged path does not match"

vfill_marker_matches "$scratch/absent-marker" "140F1F" "DFEDE5" "$logo" "$logo_color" &&
  fail "a missing marker never matches"
pass "a missing marker never matches"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$scratch/absent-logo.png" "$logo_color" &&
  fail "a missing logo file never matches"
pass "a missing logo file never matches"

# A marker written before logo_color existed (no logo_color= line at all)
# must never match, so an upgrade always restages rather than silently
# keeping a stale fallback-logo colour.
old_marker="$scratch/.vfill-marker-old"
cat >"$old_marker" <<EOF
background=140F1F
foreground=DFEDE5
logo_source=$logo
logo_sha256=$(sha256sum "$logo" | cut -d' ' -f1)
EOF
vfill_marker_matches "$old_marker" "140F1F" "DFEDE5" "$logo" "$logo_color" &&
  fail "a marker without logo_color never matches"
pass "a marker without logo_color never matches"

# The optional sixth argument names the file whose bytes are hashed, so a
# privileged caller can hash the copy it published rather than re-reading a
# user-controlled path.
published="$scratch/published-logo.png"
printf 'published bytes\n' >"$published"
vfill_write_marker "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" "$published"
assert_equals "$(sha256sum "$published" | cut -d' ' -f1)" \
  "$(sed -nE 's/^logo_sha256=(.*)$/\1/p' "$marker")" \
  "the marker hashes the file named by the sixth argument"
assert_equals "$logo" "$(sed -nE 's/^logo_source=(.*)$/\1/p' "$marker")" \
  "the marker still records the logo path as its source"
assert_equals "$logo_color" "$(sed -nE 's/^logo_color=(.*)$/\1/p' "$marker")" \
  "the marker records the logo colour"

vfill_write_marker "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" "$scratch/absent.png" &&
  fail "a missing hash source refuses to write a marker"
pass "a missing hash source refuses to write a marker"

# vfill_marker_matches takes the same optional sixth argument: the file whose
# bytes are hashed. A privileged run compares against the verified copy it took,
# because hashing the user's path would mean root opening user-controlled content
# while it holds the retheme lock -- and hashing whatever was swapped in since.
copy="$scratch/verified-copy"
printf 'the verified bytes\n' >"$copy"
printf 'something else entirely\n' >"$logo"
vfill_write_marker "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" "$copy"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" "$copy" ||
  fail "a marker written from a verified copy matches when hashed against that copy"
pass "a marker written from a verified copy matches when hashed against that copy"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" &&
  fail "the same marker does not match when hashed against the path's own bytes"
pass "the same marker does not match when hashed against the path's own bytes"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" "$logo_color" "$scratch/absent-copy" &&
  fail "a missing hash source never matches"
pass "a missing hash source never matches"

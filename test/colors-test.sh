#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

cat >"$scratch/colors.toml" <<'EOF'
mode = "dark"

accent = "#8be9fd"

dark_background = "#21222c"
lighter_background = "#343746"
background = "#140F1F"

foreground = "#DFEDE5"
EOF

assert_equals "140F1F" "$(vfill_read_color "$scratch/colors.toml" background)" \
  "background is read from colors.toml"

assert_equals "DFEDE5" "$(vfill_read_color "$scratch/colors.toml" foreground)" \
  "foreground is read from colors.toml"

# dark_background and lighter_background must not satisfy a background lookup.
assert_equals "140F1F" "$(vfill_read_color "$scratch/colors.toml" background)" \
  "prefixed keys do not shadow background"

vfill_read_color "$scratch/colors.toml" nonexistent >/dev/null 2>&1 &&
  fail "a missing key returns non-zero"
pass "a missing key returns non-zero"

assert_equals "0.078, 0.059, 0.122" "$(vfill_hex_to_floats 140F1F)" \
  "hex converts to three Plymouth floats"

assert_equals "1.000, 1.000, 1.000" "$(vfill_hex_to_floats ffffff)" \
  "white converts to 1.000"

assert_equals "0.000, 0.000, 0.000" "$(vfill_hex_to_floats 000000)" \
  "black converts to 0.000"

#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

cat >"$scratch/colors.toml" <<'EOF'
mode = "dark"

bright_accent = "#ff79c6"
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

assert_equals "8be9fd" "$(vfill_read_color "$scratch/colors.toml" accent)" \
  "accent is read from colors.toml"

# bright_accent must not satisfy a lookup for accent.
assert_equals "8be9fd" "$(vfill_read_color "$scratch/colors.toml" accent)" \
  "prefixed keys do not shadow accent"

assert_equals "8be9fd" "$(vfill_logo_color "$scratch/colors.toml")" \
  "vfill_logo_color prefers accent when present"

cat >"$scratch/no-accent.toml" <<'EOF'
background = "#140F1F"
foreground = "#DFEDE5"
EOF

assert_equals "DFEDE5" "$(vfill_logo_color "$scratch/no-accent.toml")" \
  "vfill_logo_color falls back to foreground when accent is absent"

vfill_logo_color "$scratch/absent.toml" >/dev/null 2>&1 &&
  fail "vfill_logo_color fails when the file is missing"
pass "vfill_logo_color fails when the file is missing"

vfill_read_color "$scratch/colors.toml" nonexistent >/dev/null 2>&1 &&
  fail "a missing key returns non-zero"
pass "a missing key returns non-zero"

assert_equals "0.078, 0.059, 0.122" "$(vfill_hex_to_floats 140F1F)" \
  "hex converts to three Plymouth floats"

assert_equals "1.000, 1.000, 1.000" "$(vfill_hex_to_floats ffffff)" \
  "white converts to 1.000"

assert_equals "0.000, 0.000, 0.000" "$(vfill_hex_to_floats 000000)" \
  "black converts to 0.000"

# --- The colors.toml read is bounded. ---------------------------------------
# Root reads colors.toml six times per privileged retheme -- three in
# bin/omarchy-vfill-retheme, three more inside vfill_stage_theme -- and every one
# of them happens AFTER /run/lock/omarchy-vfill.lock is taken, on a path the user
# controls. sed's open of a FIFO with no writer never returns, so an unbounded
# read wedged root there and every later retheme, plus the whole of uninstall.sh's
# privileged transaction, waited on a lock nobody would ever release.
#
# Every call below goes through an OUTER timeout as well, so a regression cannot
# hang the suite -- and a status of 124 from that outer timeout is itself a
# failure, because it means the refusal was the test's doing and not the
# function's. This is the shape test/secure-open-test.sh uses for the logo.
read_under_outer_timeout() {
  local toml="$1" key="$2"
  timeout 15 bash -c '
    source "$1" || exit 1
    VFILL_OPEN_TIMEOUT=2 vfill_read_color "$2" "$3"
  ' bash "$ROOT/lib/vfill.sh" "$toml" "$key" 2>/dev/null
}

# The happy path still works while the bound is in force, and does not wait it out.
start=$SECONDS
value=$(read_under_outer_timeout "$scratch/colors.toml" background)
status=$?
elapsed=$((SECONDS - start))
assert_equals "0" "$status" "a normal read still succeeds with the bound in force"
assert_equals "140F1F" "$value" "a normal read still returns the colour with the bound in force"
((elapsed < 2)) ||
  fail "a normal read does not wait out the bound" "took ${elapsed}s with a 2 s bound"
pass "a normal read does not wait out the bound"

# The one this exists for: colors.toml as a FIFO with no writer.
fifo_toml="$scratch/colors-as-a-fifo.toml"
mkfifo "$fifo_toml"
start=$SECONDS
read_under_outer_timeout "$fifo_toml" background >/dev/null
status=$?
elapsed=$((SECONDS - start))

[[ $status -ne 0 ]] || fail "a colors.toml that is a FIFO is refused rather than read"
pass "a colors.toml that is a FIFO is refused rather than read"
[[ $status -ne 124 ]] ||
  fail "the FIFO refusal is the function's own bound, not the test's outer timeout" \
    "the call did not return within the outer 15 s: an unbounded read would hold the retheme lock here forever"
pass "the FIFO refusal is the function's own bound, not the test's outer timeout"
((elapsed < 10)) ||
  fail "the FIFO refusal is bounded by VFILL_OPEN_TIMEOUT" "took ${elapsed}s with a 2 s bound"
pass "the FIFO refusal is bounded by VFILL_OPEN_TIMEOUT"

# vfill_logo_color reads through the same function, so it is bounded too.
start=$SECONDS
timeout 15 bash -c '
  source "$1" || exit 1
  VFILL_OPEN_TIMEOUT=2 vfill_logo_color "$2"
' bash "$ROOT/lib/vfill.sh" "$fifo_toml" >/dev/null 2>&1
status=$?
elapsed=$((SECONDS - start))
[[ $status -ne 0 && $status -ne 124 ]] ||
  fail "vfill_logo_color is bounded on a FIFO too, by its own bound" "exit $status after ${elapsed}s"
pass "vfill_logo_color is bounded on a FIFO too, by its own bound"

# --- The bound applied is VFILL_OPEN_TIMEOUT, validated. --------------------
# A stub timeout records the bound it was handed and then runs the real one, so
# this reads the actual argv rather than inferring it from how long a call took.
real_timeout=$(command -v timeout) || fail "timeout(1) is available"
pass "timeout(1) is available"
bound_stubs="$scratch/bound-stubs"
bound_log="$scratch/bound.log"
mkdir -p "$bound_stubs"
cat >"$bound_stubs/timeout" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$bound_log"
exec "$real_timeout" "\$@"
STUB
chmod +x "$bound_stubs/timeout"

bound_for() {
  : >"$bound_log"
  env ${1:+VFILL_OPEN_TIMEOUT="$1"} PATH="$bound_stubs:$PATH" \
    bash -c 'source "$1" || exit 1; vfill_read_color "$2" background' \
    bash "$ROOT/lib/vfill.sh" "$scratch/colors.toml" >/dev/null 2>&1
  sed -nE 's/^-k 1 ([0-9]+) .*$/\1/p' "$bound_log" | head -1
}

assert_equals "20" "$(bound_for "")" "an unset VFILL_OPEN_TIMEOUT bounds the read at 20 s"
assert_equals "7" "$(bound_for 7)" "VFILL_OPEN_TIMEOUT sets the bound the read runs under"
assert_equals "20" "$(bound_for 'x[$(touch '"$scratch"'/pwned)]')" \
  "a VFILL_OPEN_TIMEOUT that is not a plain number of seconds falls back to 20"
[[ ! -e $scratch/pwned ]] ||
  fail "a rejected VFILL_OPEN_TIMEOUT never reaches a context that would run it"
pass "a rejected VFILL_OPEN_TIMEOUT never reaches a context that would run it"
assert_equals "20" "$(bound_for 0)" "a zero VFILL_OPEN_TIMEOUT -- no bound at all -- falls back to 20"

# --- No timeout(1) is a refusal, not an unbounded read. ---------------------
# Reading unbounded is the thing the bound exists to prevent, so a missing
# timeout must not be a licence to do it.
no_timeout="$scratch/no-timeout-path"
mkdir -p "$no_timeout"
for tool in sed head; do
  ln -sf "$(command -v "$tool")" "$no_timeout/$tool"
done
PATH="$no_timeout" command -v timeout >/dev/null &&
  fail "prerequisite: timeout is absent from the stripped PATH"
pass "prerequisite: timeout is absent from the stripped PATH"

# bash itself is named by absolute path, so the stripped PATH removes timeout(1)
# and nothing else -- a "refusal" caused by bash being unfindable would prove
# nothing.
message=$(PATH="$no_timeout" "$BASH" -c \
  'source "$1" || exit 1; vfill_read_color "$2" background' \
  bash "$ROOT/lib/vfill.sh" "$scratch/colors.toml" 2>&1 >/dev/null)
status=$?
[[ $status -ne 0 ]] || fail "a read with no timeout(1) is refused, not run unbounded" "$message"
pass "a read with no timeout(1) is refused, not run unbounded"
[[ $message == *"timeout(1) is not available"* && $message == *"$scratch/colors.toml"* ]] ||
  fail "the refusal says why and names the file" "$message"
pass "the refusal says why and names the file"

#!/bin/bash

# Exercises bin/omarchy-vfill-reboot with everything dangerous stubbed: the
# retheme is a recording stub with a settable exit code, sudo and pkexec only
# record what they were asked to run (they never run it), and systemctl records
# instead of rebooting. Nothing here runs as root and no reboot can happen.
#
# The point of every case is the same: the machine must not go down unless the
# boot splash it would come back up with is actually correct.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

REBOOT="$ROOT/bin/omarchy-vfill-reboot"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

stubs="$scratch/stubs"
log="$scratch/stub.log"
mkdir -p "$stubs"

for elevate in sudo pkexec; do
  cat >"$stubs/$elevate" <<STUB
#!/bin/bash
printf '$elevate %s\n' "\$*" >>"$log"
exit "\${STUB_ELEVATE_EXIT:-0}"
STUB
  chmod +x "$stubs/$elevate"
done

cat >"$stubs/systemctl" <<STUB
#!/bin/bash
printf 'systemctl %s\n' "\$*" >>"$log"
exit "\${STUB_SYSTEMCTL_EXIT:-0}"
STUB
chmod +x "$stubs/systemctl"

retheme="$scratch/omarchy-vfill-retheme"
cat >"$retheme" <<STUB
#!/bin/bash
printf 'retheme %s\n' "\$*" >>"$log"
exit "\${STUB_CHECK_EXIT:-0}"
STUB
chmod +x "$retheme"

home="$scratch/home"
theme_dir="$home/.local/state/omarchy/current/theme"
mkdir -p "$theme_dir"

# Always </dev/null, so run_root takes the pkexec branch and no password
# prompt can ever appear. VFILL_TEST is what makes VFILL_RETHEME honoured at
# all: without it the script uses the hardcoded /usr/local path, so the
# environment cannot choose what gets handed to pkexec.
run_reboot() {
  : >"$log"
  env -u STUB_ELEVATE_EXIT -u STUB_SYSTEMCTL_EXIT -u STUB_CHECK_EXIT "$@" \
    HOME="$home" PATH="$stubs:$PATH" VFILL_TEST=1 VFILL_RETHEME="$retheme" \
    bash "$REBOOT" </dev/null 2>&1
}

rebooted() {
  grep -q '^systemctl reboot$' "$log"
}

# --- Nothing changed: reboot straight away, without elevating. --------------
# --check exits 3, and only 3, when the splash is already current.

output=$(run_reboot STUB_CHECK_EXIT=3)
assert_equals "0" "$?" "succeeds when the splash is already current"
rebooted || fail "reboots when the splash is already current" "$log: $(cat "$log")"
pass "reboots when the splash is already current"
grep -qE '^(sudo|pkexec) ' "$log" &&
  fail "does not elevate when the splash is already current" "$(cat "$log")"
pass "does not elevate when the splash is already current"

# --- The theme changed and the update succeeded: reboot. --------------------
# --check exits 0 when a retheme is needed.

output=$(run_reboot STUB_CHECK_EXIT=0 STUB_ELEVATE_EXIT=0)
assert_equals "0" "$?" "succeeds when the splash needed an update and got one"
assert_equals "retheme --check --theme-dir $theme_dir
pkexec $retheme --theme-dir $theme_dir
systemctl reboot" "$(cat "$log")" \
  "checks unprivileged first, then elevates the retheme, then reboots"

# --- The theme changed and the update FAILED: do not reboot. ---------------

output=$(run_reboot STUB_CHECK_EXIT=0 STUB_ELEVATE_EXIT=1)
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when the splash update fails"
pass "exits non-zero when the splash update fails"
rebooted && fail "does NOT reboot when the splash update fails" "$(cat "$log")"
pass "does NOT reboot when the splash update fails"
[[ $output == *"not rebooting"* || $output == *"NOT rebooting"* ]] ||
  fail "says it is not rebooting when the splash update fails" "$output"
pass "says it is not rebooting when the splash update fails"

# --- The check itself failed: do not reboot, do not guess. ----------------
# Only 0 and 3 are "no problem". Everything else -- 1 included, which is what
# the retheme exits on a broken theme -- is an error and must not reboot.

for code in 1 2 4 127; do
  output=$(run_reboot STUB_CHECK_EXIT="$code")
  status=$?
  [[ $status -ne 0 ]] || fail "exits non-zero when the check exits $code" "$output"
  rebooted && fail "does NOT reboot when the check exits $code" "$(cat "$log")"
  grep -qE '^(sudo|pkexec) ' "$log" &&
    fail "does NOT elevate when the check exits $code" "$(cat "$log")"
  [[ $output == *"NOT rebooting"* ]] ||
    fail "says it is not rebooting when the check exits $code" "$output"
done
pass "a check exit that is neither 0 nor 3 refuses to reboot or elevate"

# --- A failing systemctl reboot is reported, not swallowed. ---------------

output=$(run_reboot STUB_CHECK_EXIT=3 STUB_SYSTEMCTL_EXIT=1)
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when systemctl reboot fails"
pass "exits non-zero when systemctl reboot fails"

# --- Nothing installed, or no active theme: refuse up front. --------------

output=$(VFILL_TEST=1 VFILL_RETHEME="$scratch/not-installed" HOME="$home" PATH="$stubs:$PATH" \
  bash "$REBOOT" </dev/null 2>&1)
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when the retheme is not installed"
pass "exits non-zero when the retheme is not installed"
[[ $output == *"not installed: $scratch/not-installed"* ]] ||
  fail "says the retheme is not installed, and names it" "$output"
pass "says the retheme is not installed, and names it"

# --- Driven against the REAL retheme --check, not a stub. -----------------
# The stub cases above all depend on the stub's contract being the real one, so
# these two drive the actual script. --check is unprivileged and writes nothing,
# and VFILL_THEME_DEST points at a scratch directory, so nothing in /usr/share
# is read or written and nothing runs as root.

real_dest="$scratch/real-dest"
mkdir -p "$real_dest"

run_reboot_real() {
  local real_home="$1"
  : >"$log"
  env HOME="$real_home" PATH="$stubs:$PATH" VFILL_TEST=1 \
    VFILL_RETHEME="$ROOT/bin/omarchy-vfill-retheme" \
    VFILL_THEME_DEST="$real_dest" \
    bash "$REBOOT" </dev/null 2>&1
}

# A theme directory that exists but holds no colors.toml: the real --check
# reports that as an error, distinctly from "already current". Before the exit
# code 3 this read as "nothing to do" and the machine rebooted on a broken
# theme.
broken_home="$scratch/broken-home"
mkdir -p "$broken_home/.local/state/omarchy/current/theme"
output=$(run_reboot_real "$broken_home")
status=$?
[[ $status -ne 0 ]] ||
  fail "exits non-zero when the real check finds a theme with no colors.toml" "$output"
pass "exits non-zero when the real check finds a theme with no colors.toml"
rebooted &&
  fail "does NOT reboot when the real check finds a theme with no colors.toml" "$(cat "$log")"
pass "does NOT reboot when the real check finds a theme with no colors.toml"
grep -qE '^(sudo|pkexec) ' "$log" &&
  fail "does NOT elevate when the real check finds a theme with no colors.toml" "$(cat "$log")"
pass "does NOT elevate when the real check finds a theme with no colors.toml"
[[ $output == *"colors.toml"* ]] ||
  fail "the real check's own message reaches the user" "$output"
pass "the real check's own message reaches the user"

# No theme directory at all. The script no longer tests for it itself -- the
# retheme reports it, and reports it as an error.
output=$(run_reboot_real "$scratch/no-such-home")
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when there is no active Omarchy theme" "$output"
pass "exits non-zero when there is no active Omarchy theme"
rebooted && fail "does NOT reboot when there is no active Omarchy theme" "$(cat "$log")"
pass "does NOT reboot when there is no active Omarchy theme"
[[ $output == *"no active Omarchy theme"* ]] ||
  fail "says there is no active Omarchy theme" "$output"
pass "says there is no active Omarchy theme"

# --check must have written nothing to the scratch destination.
assert_equals "" "$(find "$real_dest" -mindepth 1 | sort)" \
  "the real --check wrote nothing to the theme destination"

# --- VFILL_RETHEME is ignored unless VFILL_TEST is set. -------------------
# It is read unprivileged, before any elevation, and it names the program handed
# to pkexec -- so the environment must not be able to choose it on a real run.

: >"$log"
output=$(env -u VFILL_TEST HOME="$home" PATH="$stubs:$PATH" VFILL_RETHEME="$retheme" \
  bash "$REBOOT" </dev/null 2>&1)
status=$?
grep -q '^retheme ' "$log" &&
  fail "VFILL_RETHEME without VFILL_TEST does not run the named program" "$(cat "$log")"
pass "VFILL_RETHEME without VFILL_TEST does not run the named program"
grep -qE '^(sudo|pkexec) ' "$log" &&
  fail "VFILL_RETHEME without VFILL_TEST elevates nothing it named" "$(cat "$log")"
pass "VFILL_RETHEME without VFILL_TEST elevates nothing it named"
rebooted && fail "VFILL_RETHEME without VFILL_TEST does not reboot" "$(cat "$log")"
pass "VFILL_RETHEME without VFILL_TEST does not reboot"
[[ $status -ne 0 ]] ||
  fail "VFILL_RETHEME without VFILL_TEST exits non-zero (scratch HOME has no theme)" "$output"
pass "VFILL_RETHEME without VFILL_TEST exits non-zero"
[[ $output != *"$retheme"* ]] ||
  fail "the ignored VFILL_RETHEME path is never named in the output" "$output"
pass "the ignored VFILL_RETHEME path is never named in the output"

# --- The desktop entry points at the command and shows its progress. ------
# The rebuild takes about 90 seconds, so Terminal=true is load-bearing: the
# user has to be able to see it working, and see it fail.

entry="$ROOT/share/omarchy-vfill-reboot.desktop"
[[ -f $entry ]] || fail "the desktop entry exists in the checkout"
pass "the desktop entry exists in the checkout"

assert_equals "[Desktop Entry]" "$(head -1 "$entry")" \
  "the desktop entry starts with the [Desktop Entry] group"
for want in \
  "Type=Application" \
  "Name=Reboot with updated boot splash" \
  "Exec=/usr/local/bin/omarchy-vfill-reboot" \
  "Terminal=true" \
  "Icon=system-reboot" \
  "Categories=System;"; do
  grep -qxF "$want" "$entry" ||
    fail "the desktop entry declares $want" "$(cat "$entry")"
done
pass "the desktop entry declares the expected name, exec, terminal, icon and categories"

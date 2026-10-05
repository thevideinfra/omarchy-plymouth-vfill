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
# prompt can ever appear.
run_reboot() {
  : >"$log"
  env -u STUB_ELEVATE_EXIT -u STUB_SYSTEMCTL_EXIT -u STUB_CHECK_EXIT "$@" \
    HOME="$home" PATH="$stubs:$PATH" VFILL_RETHEME="$retheme" \
    bash "$REBOOT" </dev/null 2>&1
}

rebooted() {
  grep -q '^systemctl reboot$' "$log"
}

# --- Nothing changed: reboot straight away, without elevating. --------------
# --check exits 1 when the splash is already current.

output=$(run_reboot STUB_CHECK_EXIT=1)
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
# Exit codes above 1 are real errors from the retheme, not "already current".

output=$(run_reboot STUB_CHECK_EXIT=2)
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when the check errors"
pass "exits non-zero when the check errors"
rebooted && fail "does NOT reboot when the check errors" "$(cat "$log")"
pass "does NOT reboot when the check errors"

# --- A failing systemctl reboot is reported, not swallowed. ---------------

output=$(run_reboot STUB_CHECK_EXIT=1 STUB_SYSTEMCTL_EXIT=1)
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when systemctl reboot fails"
pass "exits non-zero when systemctl reboot fails"

# --- Nothing installed, or no active theme: refuse up front. --------------

output=$(VFILL_RETHEME="$scratch/not-installed" HOME="$home" PATH="$stubs:$PATH" \
  bash "$REBOOT" </dev/null 2>&1)
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when the retheme is not installed"
pass "exits non-zero when the retheme is not installed"
[[ $output == *"not installed: $scratch/not-installed"* ]] ||
  fail "says the retheme is not installed, and names it" "$output"
pass "says the retheme is not installed, and names it"

: >"$log"
output=$(HOME="$scratch/no-such-home" PATH="$stubs:$PATH" VFILL_RETHEME="$retheme" \
  bash "$REBOOT" </dev/null 2>&1)
status=$?
[[ $status -ne 0 ]] || fail "exits non-zero when there is no active Omarchy theme"
pass "exits non-zero when there is no active Omarchy theme"
rebooted && fail "does NOT reboot when there is no active Omarchy theme" "$(cat "$log")"
pass "does NOT reboot when there is no active Omarchy theme"

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

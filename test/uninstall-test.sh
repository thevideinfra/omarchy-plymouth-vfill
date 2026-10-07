#!/bin/bash

# Exercises uninstall.sh without any real privilege. HOME is a scratch
# directory, and sudo/pkexec are stubs that only record the command they were
# asked to run (NUL-separated) and exit -- nothing they are handed ever runs
# with privilege. The recorded root-shell script is then replayed inside an
# unprivileged user namespace against scratch paths substituted for
# /usr/share/plymouth/themes/omarchy-vfill, /usr/local/lib/omarchy-vfill and the
# lock, with plymouth-set-default-theme and the initramfs tool stubbed.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

command -v unshare >/dev/null || fail "unshare is available"
unshare -r true 2>/dev/null || fail "unprivileged user namespaces are available"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

stubs="$scratch/stubs"
log="$scratch/stub.log"
argv="$scratch/root-argv"
mkdir -p "$stubs"

for elevate in sudo pkexec; do
  cat >"$stubs/$elevate" <<EOF
#!/bin/bash
printf '%s\0' "\$@" >"$argv"
exit "\${STUB_ELEVATE_EXIT:-0}"
EOF
  chmod +x "$stubs/$elevate"
done

cat >"$stubs/plymouth-set-default-theme" <<EOF
#!/bin/bash
printf 'plymouth-set-default-theme %s\n' "\$*" >>"$log"
exit "\${STUB_SETDEFAULT_EXIT:-0}"
EOF
cat >"$stubs/limine-mkinitcpio" <<EOF
#!/bin/bash
printf 'limine-mkinitcpio %s\n' "\$*" >>"$log"
exit "\${STUB_REBUILD_EXIT:-0}"
EOF
chmod +x "$stubs/plymouth-set-default-theme" "$stubs/limine-mkinitcpio"

home="$scratch/home"
hook="$home/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh"

run_uninstall() {
  rm -f -- "$argv"
  mkdir -p "$(dirname "$hook")"
  printf '#!/bin/bash\n' >"$hook"
  HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/uninstall.sh" </dev/null
}

# --- The privileged transaction is handed the expected arguments. ---------

output=$(run_uninstall 2>&1)
assert_equals "0" "$?" "uninstall succeeds when the privileged step succeeds"
[[ ! -e $hook ]] || fail "a successful uninstall removes the hook"
pass "a successful uninstall removes the hook"

# --- Uninstall succeeds just as well when there is no hook at all -- the
#     normal case now that install.sh no longer creates one. --------------

rm -f -- "$argv" "$hook"
output=$(HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/uninstall.sh" </dev/null 2>&1)
assert_equals "0" "$?" "uninstall succeeds with no hook present"
[[ ! -e $hook ]] || fail "uninstall with no hook still leaves no hook behind"
pass "uninstall with no hook still leaves no hook behind"

mapfile -d '' -t recorded <"$argv"
assert_equals "/bin/bash -c" "${recorded[0]} ${recorded[1]}" \
  "the privileged step is a single root shell"
assert_equals "bash /usr/share/plymouth/themes/omarchy-vfill /usr/local/lib/omarchy-vfill /run/lock/omarchy-vfill.lock /usr/local/bin/omarchy-vfill-reboot /usr/local/share/applications/omarchy-vfill-reboot.desktop /etc/polkit-1/rules.d/49-omarchy-vfill.rules /etc/polkit-1/rules.d/49-omarchy-vfill.rules limine-mkinitcpio" \
  "${recorded[*]:3}" \
  "the root shell is given the theme, prefix, lock, mode-reboot artefacts, mode-auto rule (twice: the path in use and the default) and rebuild command"

# The rule path is overridable for the tests -- but only with
# VFILL_TEST_POLKIT_RULES_DIR=1 and only inside a scratch prefix, because it is
# read here, unprivileged, and handed to root as an argv word. The DEFAULT path is
# handed over as well, always, so an override can never be the only path this
# uninstall cleans up: a single line in a shell profile used to be enough to leave
# passwordless root installed. Nothing privileged runs in either case -- the
# elevate stub only records its arguments.
rm -f -- "$argv"
scratch_rules_dir=$(readlink -m "$scratch/polkit-rules.d")
HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$scratch_rules_dir" \
  bash "$ROOT/uninstall.sh" </dev/null >/dev/null 2>&1
mapfile -d '' -t recorded <"$argv"
assert_equals "$scratch_rules_dir/49-omarchy-vfill.rules" "${recorded[9]}" \
  "the rule path handed to the root shell is overridable for the tests"
assert_equals "/etc/polkit-1/rules.d/49-omarchy-vfill.rules" "${recorded[10]}" \
  "the default rule path is handed over as well, even when the override is set"

# An override the gate refuses is ignored, never fatal: an uninstall that exits
# because a shell profile set a variable would leave passwordless root installed,
# which is the opposite of what it is for. The default path is still removed.
for bad in no-marker outside-scratch; do
  rm -f -- "$argv"
  case "$bad" in
    no-marker) env_marker="" bad_dir="$scratch_rules_dir" ;;
    outside-scratch) env_marker=1 bad_dir=/etc/sudoers.d ;;
  esac
  output=$(env HOME="$home" PATH="$stubs:$PATH" \
    ${env_marker:+VFILL_TEST_POLKIT_RULES_DIR=$env_marker} \
    VFILL_POLKIT_RULES_DIR="$bad_dir" \
    bash "$ROOT/uninstall.sh" </dev/null 2>&1)
  status=$?
  assert_equals "0" "$status" "a refused VFILL_POLKIT_RULES_DIR does not stop the uninstall: $bad"
  [[ $output == *"refusing VFILL_POLKIT_RULES_DIR=$bad_dir"* ]] ||
    fail "the uninstall says it refused the override: $bad" "$output"
  [[ $output == *"removing /etc/polkit-1/rules.d/49-omarchy-vfill.rules instead"* ]] ||
    fail "the uninstall says which rule path it removes instead: $bad" "$output"
  mapfile -d '' -t recorded <"$argv"
  assert_equals "/etc/polkit-1/rules.d/49-omarchy-vfill.rules" "${recorded[9]}" \
    "a refused override removes the default rule path: $bad"
  [[ ${recorded[9]} != *"$bad_dir"* ]] ||
    fail "a refused override is not the path handed to root: $bad" "${recorded[9]}"
done
pass "a refused VFILL_POLKIT_RULES_DIR is ignored and the default rule is removed anyway"

# --- A failed privileged step restores the hook and does not claim the theme
#     is intact. ------------------------------------------------------------

output=$(STUB_ELEVATE_EXIT=1 run_uninstall 2>&1)
[[ $? -ne 0 ]] || fail "uninstall fails when the privileged step fails"
pass "uninstall fails when the privileged step fails"
[[ -f $hook ]] || fail "a failed uninstall restores the hook"
pass "a failed uninstall restores the hook"
[[ $output != *"still installed"* ]] ||
  fail "the failure message does not claim the theme is still installed" "$output"
pass "the failure message does not claim the theme is still installed"
[[ $output == *"re-run ./uninstall.sh"* ]] ||
  fail "the failure message says to re-run uninstall" "$output"
pass "the failure message says to re-run uninstall"

# --- Replay the root shell against scratch paths. -------------------------

mapfile -d '' -t recorded <"$argv"
script="${recorded[2]}"

reboot_bin="$scratch/local-bin/omarchy-vfill-reboot"
desktop_entry="$scratch/applications/omarchy-vfill-reboot.desktop"
# Mode auto's rule is replayed against a scratch directory, never against the
# real /etc/polkit-1/rules.d.
polkit_rule="$scratch/polkit-rules.d/49-omarchy-vfill.rules"
# The seventh argument is the DEFAULT rule path, which the root shell removes
# alongside whatever path is in use. It too is a scratch path here: the real
# /etc/polkit-1/rules.d/49-omarchy-vfill.rules is a live file on a machine
# installed in mode auto and is never written or removed by this suite.
polkit_rule_default="$scratch/default-polkit-rules.d/49-omarchy-vfill.rules"
mkdir -p "$(dirname "$polkit_rule_default")"

replay() {
  local dest="$1" prefix="$2"
  env PATH="$stubs:$PATH" \
    unshare -r /bin/bash -c "$script" bash "$dest" "$prefix" "$scratch/lock" \
      "$reboot_bin" "$desktop_entry" "$polkit_rule" "$polkit_rule_default" \
      limine-mkinitcpio
}

# Mode reboot's artefacts, as a machine installed in that mode would have them.
install_mode_reboot_artefacts() {
  mkdir -p "$(dirname "$reboot_bin")" "$(dirname "$desktop_entry")"
  printf '#!/bin/bash\n' >"$reboot_bin"
  chmod +x "$reboot_bin"
  printf '[Desktop Entry]\n' >"$desktop_entry"
}

# Mode auto's rule, as a machine installed in that mode would have it -- at the
# path in use and at the default path, which a previous install without an
# override would have used.
install_mode_auto_rule() {
  mkdir -p "$(dirname "$polkit_rule")" "$(dirname "$polkit_rule_default")"
  printf 'polkit.addRule(function(action, subject) {});\n' >"$polkit_rule"
  printf 'polkit.addRule(function(action, subject) {});\n' >"$polkit_rule_default"
}

dest="$scratch/themes/omarchy-vfill"
prefix="$scratch/prefix"
mkdir -p "$dest" "$dest.new.123" "$dest.old.456" "$prefix/bin" "$scratch/themes/omarchy"
touch "$dest/.vfill-marker"
printf 'reboot\n' >"$prefix/mode"
install_mode_reboot_artefacts
install_mode_auto_rule
: >"$log"
replay "$dest" "$prefix"
assert_equals "0" "$?" "the root shell succeeds"
assert_equals "plymouth-set-default-theme omarchy
limine-mkinitcpio " "$(cat "$log")" "the root shell restores the default, then rebuilds"
assert_equals "omarchy" "$(ls "$scratch/themes")" \
  "the root shell removes the theme and any stranded .new/.old siblings, and nothing else"
[[ ! -e $prefix ]] || fail "the root shell removes the prefix"
pass "the root shell removes the prefix (and with it the recorded mode)"

# Mode reboot's root-owned artefacts live outside the prefix, so removing the
# prefix is not enough -- they have to be named.
[[ ! -e $reboot_bin ]] || fail "the root shell removes the reboot command"
pass "the root shell removes the reboot command"
[[ ! -e $desktop_entry ]] || fail "the root shell removes the desktop entry"
pass "the root shell removes the desktop entry"

# Mode auto's polkit rule, likewise: it lives in /etc, outside the prefix, and
# has to be named to go.
[[ ! -e $polkit_rule ]] || fail "the root shell removes mode auto's polkit rule"
pass "the root shell removes mode auto's polkit rule"
[[ ! -e $polkit_rule_default ]] ||
  fail "the root shell removes the rule at the default path as well as the one in use"
pass "the root shell removes the rule at the default path as well as the one in use"
[[ -d $(dirname "$polkit_rule") ]] ||
  fail "the root shell removes the rule, not the polkit rules directory"
pass "the root shell removes the rule, not the polkit rules directory"

# A machine installed in mode theme-set or manual has none of them, and the
# removal must not turn that into a failure.
mkdir -p "$dest" "$prefix"
: >"$log"
replay "$dest" "$prefix"
assert_equals "0" "$?" "the root shell succeeds when mode reboot's and mode auto's artefacts are absent"
[[ ! -e $polkit_rule ]] || fail "an absent polkit rule stays absent"
pass "removing an absent polkit rule is not an error"

# The root shell waits for the retheme lock.
mkdir -p "$dest" "$prefix"
: >"$log"
exec {held}>>"$scratch/lock"
flock "$held" || fail "the test can take the lock"
replay "$dest" "$prefix" {held}>&- &
waiter=$!
sleep 2
assert_equals "" "$(cat "$log")" "the root shell waits while a retheme holds the lock"
[[ -d $dest ]] || fail "the waiting root shell removes nothing"
pass "the waiting root shell removes nothing"
exec {held}>&-
wait "$waiter"
assert_equals "0" "$?" "the root shell completes once the lock is released"
[[ ! -e $dest ]] || fail "the root shell removes the theme after the lock is released"
pass "the root shell removes the theme after the lock is released"

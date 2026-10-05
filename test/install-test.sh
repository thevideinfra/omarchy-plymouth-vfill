#!/bin/bash

# Runs install.sh as the user with a scratch HOME. sudo, pkexec and omarchy are
# stubs that only record what they were asked to run (NUL-separated) and exit,
# so nothing privileged ever executes.
#
# The recorded root-shell script is both inspected and, separately, replayed
# inside an unprivileged user namespace against scratch paths substituted for
# /usr/local/lib/omarchy-vfill, /usr/local/bin/omarchy-vfill-reboot and the
# desktop entry -- so the artefacts each mode installs and removes can be
# checked without ever writing to /usr/local. The replay is handed a fake repo
# whose retheme is a recording stub, so the exec at the end of the transaction
# runs nothing real.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

command -v unshare >/dev/null || fail "unshare is available"
unshare -r true 2>/dev/null || fail "unprivileged user namespaces are available"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

stubs="$scratch/stubs"
argv="$scratch/root-argv"
log="$scratch/stub.log"
mkdir -p "$stubs"

for elevate in sudo pkexec; do
  cat >"$stubs/$elevate" <<STUB
#!/bin/bash
printf '%s\0' "\$@" >"$argv"
exit "\${STUB_ELEVATE_EXIT:-0}"
STUB
  chmod +x "$stubs/$elevate"
done
for other in omarchy plymouth-set-default-theme limine-mkinitcpio; do
  printf '#!/bin/bash\nexit 0\n' >"$stubs/$other"
  chmod +x "$stubs/$other"
done

home="$scratch/home"
mkdir -p "$home"
hook="$home/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh"
theme_dir="$home/.local/state/omarchy/current/theme"
PREFIX=/usr/local/lib/omarchy-vfill
MANUAL_COMMAND="sudo $PREFIX/bin/omarchy-vfill-retheme --force"

# First argument is what install.sh reads on stdin; the rest are its own
# arguments. An empty first argument means an empty stdin, i.e. no answer.
run_install() {
  local answers="$1"
  shift
  rm -f -- "$argv"
  printf '%s' "$answers" |
    HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" "$@" 2>&1
}

# The privileged step is one root shell:
#   /bin/bash -c <script> bash <prefix> <repo> <theme_dir> <mode> \
#                              <reboot_bin> <desktop_entry>
load_root_argv() {
  [[ -f $argv ]] || fail "the privileged step was invoked"
  mapfile -d '' -t RECORDED <"$argv"
}

# --- With no answer at all, the default mode is taken. ---------------------

output=$(run_install "")
assert_equals "0" "$?" "install succeeds when the privileged step succeeds"

load_root_argv
assert_equals "/bin/bash -c" "${RECORDED[0]} ${RECORDED[1]}" \
  "the privileged step is a single root shell"
[[ ${RECORDED[2]} == *'omarchy-vfill-retheme" --force --theme-dir "$theme_dir"'* ]] ||
  fail "the privileged step runs the installed retheme with --force" "${RECORDED[2]}"
pass "the privileged step runs the installed retheme with --force"
assert_equals "$ROOT" "${RECORDED[5]}" "the privileged step is given the checkout as its source"
assert_equals "$theme_dir" "${RECORDED[6]}" \
  "the privileged step is given the user's theme directory"
assert_equals "theme-set" "${RECORDED[7]}" \
  "no answer takes the default mode, theme-set"
assert_equals "/usr/local/bin/omarchy-vfill-reboot" "${RECORDED[8]}" \
  "the privileged step is told where the reboot command goes"
assert_equals "/usr/local/share/applications/omarchy-vfill-reboot.desktop" "${RECORDED[9]}" \
  "the privileged step is told where the desktop entry goes"

[[ $output == *"How should the boot splash follow your desktop theme?"* ]] ||
  fail "the mode question is asked" "$output"
pass "the mode question is asked"
for line in \
  "1) At theme change" \
  "2) Before reboot" \
  "3) Manually"; do
  [[ $output == *"$line"* ]] || fail "the mode question offers: $line" "$output"
done
pass "the mode question offers all three modes"

# --- Mode theme-set installs the hook, rendered and executable. -----------

[[ -f $hook ]] || fail "mode theme-set installs the theme-set hook"
pass "mode theme-set installs the theme-set hook"
assert_equals "755" "$(stat -c %a "$hook")" "the installed hook is mode 0755"
grep -qF "$PREFIX/bin/omarchy-vfill-retheme" "$hook" ||
  fail "the hook points at the installed root-owned retheme" "$(cat "$hook")"
pass "the hook points at the installed root-owned retheme"
grep -q '__RETHEME_PATH__' "$hook" &&
  fail "the hook has no placeholder left in it" "$(cat "$hook")"
pass "the hook has no placeholder left in it"
bash -n "$hook" || fail "the installed hook parses as bash"
pass "the installed hook parses as bash"

# --- Each answer picks the mode it names. --------------------------------

for pair in "1:theme-set" "2:reboot" "3:manual"; do
  answer=${pair%%:*}
  want=${pair##*:}
  rm -f -- "$hook"
  run_install "$answer"$'\n' >/dev/null
  assert_equals "0" "$?" "install succeeds for answer $answer"
  load_root_argv
  assert_equals "$want" "${RECORDED[7]}" "answer $answer selects mode $want"
done

# --- Only mode theme-set creates a hook. --------------------------------

for answer in 2 3; do
  rm -f -- "$hook"
  run_install "$answer"$'\n' >/dev/null
  [[ ! -e $hook ]] || fail "answer $answer creates no theme-set hook"
done
pass "modes reboot and manual create no theme-set hook"

# --- Bad input re-asks rather than guessing. ----------------------------

rm -f -- "$hook"
output=$(run_install $'bogus\n9\n3\n')
assert_equals "0" "$?" "install succeeds once a valid answer is given"
load_root_argv
assert_equals "manual" "${RECORDED[7]}" \
  "a bad answer is not accepted; the next valid answer is used"
assert_equals "2" "$(grep -c 'Please answer 1, 2 or 3' <<<"$output")" \
  "each bad answer is refused and the question re-asked"

# --- --mode works non-interactively and is not second-guessed. -----------

rm -f -- "$hook"
output=$(run_install "" --mode reboot)
assert_equals "0" "$?" "--mode reboot succeeds with no stdin at all"
load_root_argv
assert_equals "reboot" "${RECORDED[7]}" "--mode reboot selects mode reboot"
[[ $output != *"How should the boot splash"* ]] ||
  fail "--mode asks no question" "$output"
pass "--mode asks no question"
[[ ! -e $hook ]] || fail "--mode reboot creates no theme-set hook"
pass "--mode reboot creates no theme-set hook"

# --- An unknown --mode is refused before anything is touched. ------------

rm -f -- "$argv"
output=$(HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" --mode bogus </dev/null 2>&1)
status=$?
[[ $status -ne 0 ]] || fail "an unknown --mode is refused"
pass "an unknown --mode is refused"
[[ ! -f $argv ]] || fail "an unknown --mode runs nothing privileged"
pass "an unknown --mode runs nothing privileged"
[[ $output == *bogus* ]] || fail "the refusal names the rejected mode" "$output"
pass "the refusal names the rejected mode"

rm -f -- "$argv"
HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" --bogus-option </dev/null >/dev/null 2>&1
[[ $? -ne 0 ]] || fail "an unknown option is refused"
pass "an unknown option is refused"
[[ ! -f $argv ]] || fail "an unknown option runs nothing privileged"
pass "an unknown option runs nothing privileged"

# --- Switching modes on re-install removes the previous mode's hook. -----

rm -f -- "$hook"
run_install "" --mode theme-set >/dev/null
[[ -f $hook ]] || fail "prerequisite: mode theme-set installed the hook"
pass "prerequisite: mode theme-set installed the hook"

output=$(run_install "" --mode manual)
assert_equals "0" "$?" "re-installing in mode manual succeeds"
[[ ! -e $hook ]] || fail "switching from theme-set to manual removes the hook"
pass "switching from theme-set to manual removes the hook"
[[ $output == *"removing the theme-set hook"* ]] ||
  fail "the switch says the hook was removed" "$output"
pass "the switch says the hook was removed"

# --- Every mode says how the splash gets updated, and always names the
#     manual command. ----------------------------------------------------

for pair in \
  "theme-set:at theme change" \
  "reboot:Reboot with updated boot splash" \
  "manual:by hand"; do
  mode=${pair%%:*}
  phrase=${pair#*:}
  rm -f -- "$hook"
  output=$(run_install "" --mode "$mode")
  [[ $output == *"$MANUAL_COMMAND"* ]] ||
    fail "mode $mode names the always-available manual command" "$output"
  [[ $output == *"$phrase"* ]] ||
    fail "mode $mode states how the splash gets updated ($phrase)" "$output"
done
pass "every mode states how the splash is updated and names the manual command"

# --- A failed privileged step installs no hook and says so. -------------

rm -f -- "$hook"
output=$(STUB_ELEVATE_EXIT=1 run_install "" --mode theme-set)
[[ $? -ne 0 ]] || fail "install fails when the privileged step fails"
pass "install fails when the privileged step fails"
[[ ! -e $hook ]] || fail "a failed privileged step installs no hook"
pass "a failed privileged step installs no hook"

# --- Replay the root transaction against scratch paths. -----------------

fakerepo="$scratch/fakerepo"
mkdir -p "$fakerepo/bin" "$fakerepo/lib" "$fakerepo/theme" "$fakerepo/share"
cat >"$fakerepo/bin/omarchy-vfill-retheme" <<STUB
#!/bin/bash
printf 'retheme %s\n' "\$*" >>"$log"
exit 0
STUB
chmod +x "$fakerepo/bin/omarchy-vfill-retheme"
: >"$fakerepo/lib/vfill.sh"
: >"$fakerepo/theme/omarchy-vfill.plymouth"
: >"$fakerepo/theme/omarchy-vfill.script"
cp "$ROOT/bin/omarchy-vfill-reboot" "$fakerepo/bin/omarchy-vfill-reboot"
cp "$ROOT/share/omarchy-vfill-reboot.desktop" "$fakerepo/share/omarchy-vfill-reboot.desktop"

run_install "" --mode reboot >/dev/null
load_root_argv
script="${RECORDED[2]}"

prefix="$scratch/prefix"
reboot_bin="$scratch/local-bin/omarchy-vfill-reboot"
desktop_entry="$scratch/applications/omarchy-vfill-reboot.desktop"

# unshare -r maps our uid to 0, so a file the transaction created as root:root
# shows up outside the namespace as owned by us. A different -o/-g would not:
# only uid 0 is mapped inside, so install would fail outright.
NS_ROOT="$(id -u):$(id -g)"

replay() {
  local mode="$1"
  : >"$log"
  env PATH="$stubs:$PATH" unshare -r /bin/bash -c "$script" \
    bash "$prefix" "$fakerepo" "$theme_dir" "$mode" "$reboot_bin" "$desktop_entry"
}

replay reboot
assert_equals "0" "$?" "the root transaction succeeds in mode reboot"
assert_equals "retheme --force --theme-dir $theme_dir" "$(cat "$log")" \
  "the root transaction ends by running the installed retheme once"

assert_equals "reboot" "$(cat "$prefix/mode")" "the root transaction records the mode"
assert_equals "644" "$(stat -c %a "$prefix/mode")" "the mode file is 0644"
assert_equals "$NS_ROOT" "$(stat -c %u:%g "$prefix/mode")" "the mode file is root-owned"
assert_equals "755" "$(stat -c %a "$prefix/bin/omarchy-vfill-retheme")" \
  "the installed retheme is 0755"

[[ -f $reboot_bin ]] || fail "mode reboot installs the reboot command"
pass "mode reboot installs the reboot command"
assert_equals "755" "$(stat -c %a "$reboot_bin")" "the reboot command is 0755"
assert_equals "$NS_ROOT" "$(stat -c %u:%g "$reboot_bin")" "the reboot command is root-owned"
cmp -s "$ROOT/bin/omarchy-vfill-reboot" "$reboot_bin" ||
  fail "the installed reboot command matches the checkout"
pass "the installed reboot command matches the checkout"

[[ -f $desktop_entry ]] || fail "mode reboot installs the desktop entry"
pass "mode reboot installs the desktop entry"
assert_equals "644" "$(stat -c %a "$desktop_entry")" "the desktop entry is 0644"
assert_equals "$NS_ROOT" "$(stat -c %u:%g "$desktop_entry")" "the desktop entry is root-owned"
cmp -s "$ROOT/share/omarchy-vfill-reboot.desktop" "$desktop_entry" ||
  fail "the installed desktop entry matches the checkout"
pass "the installed desktop entry matches the checkout"

# Switching away from mode reboot takes both root-owned artefacts with it, in
# the same privileged transaction -- so the user authenticates only once.
for mode in manual theme-set; do
  replay "$mode"
  assert_equals "0" "$?" "the root transaction succeeds in mode $mode"
  assert_equals "$mode" "$(cat "$prefix/mode")" "mode $mode is recorded"
  [[ ! -e $reboot_bin ]] || fail "mode $mode removes the reboot command"
  [[ ! -e $desktop_entry ]] || fail "mode $mode removes the desktop entry"
  # Put them back for the next iteration's removal to be a real removal.
  replay reboot >/dev/null
  [[ -f $reboot_bin && -f $desktop_entry ]] ||
    fail "re-installing mode reboot puts the artefacts back"
done
pass "switching away from mode reboot removes its command and desktop entry"
pass "re-installing mode reboot puts its artefacts back"

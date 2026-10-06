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

# The privileged-transaction replay needs an unprivileged user namespace. Where
# there is none, those assertions are skipped with a printed reason rather than
# failing the suite: the machine's kernel configuration is not this project's
# bug, and everything before the replay still runs.
SKIP_NAMESPACE=""
if ! command -v unshare >/dev/null; then
  SKIP_NAMESPACE="unshare is not installed"
elif ! unshare -r true 2>/dev/null; then
  SKIP_NAMESPACE="unprivileged user namespaces are unavailable"
fi

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

# --- --mode with no value at all is refused, not silently defaulted. ------
# It used to leave MODE empty, which skipped the validation, fell into the
# prompt and -- with no tty -- took the default: the one mode that adds a
# recurring password prompt.

rm -f -- "$hook"
for bad in "last-argument" "empty-value"; do
  rm -f -- "$argv"
  if [[ $bad == last-argument ]]; then
    output=$(HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" --mode </dev/null 2>&1)
  else
    output=$(HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" --mode "" </dev/null 2>&1)
  fi
  status=$?
  [[ $status -ne 0 ]] || fail "--mode with an $bad is refused" "$output"
  [[ ! -f $argv ]] || fail "--mode with an $bad runs nothing privileged" "$output"
  [[ $output != *"How should the boot splash"* ]] ||
    fail "--mode with an $bad does not fall through to the prompt" "$output"
  [[ $output == *"--mode needs a value"* ]] ||
    fail "--mode with an $bad says the value is missing" "$output"
  [[ ! -e $hook ]] || fail "--mode with an $bad installs no hook"
done
pass "--mode with a missing or empty value is refused, prompts nothing and installs nothing"

# --- The legacy-migration prompt on a closed stdin aborts cleanly. --------
# `read` leaves its variable UNSET on a read error -- a closed stdin, which is
# what a desktop launch has -- so under set -u install.sh died with
# "reply: unbound variable" and exit 127 instead of taking the safe answer.

legacy_home="$scratch/legacy-home"
mkdir -p "$legacy_home/.config/omarchy/plymouth-vfill"
rm -f -- "$argv"
output=$(HOME="$legacy_home" PATH="$stubs:$PATH" \
  bash "$ROOT/install.sh" --mode manual 0<&- 2>&1)
status=$?
[[ $status -ne 0 ]] || fail "a refused legacy migration exits non-zero" "$output"
pass "a refused legacy migration exits non-zero"
[[ $output != *"unbound variable"* ]] ||
  fail "the legacy-migration prompt survives a closed stdin" "$output"
pass "the legacy-migration prompt survives a closed stdin"
[[ $output == *"aborted; nothing was changed"* ]] ||
  fail "a closed stdin takes the safe answer and says so" "$output"
pass "a closed stdin takes the safe answer and says so"
[[ ! -f $argv ]] || fail "an aborted legacy migration runs nothing privileged"
pass "an aborted legacy migration runs nothing privileged"
[[ -d $legacy_home/.config/omarchy/plymouth-vfill ]] ||
  fail "an aborted legacy migration removes nothing"
pass "an aborted legacy migration removes nothing"

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
  "reboot:Plymouth vfill reboot" \
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

# The mode file and mode reboot's artefacts are settled inside the same
# transaction, before its final retheme, so "nothing else was changed" was a
# lie whenever it failed at the retheme.
[[ $output != *"nothing else was changed"* ]] ||
  fail "the failure message does not claim nothing else was changed" "$output"
pass "the failure message does not claim nothing else was changed"
[[ $output == *"may already be in place"* ]] ||
  fail "the failure message says what may already be in place" "$output"
pass "the failure message says what may already be in place"
[[ $output == *"No theme-set hook was installed"* ]] ||
  fail "the failure message says no hook was installed" "$output"
pass "the failure message says no hook was installed"

# --- The transaction's copies landed and only its retheme failed. ---------
# STUB_ELEVATE_EXIT=1 above refuses before running anything, so it only ever
# exercised the case where nothing happened. The interesting failure is the
# other one: the transaction stages the prefix, writes the mode file and settles
# mode reboot's artefacts, and only then execs the retheme -- which swaps the
# live theme directory in and repoints the Plymouth default before it rebuilds
# the initramfs. A rebuild or marker failure therefore exits non-zero with the
# live theme already replaced, and the message must not say otherwise.
#
# Replayed as the user, not as root: the elevate stub re-runs install.sh's own
# transaction script with scratch paths substituted for /usr/local and a repo
# whose retheme exits 1, through an `install` shim that drops the -o/-g
# ownership flags an unprivileged user cannot honour. No namespace is needed, so
# this runs everywhere.

partial="$scratch/partial"
mkdir -p "$partial/stubs" "$partial/repo/bin" "$partial/repo/lib" \
  "$partial/repo/theme" "$partial/repo/share"

REAL_INSTALL=$(command -v install) || fail "install(1) is available"
cat >"$partial/stubs/install" <<STUB
#!/bin/bash
# Drops -o/-g so the replay can run unprivileged; changes nothing else.
args=()
while ((\$# > 0)); do
  case "\$1" in
    -o | -g) shift 2 ;;
    *)
      args+=("\$1")
      shift
      ;;
  esac
done
exec "$REAL_INSTALL" "\${args[@]}"
STUB
chmod +x "$partial/stubs/install"

cat >"$partial/repo/bin/omarchy-vfill-retheme" <<STUB
#!/bin/bash
printf 'retheme %s\n' "\$*" >>"$log"
# Stands for the real retheme failing at the initramfs rebuild or the marker --
# after it has already swapped the live theme in and repointed the default.
exit 1
STUB
chmod +x "$partial/repo/bin/omarchy-vfill-retheme"
: >"$partial/repo/lib/vfill.sh"
: >"$partial/repo/theme/omarchy-vfill.plymouth"
: >"$partial/repo/theme/omarchy-vfill.script"
cp "$ROOT/bin/omarchy-vfill-reboot" "$partial/repo/bin/omarchy-vfill-reboot"
cp "$ROOT/share/omarchy-vfill-reboot.desktop" "$partial/repo/share/"

# install.sh invokes: <elevate> /bin/bash -c <script> bash <prefix> <repo> \
#   <theme_dir> <mode> <reboot_bin> <desktop_entry>
for elevate in sudo pkexec; do
  cat >"$partial/stubs/$elevate" <<STUB
#!/bin/bash
printf '%s\0' "\$@" >"$argv"
exec env PATH="$partial/stubs:\$PATH" /bin/bash -c "\$3" bash \
  "$partial/prefix" "$partial/repo" "\$7" "\$8" \
  "$partial/reboot-bin" "$partial/entry.desktop"
STUB
  chmod +x "$partial/stubs/$elevate"
done

rm -f -- "$hook" "$argv"
: >"$log"
output=$(HOME="$home" PATH="$partial/stubs:$stubs:$PATH" \
  bash "$ROOT/install.sh" --mode reboot </dev/null 2>&1)
status=$?

[[ $status -ne 0 ]] || fail "install fails when the transaction's retheme fails" "$output"
pass "install fails when the transaction's retheme fails"
assert_equals "retheme --force --theme-dir $theme_dir" "$(cat "$log")" \
  "the replayed transaction got as far as running the retheme"
assert_equals "reboot" "$(cat "$partial/prefix/mode")" \
  "the mode file was already written when the retheme failed"
[[ -x $partial/prefix/bin/omarchy-vfill-retheme ]] ||
  fail "the prefix was already staged when the retheme failed" "$(ls -AR "$partial/prefix" 2>&1)"
pass "the prefix was already staged when the retheme failed"
[[ -f $partial/reboot-bin && -f $partial/entry.desktop ]] ||
  fail "mode reboot's artefacts were already installed when the retheme failed"
pass "mode reboot's artefacts were already installed when the retheme failed"
[[ ! -e $hook ]] || fail "a failed transaction installs no hook"
pass "a failed transaction installs no hook"

# The message has to survive exactly this case: the live theme really may be
# replaced by now.
for lie in \
  "the live Plymouth theme was not replaced" \
  "nothing else was changed" \
  "nothing was changed"; do
  [[ $output != *"$lie"* ]] ||
    fail "the failure message does not claim: $lie" "$output"
done
pass "the failure message claims nothing was left untouched"
[[ $output == *"may already have been"* && $output == *"Plymouth default"* ]] ||
  fail "the failure message says the live theme and the default may already have changed" "$output"
pass "the failure message says the live theme and the default may already have changed"
[[ $output == *"initramfs that does not yet match"* ]] ||
  fail "the failure message says the initramfs may not match" "$output"
pass "the failure message says the initramfs may not match"
[[ $output == *"./install.sh"* && $output == *"./uninstall.sh"* ]] ||
  fail "the failure message names both ways out" "$output"
pass "the failure message names both ways out"

# --- A failed render leaves the live hook alone. ------------------------
# A redirection onto the hook truncates it before the render runs, so a failed
# render used to leave an empty file behind that omarchy-hook still executes.
# The render is made to fail by handing install.sh a checkout with no hook
# template; everything privileged is still a stub.

norender="$scratch/norender"
mkdir -p "$norender/lib"
cp "$ROOT/install.sh" "$norender/install.sh"
cp "$ROOT/lib/vfill.sh" "$norender/lib/vfill.sh"
[[ ! -e $norender/hooks/theme-set.sh ]] ||
  fail "prerequisite: the no-template checkout really has no hook template"
pass "prerequisite: the no-template checkout has no hook template"

mkdir -p "$(dirname "$hook")"
printf '#!/bin/bash
# a working hook from the previous install
' >"$hook"
live_hook=$(cat "$hook")

rm -f -- "$argv"
output=$(HOME="$home" PATH="$stubs:$PATH" bash "$norender/install.sh" --mode theme-set </dev/null 2>&1)
[[ $? -ne 0 ]] || fail "install fails when the hook cannot be rendered" "$output"
pass "install fails when the hook cannot be rendered"
[[ -s $hook ]] || fail "a failed render leaves the live hook non-empty" "$(ls -l "$hook" 2>&1)"
pass "a failed render leaves the live hook non-empty"
assert_equals "$live_hook" "$(cat "$hook")" \
  "a failed render leaves the live hook byte-for-byte as it was"
assert_equals "" "$(find "$(dirname "$hook")" -maxdepth 1 -name '.omarchy-vfill.sh.*')" \
  "a failed render leaves no temporary file behind in the hook directory"

# A successful render still ends up with exactly one executable hook and no
# temporary file beside it.
rm -f -- "$hook"
run_install "" --mode theme-set >/dev/null
assert_equals "755" "$(stat -c %a "$hook")" "a successful render installs the hook 0755"
assert_equals "" "$(find "$(dirname "$hook")" -maxdepth 1 -name '.omarchy-vfill.sh.*')" \
  "a successful render leaves no temporary file behind either"

# --- Replay the root transaction against scratch paths. -----------------

if [[ -n $SKIP_NAMESPACE ]]; then
  printf '# skip - the privileged-transaction replay needs unshare -r: %s\n' "$SKIP_NAMESPACE"
  exit 0
fi

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

# --- Pre-existing system directories keep their mode and owner. ----------
# /usr/local/bin and /usr/local/share/applications normally already exist and
# belong to the system. install -d on them rewrites their mode and owner, so
# they are created only when they are actually missing.

existing_bin="$scratch/sysdirs/bin"
existing_apps="$scratch/sysdirs/applications"
mkdir -p "$existing_bin" "$existing_apps"
chmod 0711 "$existing_bin"
chmod 0700 "$existing_apps"

env PATH="$stubs:$PATH" unshare -r /bin/bash -c "$script" \
  bash "$prefix" "$fakerepo" "$theme_dir" reboot \
  "$existing_bin/omarchy-vfill-reboot" "$existing_apps/omarchy-vfill-reboot.desktop"
assert_equals "0" "$?" "the root transaction succeeds into pre-existing directories"
assert_equals "711" "$(stat -c %a "$existing_bin")" \
  "a pre-existing /usr/local/bin keeps its mode"
assert_equals "700" "$(stat -c %a "$existing_apps")" \
  "a pre-existing /usr/local/share/applications keeps its mode"
[[ -f $existing_bin/omarchy-vfill-reboot && -f $existing_apps/omarchy-vfill-reboot.desktop ]] ||
  fail "the artefacts still land in pre-existing directories"
pass "the artefacts still land in pre-existing directories"

# A missing directory is still created, 0755.
missing_bin="$scratch/newdirs/bin"
missing_apps="$scratch/newdirs/applications"
env PATH="$stubs:$PATH" unshare -r /bin/bash -c "$script" \
  bash "$prefix" "$fakerepo" "$theme_dir" reboot \
  "$missing_bin/omarchy-vfill-reboot" "$missing_apps/omarchy-vfill-reboot.desktop"
assert_equals "0" "$?" "the root transaction creates the directories when they are missing"
assert_equals "755" "$(stat -c %a "$missing_bin")" "a created bin directory is 0755"
assert_equals "755" "$(stat -c %a "$missing_apps")" "a created applications directory is 0755"

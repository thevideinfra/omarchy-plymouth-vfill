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

# install.sh only ever looks polkitd up with command -v -- a rules file is read
# by polkitd, so without one the rule would do nothing -- and must never run it.
# This stub is loud and non-zero so that running it would be obvious.
cat >"$stubs/polkitd" <<'STUB'
#!/bin/bash
echo "polkitd stub: must never be executed" >&2
exit 97
STUB
chmod +x "$stubs/polkitd"

# Mode auto refuses a user who is not in group wheel, since the rule would never
# match them. The real id would report whatever groups the machine running the
# suite happens to have, so that one question is answered by STUB_ID_GROUPS and
# everything else passes through.
REAL_ID=$(command -v id) || fail "id(1) is available"
cat >"$stubs/id" <<STUB
#!/bin/bash
if [[ "\$*" == "-nG" ]]; then
  printf '%s\n' "\${STUB_ID_GROUPS-someone wheel users}"
  exit 0
fi
exec "$REAL_ID" "\$@"
STUB
chmod +x "$stubs/id"

home="$scratch/home"
mkdir -p "$home"
hook="$home/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh"
theme_dir="$home/.local/state/omarchy/current/theme"
PREFIX=/usr/local/lib/omarchy-vfill
MANUAL_COMMAND="sudo $PREFIX/bin/omarchy-vfill-retheme --force"

# Mode auto's polkit rule. The real /etc/polkit-1/rules.d is never named except
# in the assertions below that check the default, where nothing privileged runs:
# everything that could write points at this scratch directory. install.sh only
# accepts a VFILL_POLKIT_RULES_DIR at all when VFILL_TEST_POLKIT_RULES_DIR=1 is
# set AND the value canonicalises under /tmp, /var/tmp or /dev/shm -- it is read
# unprivileged and handed to root as an argv word, so the environment does not
# get to choose where root writes a drop-in. Canonicalised here because that is
# the form install.sh passes on.
rules_dir=$(readlink -m "$scratch/polkit-rules.d")
mkdir -p "$rules_dir"
RULE_SRC="$ROOT/share/49-omarchy-vfill.rules"
rule="$rules_dir/49-omarchy-vfill.rules"

# First argument is what install.sh reads on stdin; the rest are its own
# arguments. An empty first argument means an empty stdin, i.e. no answer.
run_install() {
  local answers="$1"
  shift
  rm -f -- "$argv"
  printf '%s' "$answers" |
    HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" \
      bash "$ROOT/install.sh" "$@" 2>&1
}

# The privileged step is one root shell:
#   /bin/bash -c <script> bash <prefix> <repo> <theme_dir> <mode> \
#                              <reboot_bin> <desktop_entry> <polkit_rule>
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
assert_equals "$rule" "${RECORDED[10]}" \
  "the privileged step is told where mode auto's polkit rule goes"
# And always the default path too, overridden or not: every mode but auto removes
# both, so a stale override in the environment can never be the only path a mode
# switch cleans up. That left passwordless root installed at the default path.
assert_equals "/etc/polkit-1/rules.d/49-omarchy-vfill.rules" "${RECORDED[11]}" \
  "the privileged step is always told the default rule path as well"

[[ $output == *"How should the boot splash follow your desktop theme?"* ]] ||
  fail "the mode question is asked" "$output"
pass "the mode question is asked"
for line in \
  "1) At theme change" \
  "2) Before reboot" \
  "3) Manually" \
  "4) At theme change, without a password"; do
  [[ $output == *"$line"* ]] || fail "the mode question offers: $line" "$output"
done
pass "the mode question offers all four modes"

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
assert_equals "2" "$(grep -c 'Please answer 1, 2, 3 or 4' <<<"$output")" \
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

# The polkit rule is the one artefact here with a security meaning, so it is named
# on its own rather than lumped in with "mode auto's artefacts". Switching away
# from auto should have removed it, and a failure means that may not have happened.
[[ $output == *"$rule"* ]] ||
  fail "a failed install names the polkit rule path specifically" "$output"
[[ $output == *"may still be live"* && $output == *"passwordless root"* ]] ||
  fail "a failed install says the rule may still be granting passwordless root" "$output"
pass "a failed install in another mode names the polkit rule and what it may still grant"

# In mode auto the rule is installed by the transaction before the retheme it then
# failed at, so it really can be live even though the install did not finish.
rm -f -- "$hook" "$argv"
output=$(STUB_ELEVATE_EXIT=1 run_install "" --mode auto --i-understand)
[[ $? -ne 0 ]] || fail "install fails when the privileged step fails in mode auto"
pass "install fails when the privileged step fails in mode auto"
[[ $output == *"$rule"* ]] ||
  fail "a failed mode auto install names the polkit rule path" "$output"
[[ $output == *"may already be"* && $output == *"installed and live"* ]] ||
  fail "a failed mode auto install says the rule may already be live" "$output"
[[ $output == *"no"*"password"* ]] ||
  fail "a failed mode auto install says what the live rule allows" "$output"
pass "a failed mode auto install names the rule and says it may already be live"

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
cp "$ROOT/share/49-omarchy-vfill.rules" "$partial/repo/share/"
mkdir -p "$partial/rules.d" "$partial/default-rules.d"

# install.sh invokes: <elevate> /bin/bash -c <script> bash <prefix> <repo> \
#   <theme_dir> <mode> <reboot_bin> <desktop_entry>
for elevate in sudo pkexec; do
  cat >"$partial/stubs/$elevate" <<STUB
#!/bin/bash
printf '%s\0' "\$@" >"$argv"
exec env PATH="$partial/stubs:\$PATH" /bin/bash -c "\$3" bash \
  "$partial/prefix" "$partial/repo" "\$7" "\$8" \
  "$partial/reboot-bin" "$partial/entry.desktop" \
  "$partial/rules.d/49-omarchy-vfill.rules" \
  "$partial/default-rules.d/49-omarchy-vfill.rules"
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

# --- The rule path defaults to the real /etc/polkit-1/rules.d. ------------
# Nothing privileged runs here -- the elevate stub only records its arguments --
# so the real directory is named and never touched.

rm -f -- "$hook" "$argv"
HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" --mode manual \
  </dev/null >/dev/null 2>&1
load_root_argv
assert_equals "/etc/polkit-1/rules.d/49-omarchy-vfill.rules" "${RECORDED[10]}" \
  "with nothing overriding it, the rule path is the real /etc/polkit-1/rules.d one"

# --- A VFILL_POLKIT_RULES_DIR the gate does not allow ends the install. ----
# The variable is read here, unprivileged, and handed into the root transaction as
# an argv word -- which is how it got past the env scrubbing that makes
# VFILL_THEME_DEST harmless. Unchecked, it chose where root wrote a drop-in: the
# review demonstrated /etc/sudoers.d. Each case below must stop the install before
# anything privileged runs; none of them may name a real directory that gets
# written, so the hostile values are only ever *rejected*, never honoured.

for bad in no-marker outside-scratch traversal; do
  rm -f -- "$hook" "$argv"
  case "$bad" in
    # The marker alone gates nothing -- the environment supplies both the marker
    # and the value -- so the value is checked as well. Without the marker, no
    # override at all is accepted.
    no-marker) env_marker="" bad_dir="$rules_dir" ;;
    # With the marker, still only a scratch prefix.
    outside-scratch) env_marker=1 bad_dir=/etc/sudoers.d ;;
    # Canonicalised first, so this is /etc/sudoers.d too.
    traversal) env_marker=1 bad_dir=/tmp/../etc/sudoers.d ;;
  esac

  output=$(env HOME="$home" PATH="$stubs:$PATH" \
    ${env_marker:+VFILL_TEST_POLKIT_RULES_DIR=$env_marker} \
    VFILL_POLKIT_RULES_DIR="$bad_dir" \
    bash "$ROOT/install.sh" --mode auto --i-understand </dev/null 2>&1)
  status=$?

  [[ $status -ne 0 ]] || fail "a refused VFILL_POLKIT_RULES_DIR exits non-zero: $bad" "$output"
  [[ ! -f $argv ]] || fail "a refused VFILL_POLKIT_RULES_DIR runs nothing privileged: $bad" "$output"
  [[ ! -e $hook ]] || fail "a refused VFILL_POLKIT_RULES_DIR installs no hook: $bad"
  [[ $output == *"refusing VFILL_POLKIT_RULES_DIR=$bad_dir"* ]] ||
    fail "the refusal names the value it rejected: $bad" "$output"
  [[ $output == *"/etc/polkit-1/rules.d"* || $output == *"/tmp, /var/tmp or /dev/shm"* ]] ||
    fail "the refusal says where the rule may go: $bad" "$output"
  [[ $output == *"nothing was changed"* ]] ||
    fail "the refusal says nothing was changed: $bad" "$output"
done
pass "an ungated, non-scratch or traversing VFILL_POLKIT_RULES_DIR ends the install, privileged step untouched"

# A refused override is refused whatever the mode, because the value is read
# before the mode is: a mode that would merely *remove* the rule must not get to
# remove it from a path of the environment's choosing either.
rm -f -- "$argv"
output=$(env HOME="$home" PATH="$stubs:$PATH" VFILL_POLKIT_RULES_DIR=/etc/sudoers.d \
  bash "$ROOT/install.sh" --mode manual </dev/null 2>&1)
[[ $? -ne 0 && ! -f $argv ]] ||
  fail "a refused VFILL_POLKIT_RULES_DIR ends the install in mode manual too" "$output"
pass "a refused VFILL_POLKIT_RULES_DIR ends the install in mode manual too"

# The default itself is not an override: spelling it out explicitly is accepted
# and names the same path as setting nothing.
rm -f -- "$argv"
HOME="$home" PATH="$stubs:$PATH" VFILL_POLKIT_RULES_DIR=/etc/polkit-1/rules.d \
  bash "$ROOT/install.sh" --mode manual </dev/null >/dev/null 2>&1
load_root_argv
assert_equals "/etc/polkit-1/rules.d/49-omarchy-vfill.rules" "${RECORDED[10]}" \
  "VFILL_POLKIT_RULES_DIR set to the default path is accepted as the default"

# --- The shipped rule approves exactly one program. ----------------------

[[ -f $RULE_SRC ]] || fail "the polkit rule exists in the checkout"
pass "the polkit rule exists in the checkout"
grep -qF "\"$PREFIX/bin/omarchy-vfill-retheme\"" "$RULE_SRC" ||
  fail "the shipped rule names the installed retheme" "$(cat "$RULE_SRC")"
pass "the shipped rule names the installed retheme"
for want in \
  'action.id == "org.freedesktop.policykit.exec"' \
  'subject.isInLocalSession()' \
  'subject.active' \
  'subject.isInGroup("wheel")' \
  'polkit.Result.YES'; do
  grep -qF "$want" "$RULE_SRC" ||
    fail "the shipped rule requires $want" "$(cat "$RULE_SRC")"
done
pass "the shipped rule yields only for an active local wheel session"

# ...and exactly one invocation of it. Pinning only the program approved every
# argument the retheme accepts too, --theme-dir among them, which names the
# directory root reads colors.toml and unlock.png from.
grep -qF "action.lookup(\"command_line\") == \"$PREFIX/bin/omarchy-vfill-retheme\"" "$RULE_SRC" ||
  fail "the shipped rule approves only the argument-free command line" "$(cat "$RULE_SRC")"
pass "the shipped rule approves only the argument-free command line"

# --- --mode auto on its own is refused. ---------------------------------
# No script should be able to turn the password prompt off by passing a mode
# along; it takes a second, explicit flag.

rm -f -- "$hook" "$argv"
output=$(HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" \
  bash "$ROOT/install.sh" --mode auto </dev/null 2>&1)
status=$?
[[ $status -ne 0 ]] || fail "--mode auto on its own is refused" "$output"
pass "--mode auto on its own is refused"
[[ ! -f $argv ]] || fail "--mode auto on its own runs nothing privileged" "$output"
pass "--mode auto on its own runs nothing privileged"
[[ ! -e $hook ]] || fail "--mode auto on its own installs no hook"
pass "--mode auto on its own installs no hook"
[[ ! -e $rule ]] || fail "--mode auto on its own writes no polkit rule"
pass "--mode auto on its own writes no polkit rule"
[[ $output == *"--mode auto --i-understand"* ]] ||
  fail "the refusal names the flag that would enable it" "$output"
pass "the refusal names the flag that would enable it"
[[ $output == *"no prompt"* ]] ||
  fail "the refusal says what the rule would allow" "$output"
pass "the refusal says what the rule would allow"
[[ $output == *"with no arguments"* ]] ||
  fail "the refusal says only the argument-free invocation would be allowed" "$output"
pass "the refusal says only the argument-free invocation would be allowed"

# --- --mode auto --i-understand installs the hook and the rule. ----------

rm -f -- "$hook" "$argv"
output=$(run_install "" --mode auto --i-understand)
assert_equals "0" "$?" "--mode auto --i-understand succeeds"
load_root_argv
assert_equals "auto" "${RECORDED[7]}" "--mode auto --i-understand selects mode auto"
assert_equals "$rule" "${RECORDED[10]}" \
  "mode auto's transaction is told where the polkit rule goes"
[[ ${RECORDED[2]} == *'install -m 0644 -o root -g root "$repo/share/49-omarchy-vfill.rules" "$polkit_rule"'* ]] ||
  fail "the transaction installs the rule root-owned 0644 from the checkout" "${RECORDED[2]}"
pass "the transaction installs the rule root-owned 0644 from the checkout"
[[ $output != *"How should the boot splash"* ]] ||
  fail "--mode auto --i-understand asks no question" "$output"
pass "--mode auto --i-understand asks no question"
[[ -f $hook ]] || fail "mode auto installs the theme-set hook"
pass "mode auto installs the theme-set hook"
grep -qF "$PREFIX/bin/omarchy-vfill-retheme" "$hook" ||
  fail "mode auto's hook points at the installed root-owned retheme" "$(cat "$hook")"
pass "mode auto's hook points at the installed root-owned retheme"
# The rule approves the bare invocation only, so the installed hook must escalate
# with no arguments -- otherwise mode auto prompts for a password at every theme
# change, which is the one thing it promises not to do.
grep -qE '^pkexec "\$RETHEME"$' "$hook" ||
  fail "mode auto's hook escalates with no arguments" "$(grep -n pkexec "$hook")"
pass "mode auto's hook escalates with no arguments"
# The rule is root-owned, so only the privileged transaction may write it; the
# unprivileged half must not have produced it itself.
#
# What that assertion can and cannot show: nothing in this file runs the privileged
# transaction for real -- the elevate stub only records its arguments -- so a
# missing $rule here means exactly one thing, that the UNPRIVILEGED half never
# writes it. The rule being installed and removed for real is covered by the
# namespace replay at the end of this file. On its own, "the file is absent" could
# not fail, because nothing here would have created it either; so the same claim is
# made again below against a seeded file, where writing it WOULD show.
[[ ! -e $rule ]] ||
  fail "the unprivileged half writes no polkit rule of its own" "$(ls -l "$rule")"
pass "the unprivileged half writes no polkit rule of its own"

# Seeded with a sentinel: an unprivileged half that wrote the rule would overwrite
# this, and one that removed it would delete it. Only root, inside the
# transaction, may do either.
sentinel='// seeded by install-test; the unprivileged half must not touch this'
printf '%s\n' "$sentinel" >"$rule"
rm -f -- "$hook" "$argv"
run_install "" --mode auto --i-understand >/dev/null
assert_equals "0" "$?" "a mode auto install over a seeded rule file succeeds"
assert_equals "$sentinel" "$(cat "$rule" 2>&1)" \
  "the unprivileged half neither writes nor removes the polkit rule"
rm -f -- "$rule"

# The same for a mode that removes the rule: the removal belongs to the
# transaction, not to the unprivileged half.
printf '%s\n' "$sentinel" >"$rule"
rm -f -- "$hook" "$argv"
run_install "" --mode manual >/dev/null
assert_equals "$sentinel" "$(cat "$rule" 2>&1)" \
  "the unprivileged half does not remove the polkit rule in a mode that drops it"
rm -f -- "$rule"
[[ $output == *"$rule"* ]] || fail "mode auto names the rule it installed" "$output"
pass "mode auto names the rule it installed"
[[ $output == *"with no prompt"* ]] ||
  fail "mode auto says what the rule allows without a prompt" "$output"
pass "mode auto says what the rule allows without a prompt"
[[ $output == *"with no"*"arguments"* ]] ||
  fail "mode auto says the rule allows the argument-free invocation only" "$output"
pass "mode auto says the rule allows the argument-free invocation only"
[[ $output == *"only as safe as that script is correct"* ]] ||
  fail "mode auto states the standing liability" "$output"
pass "mode auto states the standing liability"
[[ $output == *"$MANUAL_COMMAND"* ]] ||
  fail "mode auto names the always-available manual command" "$output"
pass "mode auto names the always-available manual command"

# --- Interactively, only the word yes in full chooses mode auto. ---------

for reply in "no" "y" "YES" "yes please" ""; do
  rm -f -- "$hook" "$argv"
  output=$(run_install $'4\n'"$reply"$'\n3\n')
  assert_equals "0" "$?" "the prompt carries on after a refused mode auto ('$reply')"
  load_root_argv
  assert_equals "manual" "${RECORDED[7]}" \
    "answering '$reply' at the confirmation does not choose mode auto"
  [[ $output == *"Mode auto not chosen"* ]] ||
    fail "answering '$reply' says mode auto was not chosen" "$output"
  [[ ! -e $hook ]] || fail "answering '$reply' installs no hook"
done
pass "only the word yes in full chooses mode auto"

rm -f -- "$hook" "$argv"
# The "yes" is there so that an empty answer falling through to option 4 could
# not be rescued by the confirmation reaching end-of-stdin: if Enter ever
# reached mode auto, this input would select it.
output=$(run_install $'\nyes\n')
load_root_argv
assert_equals "theme-set" "${RECORDED[7]}" \
  "pressing Enter at the prompt takes theme-set, never mode auto"
[[ $output != *"Any process running as you"* ]] ||
  fail "pressing Enter never even offers mode auto's consent" "$output"
pass "pressing Enter never even offers mode auto's consent"

rm -f -- "$hook" "$argv"
output=$(run_install $'4\nyes\n')
assert_equals "0" "$?" "answering 4 and then yes succeeds"
load_root_argv
assert_equals "auto" "${RECORDED[7]}" "answering 4 and then yes chooses mode auto"
[[ -f $hook ]] || fail "mode auto chosen interactively installs the hook"
pass "mode auto chosen interactively installs the hook"

for line in \
  "Any process running as you, in an active local session, may run" \
  "that exact command and no arguments" \
  "approves the program and the whole command line" \
  "unlimited initramfs rebuilds" \
  "the current image survives until a rebuild" \
  "only as safe as that one script is correct" \
  "Remove it with ./uninstall.sh"; do
  [[ $output == *"$line"* ]] || fail "the consent text says: $line" "$output"
done
pass "the consent text states the whole trade-off before asking"

# ...and claims no more than the rule delivers. "That one program only" implied the
# rule constrained the arguments, which it did not until it checked command_line,
# and "not a privilege leak" is not this installer's promise to make: what the
# rule is worth rests on the retheme being correct, which the text now says
# instead.
for lie in \
  "That one program only" \
  "not a privilege leak" \
  "cannot be changed by you"; do
  [[ $output != *"$lie"* ]] ||
    fail "the consent text does not claim: $lie" "$output"
done
pass "the consent text claims nothing the rule does not deliver"

# --- Mode auto is refused where the rule could never work. ---------------
# The "rules.d is missing" refusal is about a polkit too old to have a rules.d at
# all (pre-0.106), which on this machine cannot be arranged by deleting
# /etc/polkit-1/rules.d. It is reached instead through a scratch path that really
# is absent -- and that precondition is asserted here rather than assumed, both
# before and after, so this can never quietly become a test of something else.
# The gate on VFILL_POLKIT_RULES_DIR deliberately accepts a path that does not
# exist yet for exactly this reason.
missing_rules_dir_case="$scratch/no-such-rules.d"
[[ ! -e $missing_rules_dir_case ]] ||
  fail "prerequisite: the missing rules directory really is missing" \
    "$(ls -ld "$missing_rules_dir_case")"
pass "prerequisite: the rules directory used for the missing-rules-dir case is absent"

for why in missing-rules-dir not-in-wheel; do
  rm -f -- "$hook" "$argv"
  if [[ $why == missing-rules-dir ]]; then
    output=$(HOME="$home" PATH="$stubs:$PATH" \
      VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$missing_rules_dir_case" \
      bash "$ROOT/install.sh" --mode auto --i-understand </dev/null 2>&1)
  else
    output=$(HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" \
      STUB_ID_GROUPS="someone users" \
      bash "$ROOT/install.sh" --mode auto --i-understand </dev/null 2>&1)
  fi
  status=$?

  [[ $status -ne 0 ]] || fail "mode auto is refused: $why" "$output"
  [[ ! -f $argv ]] || fail "a refused mode auto runs nothing privileged: $why" "$output"
  [[ ! -e $hook ]] || fail "a refused mode auto installs no hook: $why"
  [[ ! -e $rule ]] || fail "a refused mode auto writes no polkit rule: $why"
  [[ $output == *"mode auto is not available here"* ]] ||
    fail "the refusal says mode auto is unavailable: $why" "$output"
  [[ $output == *"mode 1 (theme-set)"* ]] ||
    fail "the refusal points at mode theme-set: $why" "$output"

  if [[ $why == missing-rules-dir ]]; then
    [[ $output == *"$missing_rules_dir_case does not exist"* && $output == *"0.106"* ]] ||
      fail "the refusal names the missing rules directory and the polkit version" "$output"
    [[ ! -e $missing_rules_dir_case ]] ||
      fail "the refusal does not create the rules directory it refused over" \
        "$(ls -ld "$missing_rules_dir_case")"
  else
    [[ $output == *"not in group wheel"* ]] ||
      fail "the refusal says the user is not in group wheel" "$output"
  fi
done
pass "mode auto is refused, with its reason, when rules.d is missing or the user is not in wheel"

# Interactively the same conditions refuse the option and re-ask, rather than
# ending the install.
rm -f -- "$hook" "$argv"
output=$(printf '%s' $'4\n3\n' | HOME="$home" PATH="$stubs:$PATH" \
  VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" STUB_ID_GROUPS="someone users" \
  bash "$ROOT/install.sh" 2>&1)
assert_equals "0" "$?" "an unavailable mode auto at the prompt does not end the install"
load_root_argv
assert_equals "manual" "${RECORDED[7]}" \
  "an unavailable mode auto is refused at the prompt and the question re-asked"
[[ $output == *"mode auto is not available here"* ]] ||
  fail "the prompt says why mode auto is unavailable" "$output"
pass "the prompt says why mode auto is unavailable"
[[ $output != *"Any process running as you"* ]] ||
  fail "an unavailable mode auto never asks for consent" "$output"
pass "an unavailable mode auto never asks for consent"

# --- A rule that is not the shipped rule is refused at install time. ------
# The rule hands one exact path passwordless root, so anything but the rule this
# installer ships must not be installed at all. The check is a byte-for-byte
# comparison against the text in install.sh, not a grep for the program string:
# a grep passed any file that merely mentioned the retheme somewhere, so a
# crafted rules file was enough to have root write whatever it contained.

mutant="$scratch/mutant"
mkdir -p "$mutant"
cp -R "$ROOT/install.sh" "$ROOT/lib" "$ROOT/hooks" "$ROOT/bin" "$ROOT/theme" \
  "$ROOT/share" "$mutant/"
sed -i 's|/usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme|/usr/local/bin/some-other-program|g' \
  "$mutant/share/49-omarchy-vfill.rules"
grep -qF "$PREFIX/bin/omarchy-vfill-retheme" "$mutant/share/49-omarchy-vfill.rules" &&
  fail "prerequisite: the mutated rule no longer names the installed retheme"
pass "prerequisite: the mutated rule no longer names the installed retheme"

rm -f -- "$hook" "$argv"
output=$(HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" \
  bash "$mutant/install.sh" --mode auto --i-understand </dev/null 2>&1)
[[ $? -ne 0 ]] || fail "a rule naming the wrong program is refused" "$output"
pass "a rule naming the wrong program is refused"
[[ $output == *"is not the rule this installer approves"* &&
  $output == *"$PREFIX/bin/omarchy-vfill-retheme"* ]] ||
  fail "the refusal says the rule is not the one this installer approves" "$output"
pass "the refusal says the rule is not the one this installer approves"
[[ ! -f $argv ]] || fail "a mismatched rule runs nothing privileged" "$output"
pass "a mismatched rule runs nothing privileged"
[[ ! -e $hook ]] || fail "a mismatched rule installs no hook"
[[ ! -e $rule ]] || fail "a mismatched rule writes no polkit rule"
pass "a mismatched rule installs neither the hook nor the rule"

# A rule that still names the installed retheme, and would still have passed the
# old grep, but widens what it approves: the second addRule below returns YES for
# every pkexec action, which is passwordless root for anything. This is the case
# the grep could not see and the comparison must.
cp "$ROOT/share/49-omarchy-vfill.rules" "$mutant/share/49-omarchy-vfill.rules"
cat >>"$mutant/share/49-omarchy-vfill.rules" <<'TAMPER'
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.policykit.exec") {
    return polkit.Result.YES;
  }
});
TAMPER
grep -qF "\"$PREFIX/bin/omarchy-vfill-retheme\"" "$mutant/share/49-omarchy-vfill.rules" ||
  fail "prerequisite: the tampered rule still names the installed retheme"
pass "prerequisite: the tampered rule still names the installed retheme (the old grep passed it)"

rm -f -- "$hook" "$argv"
output=$(HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" \
  bash "$mutant/install.sh" --mode auto --i-understand </dev/null 2>&1)
[[ $? -ne 0 ]] || fail "a tampered rule that still names the retheme is refused" "$output"
pass "a tampered rule that still names the retheme is refused"
[[ $output == *"is not the rule this installer approves"* ]] ||
  fail "the refusal says the tampered rule is not the approved one" "$output"
pass "the refusal says the tampered rule is not the approved one"
[[ ! -f $argv ]] || fail "a tampered rule runs nothing privileged" "$output"
pass "a tampered rule runs nothing privileged"
[[ ! -e $rule ]] || fail "a tampered rule writes no polkit rule"
pass "a tampered rule writes no polkit rule"

# The shipped rule and the text install.sh compares it against have to stay
# identical, so an intentional change to one is a failing test until it is made
# to both. install.sh is the file an operator reads before trusting mode auto.
expected_rule="$scratch/expected-rule"
sed -n '/^polkit_rule_expected() {$/,/^RULE$/p' "$ROOT/install.sh" | sed '1,2d;$d' >"$expected_rule"
[[ -s $expected_rule ]] ||
  fail "prerequisite: install.sh's expected rule text could be extracted"
pass "prerequisite: install.sh's expected rule text could be extracted"
cmp -s "$expected_rule" "$RULE_SRC" ||
  fail "install.sh's expected rule text is byte-identical to the shipped rule" \
    "$(diff "$expected_rule" "$RULE_SRC")"
pass "install.sh's expected rule text is byte-identical to the shipped rule"

# --- A rule that does not name THIS installer's prefix is refused. ---------
# cmp pins the rule's bytes, but a baseline and a shipped rule that agree on some
# other prefix agree with each other perfectly well -- so cmp on its own does not
# enforce the relationship the rule's own comment claims, that the program path
# names the retheme this installer installs. A rule naming a program that is
# never installed here is passwordless root for whatever does end up at that path.
cp "$ROOT/share/49-omarchy-vfill.rules" "$mutant/share/49-omarchy-vfill.rules"
sed -i 's|^PREFIX=/usr/local/lib/omarchy-vfill$|PREFIX=/opt/elsewhere/omarchy-vfill|' \
  "$mutant/install.sh"
grep -qx 'PREFIX=/opt/elsewhere/omarchy-vfill' "$mutant/install.sh" ||
  fail "prerequisite: the mutant installer installs into a different prefix"
pass "prerequisite: the mutant installer installs into a different prefix"

# Nothing about the rule or the baseline changed, so the byte comparison still
# agrees: whatever refuses this install is not cmp.
mutant_expected="$scratch/mutant-expected-rule"
sed -n '/^polkit_rule_expected() {$/,/^RULE$/p' "$mutant/install.sh" | sed '1,2d;$d' \
  >"$mutant_expected"
cmp -s "$mutant_expected" "$mutant/share/49-omarchy-vfill.rules" ||
  fail "prerequisite: the mismatched prefix still passes the byte comparison" \
    "$(diff "$mutant_expected" "$mutant/share/49-omarchy-vfill.rules")"
pass "prerequisite: the mismatched prefix still passes the byte comparison (cmp alone would install it)"

rm -f -- "$hook" "$argv"
output=$(HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" \
  bash "$mutant/install.sh" --mode auto --i-understand </dev/null 2>&1)
[[ $? -ne 0 ]] || fail "a rule that does not name the installer's own prefix is refused" "$output"
pass "a rule that does not name the installer's own prefix is refused"
[[ $output == *"/opt/elsewhere/omarchy-vfill/bin/omarchy-vfill-retheme"* ]] ||
  fail "the refusal names the prefix the rule would have to name" "$output"
pass "the refusal names the prefix the rule would have to name"
[[ ! -f $argv ]] || fail "a prefix-mismatched rule runs nothing privileged" "$output"
pass "a prefix-mismatched rule runs nothing privileged"
[[ ! -e $hook ]] || fail "a prefix-mismatched rule installs no hook"
[[ ! -e $rule ]] || fail "a prefix-mismatched rule writes no polkit rule"
pass "a prefix-mismatched rule installs neither the hook nor the rule"

sed -i 's|^PREFIX=/opt/elsewhere/omarchy-vfill$|PREFIX=/usr/local/lib/omarchy-vfill|' \
  "$mutant/install.sh"

rm -f -- "$mutant/share/49-omarchy-vfill.rules" "$argv"
output=$(HOME="$home" PATH="$stubs:$PATH" VFILL_TEST_POLKIT_RULES_DIR=1 VFILL_POLKIT_RULES_DIR="$rules_dir" \
  bash "$mutant/install.sh" --mode auto --i-understand </dev/null 2>&1)
[[ $? -ne 0 ]] || fail "a missing rule file is refused" "$output"
pass "a missing rule file is refused"
[[ $output == *"is missing"* ]] ||
  fail "the refusal says the rule file is missing" "$output"
pass "the refusal says the rule file is missing"
[[ ! -f $argv ]] || fail "a missing rule file runs nothing privileged" "$output"
pass "a missing rule file runs nothing privileged"

# --- Switching between the two hook modes keeps or drops the hook. -------

rm -f -- "$hook"
run_install "" --mode auto --i-understand >/dev/null
[[ -f $hook ]] || fail "prerequisite: mode auto installed the hook"
pass "prerequisite: mode auto installed the hook"
run_install "" --mode theme-set >/dev/null
assert_equals "0" "$?" "switching from auto to theme-set succeeds"
[[ -f $hook ]] || fail "switching from auto to theme-set keeps the hook"
pass "switching from auto to theme-set keeps the hook"

run_install "" --mode auto --i-understand >/dev/null
[[ -f $hook ]] || fail "prerequisite: mode auto installed the hook again"
output=$(run_install "" --mode manual)
assert_equals "0" "$?" "switching from auto to manual succeeds"
[[ ! -e $hook ]] || fail "switching from auto to manual removes the hook" "$output"
pass "switching from auto to manual removes the hook"

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
cp "$ROOT/share/49-omarchy-vfill.rules" "$fakerepo/share/49-omarchy-vfill.rules"

run_install "" --mode reboot >/dev/null
load_root_argv
script="${RECORDED[2]}"

prefix="$scratch/prefix"
reboot_bin="$scratch/local-bin/omarchy-vfill-reboot"
desktop_entry="$scratch/applications/omarchy-vfill-reboot.desktop"
# The replay writes mode auto's rule here, never into /etc/polkit-1/rules.d.
replay_rules_dir="$scratch/replay-rules.d"
mkdir -p "$replay_rules_dir"
replay_rule="$replay_rules_dir/49-omarchy-vfill.rules"

# unshare -r maps our uid to 0, so a file the transaction created as root:root
# shows up outside the namespace as owned by us. A different -o/-g would not:
# only uid 0 is mapped inside, so install would fail outright.
NS_ROOT="$(id -u):$(id -g)"

# The eighth argument is the DEFAULT rule path, which the transaction removes
# alongside the overridden one for every mode but auto. The replay gives it a
# scratch path of its own: never the real
# /etc/polkit-1/rules.d/49-omarchy-vfill.rules, which is a live file on a machine
# installed in mode auto.
replay_default_rule="$scratch/replay-default-rules.d/49-omarchy-vfill.rules"
mkdir -p "$(dirname "$replay_default_rule")"

replay() {
  local mode="$1"
  : >"$log"
  env PATH="$stubs:$PATH" unshare -r /bin/bash -c "$script" \
    bash "$prefix" "$fakerepo" "$theme_dir" "$mode" "$reboot_bin" "$desktop_entry" \
    "$replay_rule" "$replay_default_rule"
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

# --- Mode auto's polkit rule is installed and removed by the same single
#     transaction, so switching modes still costs one authentication. --------

replay auto
assert_equals "0" "$?" "the root transaction succeeds in mode auto"
assert_equals "auto" "$(cat "$prefix/mode")" "mode auto is recorded"
[[ -f $replay_rule ]] || fail "mode auto installs the polkit rule"
pass "mode auto installs the polkit rule"
assert_equals "644" "$(stat -c %a "$replay_rule")" "the polkit rule is 0644"
assert_equals "$NS_ROOT" "$(stat -c %u:%g "$replay_rule")" "the polkit rule is root-owned"
cmp -s "$ROOT/share/49-omarchy-vfill.rules" "$replay_rule" ||
  fail "the installed polkit rule matches the checkout" "$(cat "$replay_rule")"
pass "the installed polkit rule matches the checkout"
[[ ! -e $reboot_bin && ! -e $desktop_entry ]] ||
  fail "mode auto installs none of mode reboot's artefacts"
pass "mode auto installs none of mode reboot's artefacts"

for mode in theme-set manual reboot; do
  replay auto >/dev/null
  [[ -f $replay_rule ]] || fail "prerequisite: mode auto put the rule back"
  # Stands for a rule installed at the DEFAULT path by an earlier install that ran
  # without an override. Removing only the overridden path left this one behind --
  # which is passwordless root surviving a mode switch away from auto.
  printf 'polkit.addRule(function(action, subject) {});\n' >"$replay_default_rule"
  replay "$mode"
  assert_equals "0" "$?" "the root transaction succeeds switching from auto to $mode"
  [[ ! -e $replay_rule ]] || fail "switching from auto to $mode removes the polkit rule"
  [[ ! -e $replay_default_rule ]] ||
    fail "switching from auto to $mode removes the rule at the default path too"
done
pass "switching away from mode auto removes the polkit rule"
pass "switching away from mode auto removes the rule at the default path as well as any override"

# Mode auto itself installs the rule it was given and removes nothing: the
# default path is a removal target, never something auto deletes behind its own
# back. (On every real run the two are the same path anyway.)
printf 'polkit.addRule(function(action, subject) {});\n' >"$replay_default_rule"
replay auto
assert_equals "0" "$?" "the root transaction succeeds in mode auto with a rule at the default path"
[[ -f $replay_default_rule ]] ||
  fail "mode auto does not remove the rule at the default path"
pass "mode auto installs its rule and removes nothing"
rm -f -- "$replay_default_rule"

replay theme-set >/dev/null
[[ ! -e $replay_rule ]] || fail "prerequisite: mode theme-set leaves no rule"
replay auto
assert_equals "0" "$?" "the root transaction succeeds switching from theme-set to auto"
[[ -f $replay_rule ]] || fail "switching from theme-set to auto adds the polkit rule"
pass "switching from theme-set to auto adds the polkit rule"

# The rule's directory is never created by the transaction: install.sh refused
# mode auto already if it was missing, because a polkit without it could not
# read the rule anyway.
replay theme-set >/dev/null
missing_rules_dir="$scratch/never-created-rules.d"
env PATH="$stubs:$PATH" unshare -r /bin/bash -c "$script" \
  bash "$prefix" "$fakerepo" "$theme_dir" auto "$reboot_bin" "$desktop_entry" \
  "$missing_rules_dir/49-omarchy-vfill.rules" "$replay_default_rule" >/dev/null 2>&1
[[ ! -e $missing_rules_dir ]] ||
  fail "the transaction never creates the polkit rules directory"
pass "the transaction never creates the polkit rules directory"

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
  "$existing_bin/omarchy-vfill-reboot" "$existing_apps/omarchy-vfill-reboot.desktop" \
  "$replay_rule" "$replay_default_rule"
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
  "$missing_bin/omarchy-vfill-reboot" "$missing_apps/omarchy-vfill-reboot.desktop" \
  "$replay_rule" "$replay_default_rule"
assert_equals "0" "$?" "the root transaction creates the directories when they are missing"
assert_equals "755" "$(stat -c %a "$missing_bin")" "a created bin directory is 0755"
assert_equals "755" "$(stat -c %a "$missing_apps")" "a created applications directory is 0755"

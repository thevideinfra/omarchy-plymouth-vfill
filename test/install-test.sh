#!/bin/bash

# Runs install.sh as the user with a scratch HOME. sudo, pkexec and omarchy are
# stubs that only record what they were asked to run (NUL-separated) and exit,
# so nothing privileged ever executes; the recorded root-shell script is
# inspected, never run.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

stubs="$scratch/stubs"
argv="$scratch/root-argv"
mkdir -p "$stubs"

for elevate in sudo pkexec; do
  cat >"$stubs/$elevate" <<STUB
#!/bin/bash
printf '%s\0' "\$@" >"$argv"
exit 0
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

HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" </dev/null >/dev/null 2>&1
assert_equals "0" "$?" "install succeeds when the privileged step succeeds"

mapfile -d '' -t recorded <"$argv"
[[ ${recorded[2]} == *'omarchy-vfill-retheme" --force --theme-dir "$theme_dir"'* ]] ||
  fail "the privileged step runs the installed retheme with --force" "${recorded[2]}"
pass "the privileged step runs the installed retheme with --force"
assert_equals "$home/.local/state/omarchy/current/theme" "${recorded[*]: -1}" \
  "the privileged step is given the user's theme directory"

[[ ! -e $hook ]] || fail "install creates no theme-set hook"
pass "install creates no theme-set hook"

# --- A theme-set hook left by an earlier install is removed. ---------------

mkdir -p "$(dirname "$hook")"
printf '#!/bin/bash\nexit 0\n' >"$hook"
chmod +x "$hook"

output=$(HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" </dev/null 2>&1)
assert_equals "0" "$?" "install still succeeds when an earlier hook is present"
[[ ! -e $hook ]] || fail "install removes a pre-existing theme-set hook"
pass "install removes a pre-existing theme-set hook"
[[ $output == *"removing the automatic theme-set hook"* ]] ||
  fail "install says it removed the earlier hook" "$output"
pass "install says it removed the earlier hook"

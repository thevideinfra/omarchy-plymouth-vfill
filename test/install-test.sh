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
HOME="$home" PATH="$stubs:$PATH" bash "$ROOT/install.sh" </dev/null >/dev/null 2>&1
assert_equals "0" "$?" "install succeeds when the privileged step succeeds"

mapfile -d '' -t recorded <"$argv"
[[ ${recorded[2]} == *'omarchy-vfill-retheme" --force --theme-dir "$theme_dir"'* ]] ||
  fail "the privileged step runs the installed retheme with --force" "${recorded[2]}"
pass "the privileged step runs the installed retheme with --force"
assert_equals "$home/.local/state/omarchy/current/theme" "${recorded[*]: -1}" \
  "the privileged step is given the user's theme directory"

hook="$home/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh"
grep -q 'RETHEME=/usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme' "$hook" ||
  fail "the hook points at the installed retheme script"
pass "the hook points at the installed retheme script"

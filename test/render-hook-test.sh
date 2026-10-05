#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

TEMPLATE="$ROOT/hooks/theme-set.sh"
RETHEME_PATH=/usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme

output=$(vfill_render_hook "$TEMPLATE" "$RETHEME_PATH") ||
  fail "renders successfully"
pass "renders successfully"

[[ $output == *"$RETHEME_PATH"* ]] ||
  fail "output contains the installed retheme path"
pass "output contains the installed retheme path"

[[ $output != *__RETHEME_PATH__* ]] ||
  fail "output contains no remaining placeholder"
pass "output contains no remaining placeholder"

printf '%s\n' "$output" | bash -n ||
  fail "rendered output parses as bash"
pass "rendered output parses as bash"

vfill_render_hook "$TEMPLATE" "relative/path" >/dev/null 2>&1 &&
  fail "a relative retheme path is refused"
pass "a relative retheme path is refused"

vfill_render_hook "$ROOT/no-such-template.sh" "$RETHEME_PATH" >/dev/null 2>&1 &&
  fail "a missing template is refused"
pass "a missing template is refused"

# --- The rendered hook acts on --check's exit codes, not just on success. ---
# Everything escalating is stubbed: the retheme is a recording stub with a
# settable exit code, and pkexec only records what it was asked to run. Nothing
# here runs as root and no password prompt can appear.

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

stubs="$scratch/stubs"
log="$scratch/stub.log"
mkdir -p "$stubs"

cat >"$stubs/pkexec" <<STUB
#!/bin/bash
printf 'pkexec %s\n' "\$*" >>"$log"
exit 0
STUB
chmod +x "$stubs/pkexec"

stub_retheme="$scratch/omarchy-vfill-retheme"
cat >"$stub_retheme" <<STUB
#!/bin/bash
printf 'retheme %s\n' "\$*" >>"$log"
exit "\${STUB_CHECK_EXIT:-0}"
STUB
chmod +x "$stub_retheme"

hook="$scratch/omarchy-vfill.sh"
vfill_render_hook "$ROOT/hooks/theme-set.sh" "$stub_retheme" >"$hook" ||
  fail "renders a hook pointing at the stub retheme"
pass "renders a hook pointing at the stub retheme"

hook_home="$scratch/home"
mkdir -p "$hook_home/.local/state/omarchy/current/theme"

run_hook() {
  : >"$log"
  env STUB_CHECK_EXIT="$1" HOME="$hook_home" PATH="$stubs:$PATH" \
    bash "$hook" </dev/null 2>&1
}

escalated() {
  grep -q '^pkexec ' "$log"
}

# 0 means a retheme is needed: escalate.
output=$(run_hook 0)
assert_equals "0" "$?" "the hook succeeds when a retheme is needed"
escalated || fail "the hook escalates when --check exits 0" "$(cat "$log")"
pass "the hook escalates when --check exits 0"

# 3 means already current: nothing to do, nothing said.
output=$(run_hook 3)
assert_equals "0" "$?" "the hook succeeds when the splash is already current"
escalated && fail "the hook does not escalate when --check exits 3" "$(cat "$log")"
pass "the hook does not escalate when --check exits 3"
assert_equals "" "$output" "the hook says nothing when the splash is already current"

# Anything else is an error: do not escalate, do not nag, do not fail the theme
# change -- but do say so, rather than passing the error off as "current".
for code in 1 2 4 127; do
  output=$(run_hook "$code")
  status=$?
  assert_equals "0" "$status" "the hook still exits 0 when --check exits $code"
  escalated && fail "the hook does not escalate when --check exits $code" "$(cat "$log")"
  [[ $output == *"not updated"* ]] ||
    fail "the hook reports a failed check (exit $code)" "$output"
done
pass "a check error neither escalates nor passes for already current"

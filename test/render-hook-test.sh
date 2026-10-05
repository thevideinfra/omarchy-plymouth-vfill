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

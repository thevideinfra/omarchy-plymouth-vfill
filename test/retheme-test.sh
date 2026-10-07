#!/bin/bash

# Exercises only the unprivileged --check path of bin/omarchy-vfill-retheme.
# Never runs the script without --check, never runs it as root, and never
# touches /usr/share: VFILL_THEME_DEST always points at a scratch directory.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

RETHEME="$ROOT/bin/omarchy-vfill-retheme"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

theme_dir="$scratch/theme"
mkdir -p "$theme_dir"
cat >"$theme_dir/colors.toml" <<'EOF'
background = "#140F1F"
foreground = "#DFEDE5"
EOF
magick -size 40x10 xc:white -alpha set "$theme_dir/unlock.png"

logo="$theme_dir/unlock.png"

# --check exits 0 (retheme needed) when the destination has no marker.
dest1="$scratch/dest-no-marker"
mkdir -p "$dest1"
VFILL_THEME_DEST="$dest1" "$RETHEME" --check --theme-dir "$theme_dir"
assert_equals "0" "$?" "--check exits 0 when the destination has no marker"

# --check exits 3 (already current) when the destination holds a matching
# marker. 3 and not 1: every error below exits 1 or 2, and a caller that cannot
# tell them apart reboots on a broken theme.
dest2="$scratch/dest-matching-marker"
mkdir -p "$dest2"
vfill_write_marker "$dest2/.vfill-marker" "140F1F" "DFEDE5" "$logo" "DFEDE5"
VFILL_THEME_DEST="$dest2" "$RETHEME" --check --theme-dir "$theme_dir"
assert_equals "3" "$?" "--check exits 3 when the destination has a matching marker"

# --- Every error is non-zero and is neither 0 nor 3. ----------------------
# This is the whole point of the 3: "already current" has to be impossible to
# confuse with any of these.

dest_err="$scratch/dest-errors"
mkdir -p "$dest_err"

VFILL_THEME_DEST="$dest_err" "$RETHEME" --check --theme-dir "$scratch/no-such-theme" 2>/dev/null
status=$?
[[ $status -ne 0 && $status -ne 3 ]] ||
  fail "a missing theme directory is an error, not 0 and not 3" "exit $status"
pass "a missing theme directory is an error, not 0 and not 3"

no_colors="$scratch/theme-no-colors"
mkdir -p "$no_colors"
cp "$theme_dir/unlock.png" "$no_colors/unlock.png"
VFILL_THEME_DEST="$dest_err" "$RETHEME" --check --theme-dir "$no_colors" 2>/dev/null
status=$?
[[ $status -ne 0 && $status -ne 3 ]] ||
  fail "a theme with no colors.toml is an error, not 0 and not 3" "exit $status"
pass "a theme with no colors.toml is an error, not 0 and not 3"

no_fg="$scratch/theme-no-foreground"
mkdir -p "$no_fg"
printf 'background = "#140F1F"\n' >"$no_fg/colors.toml"
cp "$theme_dir/unlock.png" "$no_fg/unlock.png"
VFILL_THEME_DEST="$dest_err" "$RETHEME" --check --theme-dir "$no_fg" 2>/dev/null
status=$?
[[ $status -ne 0 && $status -ne 3 ]] ||
  fail "a theme with no foreground is an error, not 0 and not 3" "exit $status"
pass "a theme with no foreground is an error, not 0 and not 3"

no_logo="$scratch/theme-no-logo"
mkdir -p "$no_logo"
cp "$theme_dir/colors.toml" "$no_logo/colors.toml"
VFILL_THEME_DEST="$dest_err" OMARCHY_PATH="$scratch/no-such-omarchy" \
  "$RETHEME" --check --theme-dir "$no_logo" 2>/dev/null
status=$?
[[ $status -ne 0 && $status -ne 3 ]] ||
  fail "a theme with no logo at all is an error, not 0 and not 3" "exit $status"
pass "a theme with no logo at all is an error, not 0 and not 3"

# --theme-dir wins over a misleading HOME.
dest3="$scratch/dest-home-precedence"
mkdir -p "$dest3"
output=$(HOME=/nonexistent VFILL_THEME_DEST="$dest3" "$RETHEME" --check --theme-dir "$theme_dir" 2>&1)
status=$?
assert_equals "0" "$status" \
  "--theme-dir wins over HOME: --check succeeds (retheme needed) rather than erroring"
[[ $output != *"/nonexistent"* ]] ||
  fail "--theme-dir wins over HOME: output must never mention /nonexistent" "$output"
pass "--theme-dir wins over HOME: output never mentions /nonexistent"

# --theme-dir with no value, or an empty one, is refused rather than silently
# falling back to the invoking user's HOME: `--theme-dir "$maybe_empty"` used to
# retheme from a directory nobody named. HOME points at nothing here, so a
# regression cannot quietly read the real one.
dest_opt="$scratch/dest-theme-dir-option"
mkdir -p "$dest_opt"
for bad in last-argument empty-value; do
  if [[ $bad == last-argument ]]; then
    output=$(HOME="$scratch/no-home" VFILL_THEME_DEST="$dest_opt" \
      "$RETHEME" --check --theme-dir 2>&1)
  else
    output=$(HOME="$scratch/no-home" VFILL_THEME_DEST="$dest_opt" \
      "$RETHEME" --check --theme-dir "" 2>&1)
  fi
  status=$?
  [[ $status -ne 0 && $status -ne 3 ]] ||
    fail "--theme-dir with an $bad is refused, not treated as 0 or 3" "exit $status: $output"
  [[ $output == *"--theme-dir needs a value"* ]] ||
    fail "--theme-dir with an $bad says the value is missing" "$output"
  [[ $output != *"$scratch/no-home"* ]] ||
    fail "--theme-dir with an $bad never falls back to the invoking HOME" "$output"
done
pass "--theme-dir with a missing or empty value is refused and says so"
assert_equals "" "$(find "$dest_opt" -mindepth 1 | sort)" \
  "a refused --theme-dir writes nothing to the destination"

# --- With no --theme-dir, the theme comes from PKEXEC_UID's passwd home. ----
# Mode auto's polkit rule approves only the argument-free invocation, so this is
# the ONLY way the hook-driven retheme learns which theme directory to read: if
# this resolution breaks, mode auto silently rethemes from the wrong place (or
# from nothing). getent is stubbed so the passwd lookup answers with a scratch
# home and no real passwd entry or real home is ever read; HOME points at
# nothing, so a regression cannot quietly fall back to it and still pass.
pk_home="$scratch/pkexec-home"
pk_theme="$pk_home/.local/state/omarchy/current/theme"
mkdir -p "$pk_theme"
cp "$theme_dir/colors.toml" "$pk_theme/colors.toml"
cp "$theme_dir/unlock.png" "$pk_theme/unlock.png"

getent_stubs="$scratch/getent-stubs"
mkdir -p "$getent_stubs"
cat >"$getent_stubs/getent" <<STUB
#!/bin/bash
# Answers only the passwd lookup the retheme makes for the invoking uid.
if [[ \$1 == passwd && \$2 == 4242 ]]; then
  printf 'vfilltest:x:4242:4242::%s:/bin/bash\n' "$pk_home"
  exit 0
fi
exit 2
STUB
chmod +x "$getent_stubs/getent"

# The marker matches the PKEXEC_UID home's theme and names its unlock.png as the
# logo source, so exit 3 is reachable only if that directory is what was
# resolved. Any other outcome -- $HOME, an empty path -- has no theme there and
# exits 1.
dest_pk="$scratch/dest-pkexec-uid"
mkdir -p "$dest_pk"
vfill_write_marker "$dest_pk/.vfill-marker" "140F1F" "DFEDE5" "$pk_theme/unlock.png" "DFEDE5"
output=$(env PATH="$getent_stubs:$PATH" HOME="$scratch/no-home" PKEXEC_UID=4242 \
  VFILL_THEME_DEST="$dest_pk" "$RETHEME" --check 2>&1)
status=$?
assert_equals "3" "$status" \
  "with no --theme-dir at all, the theme is resolved from PKEXEC_UID's passwd home"
[[ $output != *"$scratch/no-home"* ]] ||
  fail "the PKEXEC_UID resolution never falls back to HOME" "$output"
pass "the PKEXEC_UID resolution never falls back to HOME"

# The same invocation against a theme that is NOT the resolved one must not
# report "already current": this is what proves the assertion above is about
# PKEXEC_UID and not about any directory happening to match.
dest_other="$scratch/dest-pkexec-uid-other"
mkdir -p "$dest_other"
vfill_write_marker "$dest_other/.vfill-marker" "140F1F" "DFEDE5" "$theme_dir/unlock.png" "DFEDE5"
env PATH="$getent_stubs:$PATH" HOME="$scratch/no-home" PKEXEC_UID=4242 \
  VFILL_THEME_DEST="$dest_other" "$RETHEME" --check >/dev/null 2>&1
assert_equals "0" "$?" \
  "a marker naming a different theme's logo still asks for a retheme (exit 0)"

# A uid with no passwd entry falls back to HOME rather than resolving an empty
# path and reading /.local/state/...: HOME has no theme either, so this is the
# error exit, not a silent success.
output=$(env PATH="$getent_stubs:$PATH" HOME="$scratch/no-home" PKEXEC_UID=9999 \
  VFILL_THEME_DEST="$dest_pk" "$RETHEME" --check 2>&1)
status=$?
[[ $status -ne 0 && $status -ne 3 ]] ||
  fail "a PKEXEC_UID with no passwd entry is an error, not 0 and not 3" "exit $status: $output"
[[ $output == *"$scratch/no-home/.local/state/omarchy/current/theme"* ]] ||
  fail "a PKEXEC_UID with no passwd entry falls back to HOME and says where it looked" "$output"
pass "a PKEXEC_UID with no passwd entry falls back to HOME and says where it looked"

# An unknown option exits non-zero.
dest4="$scratch/dest-unknown-option"
mkdir -p "$dest4"
VFILL_THEME_DEST="$dest4" "$RETHEME" --check --bogus-option 2>/dev/null
status=$?
[[ $status -ne 0 ]] || fail "an unknown option exits non-zero"
pass "an unknown option exits non-zero"

# --check writes nothing: the scratch destination is unchanged afterwards.
dest5="$scratch/dest-no-writes"
mkdir -p "$dest5"
before=$(find "$dest5" -mindepth 1 | sort)
VFILL_THEME_DEST="$dest5" "$RETHEME" --check --theme-dir "$theme_dir" >/dev/null 2>&1
after=$(find "$dest5" -mindepth 1 | sort)
assert_equals "$before" "$after" "--check writes nothing to the destination"

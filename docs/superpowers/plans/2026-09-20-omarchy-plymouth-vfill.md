# omarchy-plymouth-vfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the vertical logo fill boot splash as a standalone Plymouth theme that survives Omarchy package upgrades and follows the active theme's colours.

**Architecture:** A Plymouth theme installed under its own name (`omarchy-vfill`) so no Omarchy component ever rewrites it. Pure logic lives in a sourceable bash library tested without root; thin root entry points (`install.sh`, `uninstall.sh`, `bin/omarchy-vfill-retheme`) compose it. A `theme-set` hook compares the active theme against a marker baked into the installed theme and only elevates when something actually changed.

**Tech Stack:** bash, ImageMagick (`magick`), Plymouth script theme format, plain-bash test harness modelled on Omarchy's `test/shell.d/`.

**Spec:** `docs/superpowers/specs/2026-09-19-omarchy-plymouth-vfill-design.md`

## Global Constraints

- Theme directory: `/usr/share/plymouth/themes/omarchy-vfill/` — never write to `/usr/share/plymouth/themes/omarchy/`.
- Theme name for `plymouth-set-default-theme`: `omarchy-vfill`.
- Assets required by the script: `logo.png`, `entry.png`, `lock.png`, `bullet.png`. No `progress_bar.png` / `progress_box.png`.
- `fake_progress_duration` stays at the upstream default `15.0`.
- Shebangs are `#!/bin/bash`, never `#!/usr/bin/env bash`.
- Two-space indentation, no tabs. `[[ ]]` for string/file tests, `(( ))` for numeric.
- Background colour is three floats 0–1 at 3 decimal places, e.g. `#140F1F` → `0.078, 0.059, 0.122`.
- Recolour command is `magick "$f" -channel RGB +level-colors "#$hex","#$hex" "$f"`, matching `omarchy-plymouth-set`.
- Initramfs rebuild order: `limine-mkinitcpio`, else `mkinitcpio -P`, else `dracut --force`. Only the first is testable on the target machine; the others must be labelled untested in the README.
- Never add `Co-Authored-By` or "Generated with Claude Code" trailers to commits.
- Marker file: `/usr/share/plymouth/themes/omarchy-vfill/.vfill-marker`.

## File Structure

| File | Responsibility |
| --- | --- |
| `lib/vfill.sh` | Pure functions: colour parsing, hex→float, logo resolution, marker read/compare/write, initramfs command detection. No root, no side effects outside given paths. |
| `theme/omarchy-vfill.script` | Vendored Plymouth script (fill + `layout()`), from PR #12040. |
| `theme/omarchy-vfill.plymouth` | Plymouth theme descriptor. |
| `bin/omarchy-vfill-retheme` | Root entry point: recolour installed theme from active Omarchy theme, rebuild initramfs. |
| `hooks/theme-set.sh` | User-level hook: compare marker, elevate via `pkexec` only when needed. |
| `install.sh` | Migration detection, stage theme, set default, rebuild, install hook. |
| `uninstall.sh` | Remove theme + hook, restore previous default theme, rebuild. |
| `test/base-test.sh` | `pass` / `fail` helpers, scratch dir creation. |
| `test/*-test.sh` | One file per library concern. |
| `test/all` | Runner. |
| `README.md` | Install, uninstall, tested/untested matrix. |

---

### Task 1: Test harness and colour parsing

**Files:**
- Create: `test/base-test.sh`
- Create: `test/all`
- Create: `lib/vfill.sh`
- Test: `test/colors-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `vfill_read_color <toml_path> <key>` → prints six-hex-digit colour without `#`, returns 1 if absent. `vfill_hex_to_floats <hex>` → prints `R, G, B` at 3 decimals.

- [ ] **Step 1: Write the failing test**

Create `test/base-test.sh`:

```bash
#!/bin/bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/base-test.sh from a test; do not run it directly" >&2
  exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

assert_equals() {
  local expected="$1" actual="$2" description="$3"

  [[ $expected == "$actual" ]] ||
    fail "$description" "expected: $expected
actual:   $actual"
  pass "$description"
}

new_scratch_dir() {
  local dir
  dir=$(mktemp -d)
  [[ -n $dir && -d $dir ]] || fail "scratch directory is created"
  printf '%s\n' "$dir"
}
```

Create `test/all`:

```bash
#!/bin/bash

set -uo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
failed=0

for test_file in "$root"/test/*-test.sh; do
  [[ $(basename "$test_file") == "base-test.sh" ]] && continue
  printf '# %s\n' "$(basename "$test_file")"
  if ! bash "$test_file"; then
    failed=$((failed + 1))
  fi
done

if ((failed > 0)); then
  printf '\n%d test file(s) failed\n' "$failed" >&2
  exit 1
fi

printf '\nall test files passed\n'
```

Create `test/colors-test.sh`:

```bash
#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

cat >"$scratch/colors.toml" <<'EOF'
mode = "dark"

accent = "#8be9fd"

background = "#140F1F"
dark_background = "#21222c"
lighter_background = "#343746"

foreground = "#DFEDE5"
EOF

assert_equals "140F1F" "$(vfill_read_color "$scratch/colors.toml" background)" \
  "background is read from colors.toml"

assert_equals "DFEDE5" "$(vfill_read_color "$scratch/colors.toml" foreground)" \
  "foreground is read from colors.toml"

# dark_background and lighter_background must not satisfy a background lookup.
assert_equals "140F1F" "$(vfill_read_color "$scratch/colors.toml" background)" \
  "prefixed keys do not shadow background"

vfill_read_color "$scratch/colors.toml" nonexistent >/dev/null 2>&1 &&
  fail "a missing key returns non-zero"
pass "a missing key returns non-zero"

assert_equals "0.078, 0.059, 0.122" "$(vfill_hex_to_floats 140F1F)" \
  "hex converts to three Plymouth floats"

assert_equals "1.000, 1.000, 1.000" "$(vfill_hex_to_floats ffffff)" \
  "white converts to 1.000"

assert_equals "0.000, 0.000, 0.000" "$(vfill_hex_to_floats 000000)" \
  "black converts to 0.000"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/colors-test.sh`
Expected: FAIL — `lib/vfill.sh` does not exist, `source` errors.

- [ ] **Step 3: Write minimal implementation**

Create `lib/vfill.sh`:

```bash
#!/bin/bash

# Shared helpers for omarchy-plymouth-vfill. Sourced by the install, uninstall
# and retheme entry points, and exercised directly by the tests. Everything here
# is pure: it reads what it is given and prints a result, so the logic can be
# tested without root and without touching a real Plymouth theme.

# Read a colour key out of an Omarchy colors.toml. The match is anchored so
# dark_background and lighter_background cannot satisfy a lookup for background.
vfill_read_color() {
  local toml="$1" key="$2" value

  [[ -f $toml ]] || return 1

  value=$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?#?([0-9a-fA-F]{6})\"?[[:space:]]*\$/\\1/p" "$toml" | head -1)

  [[ -n $value ]] || return 1
  printf '%s\n' "$value"
}

# Plymouth's Window.SetBackground*Color takes three floats in 0..1, not hex.
vfill_hex_to_floats() {
  local hex="${1#\#}" r g b

  [[ $hex =~ ^[0-9a-fA-F]{6}$ ]] || return 1

  r=$(awk -v n=$((16#${hex:0:2})) 'BEGIN { printf "%.3f", n / 255 }')
  g=$(awk -v n=$((16#${hex:2:2})) 'BEGIN { printf "%.3f", n / 255 }')
  b=$(awk -v n=$((16#${hex:4:2})) 'BEGIN { printf "%.3f", n / 255 }')

  printf '%s, %s, %s\n' "$r" "$g" "$b"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x test/all && bash test/colors-test.sh`
Expected: PASS — eight `ok -` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/vfill.sh test/base-test.sh test/all test/colors-test.sh
git commit -m "Add colour parsing helpers and test harness"
```

---

### Task 2: Logo resolution and marker handling

**Files:**
- Modify: `lib/vfill.sh`
- Test: `test/marker-test.sh`

**Interfaces:**
- Consumes: `vfill_read_color` from Task 1.
- Produces: `vfill_resolve_logo <theme_dir> <omarchy_path>` → prints an absolute path to the logo source. `vfill_write_marker <marker_path> <bg> <fg> <logo_source>` → writes the marker. `vfill_marker_matches <marker_path> <bg> <fg> <logo_source>` → returns 0 when every field matches, 1 otherwise.

- [ ] **Step 1: Write the failing test**

Create `test/marker-test.sh`:

```bash
#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/theme-with-logo" "$scratch/theme-without-logo" "$scratch/omarchy"
printf 'fake png\n' >"$scratch/theme-with-logo/unlock.png"
printf 'fake svg\n' >"$scratch/omarchy/logo.svg"

assert_equals "$scratch/theme-with-logo/unlock.png" \
  "$(vfill_resolve_logo "$scratch/theme-with-logo" "$scratch/omarchy")" \
  "a theme shipping unlock.png supplies the logo"

assert_equals "$scratch/omarchy/logo.svg" \
  "$(vfill_resolve_logo "$scratch/theme-without-logo" "$scratch/omarchy")" \
  "a theme without unlock.png falls back to omarchy logo.svg"

marker="$scratch/.vfill-marker"
logo="$scratch/theme-with-logo/unlock.png"

vfill_write_marker "$marker" "140F1F" "DFEDE5" "$logo"
[[ -f $marker ]] || fail "the marker file is written"
pass "the marker file is written"

vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" ||
  fail "identical values match the marker"
pass "identical values match the marker"

vfill_marker_matches "$marker" "282A36" "DFEDE5" "$logo" &&
  fail "a changed background does not match"
pass "a changed background does not match"

vfill_marker_matches "$marker" "140F1F" "FFFFFF" "$logo" &&
  fail "a changed foreground does not match"
pass "a changed foreground does not match"

# Same path, different bytes: the hash must notice.
printf 'different bytes\n' >"$logo"
vfill_marker_matches "$marker" "140F1F" "DFEDE5" "$logo" &&
  fail "an edited logo with an unchanged path does not match"
pass "an edited logo with an unchanged path does not match"

vfill_marker_matches "$scratch/absent-marker" "140F1F" "DFEDE5" "$logo" &&
  fail "a missing marker never matches"
pass "a missing marker never matches"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/marker-test.sh`
Expected: FAIL — `vfill_resolve_logo: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/vfill.sh`:

```bash
# Prefer the active theme's own artwork. Themes are not required to ship
# unlock.png (aurora, dracula and texas-longhorns do not), so fall back to
# Omarchy's logo.svg, which is greyscale plus alpha and recolours cleanly.
vfill_resolve_logo() {
  local theme_dir="$1" omarchy_path="$2"

  if [[ -f $theme_dir/unlock.png ]]; then
    printf '%s\n' "$theme_dir/unlock.png"
    return 0
  fi

  if [[ -f $omarchy_path/logo.svg ]]; then
    printf '%s\n' "$omarchy_path/logo.svg"
    return 0
  fi

  return 1
}

# The marker records what is currently baked into the installed theme, so a
# theme change that alters nothing we care about costs no rebuild and no
# authentication prompt.
vfill_write_marker() {
  local marker="$1" background="$2" foreground="$3" logo="$4"

  cat >"$marker" <<EOF
background=$background
foreground=$foreground
logo_source=$logo
logo_sha256=$(vfill_logo_hash "$logo")
EOF
}

vfill_logo_hash() {
  local logo="$1"

  [[ -f $logo ]] || return 1
  sha256sum "$logo" | cut -d' ' -f1
}

# Hash the logo as well as its path: re-theming can leave the path identical
# while replacing the artwork underneath it.
vfill_marker_matches() {
  local marker="$1" background="$2" foreground="$3" logo="$4"
  local want_hash

  [[ -f $marker ]] || return 1
  want_hash=$(vfill_logo_hash "$logo") || return 1

  local have_background have_foreground have_logo have_hash
  have_background=$(sed -nE 's/^background=(.*)$/\1/p' "$marker")
  have_foreground=$(sed -nE 's/^foreground=(.*)$/\1/p' "$marker")
  have_logo=$(sed -nE 's/^logo_source=(.*)$/\1/p' "$marker")
  have_hash=$(sed -nE 's/^logo_sha256=(.*)$/\1/p' "$marker")

  [[ $have_background == "$background" ]] || return 1
  [[ $have_foreground == "$foreground" ]] || return 1
  [[ $have_logo == "$logo" ]] || return 1
  [[ $have_hash == "$want_hash" ]] || return 1

  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/marker-test.sh`
Expected: PASS — nine `ok -` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/vfill.sh test/marker-test.sh
git commit -m "Add logo resolution and retheme marker comparison"
```

---

### Task 3: Initramfs command detection

**Files:**
- Modify: `lib/vfill.sh`
- Test: `test/initramfs-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `vfill_initramfs_command` → prints the rebuild command as a single string, returns 1 when no known tool is on `PATH`.

- [ ] **Step 1: Write the failing test**

Create `test/initramfs-test.sh`:

```bash
#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

make_stub() {
  local name="$1"
  printf '#!/bin/bash\nexit 0\n' >"$scratch/bin/$name"
  chmod +x "$scratch/bin/$name"
}

mkdir -p "$scratch/bin"
real_path="$PATH"

# limine-mkinitcpio wins when present, matching omarchy-plymouth-set.
PATH="$scratch/bin"
make_stub limine-mkinitcpio
make_stub mkinitcpio
assert_equals "limine-mkinitcpio" "$(vfill_initramfs_command)" \
  "limine-mkinitcpio takes precedence"

rm "$scratch/bin/limine-mkinitcpio"
assert_equals "mkinitcpio -P" "$(vfill_initramfs_command)" \
  "mkinitcpio -P is used when limine-mkinitcpio is absent"

rm "$scratch/bin/mkinitcpio"
make_stub dracut
assert_equals "dracut --force" "$(vfill_initramfs_command)" \
  "dracut is the last resort"

rm "$scratch/bin/dracut"
vfill_initramfs_command >/dev/null 2>&1 &&
  fail "no known initramfs tool returns non-zero"
pass "no known initramfs tool returns non-zero"

PATH="$real_path"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/initramfs-test.sh`
Expected: FAIL — `vfill_initramfs_command: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/vfill.sh`:

```bash
# Mirrors the detection omarchy-plymouth-set performs, with dracut added for
# distributions that do not use mkinitcpio. Only the limine-mkinitcpio path has
# been exercised on real hardware; see README.
vfill_initramfs_command() {
  if command -v limine-mkinitcpio >/dev/null; then
    printf 'limine-mkinitcpio\n'
  elif command -v mkinitcpio >/dev/null; then
    printf 'mkinitcpio -P\n'
  elif command -v dracut >/dev/null; then
    printf 'dracut --force\n'
  else
    return 1
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/initramfs-test.sh`
Expected: PASS — four `ok -` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/vfill.sh test/initramfs-test.sh
git commit -m "Add initramfs tool detection"
```

---

### Task 4: Vendor the theme and stage it

**Files:**
- Create: `theme/omarchy-vfill.script`
- Create: `theme/omarchy-vfill.plymouth`
- Modify: `lib/vfill.sh`
- Test: `test/stage-test.sh`

**Interfaces:**
- Consumes: `vfill_read_color`, `vfill_hex_to_floats`, `vfill_resolve_logo`, `vfill_write_marker` from Tasks 1–2.
- Produces: `vfill_stage_theme <repo_dir> <dest_dir> <theme_dir> <omarchy_path>` → populates `dest_dir` with the recoloured theme and marker, returns non-zero on failure.

- [ ] **Step 1: Vendor the script from the PR branch**

Run:

```bash
cd ~/Projects/omarchy && \
git show plymouth-vertical-logo-fill:default/plymouth/omarchy.script \
  > ~/Projects/omarchy-plymouth-vfill/theme/omarchy-vfill.script
```

Verify it is the correct variant:

```bash
cd ~/Projects/omarchy-plymouth-vfill && \
grep -c 'position_fill' theme/omarchy-vfill.script && \
grep -c 'fun layout()' theme/omarchy-vfill.script && \
grep -c 'progress_bar' theme/omarchy-vfill.script
```

Expected: `3`, `1`, `0` — the fill variant, with hotplug layout, and no stock progress bar references.

- [ ] **Step 2: Write the theme descriptor**

Create `theme/omarchy-vfill.plymouth`:

```ini
[Plymouth Theme]
Name=Omarchy VFill
Description=Omarchy boot splash with the logo filling from the bottom up.
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/omarchy-vfill
ScriptFile=/usr/share/plymouth/themes/omarchy-vfill/omarchy-vfill.script
ConsoleLogBackgroundColor=0x1a1b26
MonospaceFont=Cantarell 11
Font=Cantarell 11
```

- [ ] **Step 3: Write the failing test**

Create `test/stage-test.sh`:

```bash
#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

command -v magick >/dev/null || fail "magick is available"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

theme_dir="$scratch/theme"
omarchy_path="$scratch/omarchy"
dest="$scratch/dest"
mkdir -p "$theme_dir" "$omarchy_path/default/plymouth" "$dest"

cat >"$theme_dir/colors.toml" <<'EOF'
background = "#140F1F"
foreground = "#DFEDE5"
EOF

magick -size 40x10 xc:white -alpha set "$theme_dir/unlock.png"
for asset in entry.png lock.png bullet.png; do
  magick -size 8x8 xc:white -alpha set "$omarchy_path/default/plymouth/$asset"
done

vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" ||
  fail "staging succeeds"
pass "staging succeeds"

for asset in omarchy-vfill.script omarchy-vfill.plymouth logo.png entry.png lock.png bullet.png .vfill-marker; do
  [[ -f $dest/$asset ]] || fail "staging produces $asset"
done
pass "staging produces every required asset"

[[ -f $dest/progress_bar.png ]] &&
  fail "staging does not copy the unused progress bar assets"
pass "staging does not copy the unused progress bar assets"

assert_equals "Window.SetBackgroundTopColor(0.078, 0.059, 0.122);" \
  "$(grep -m1 '^Window.SetBackgroundTopColor' "$dest/omarchy-vfill.script")" \
  "the background is written into the staged script"

assert_equals "Window.SetBackgroundBottomColor(0.078, 0.059, 0.122);" \
  "$(grep -m1 '^Window.SetBackgroundBottomColor' "$dest/omarchy-vfill.script")" \
  "the bottom background matches the top"

vfill_marker_matches "$dest/.vfill-marker" "140F1F" "DFEDE5" "$theme_dir/unlock.png" ||
  fail "the staged marker reflects what was baked in"
pass "the staged marker reflects what was baked in"

# A theme with no unlock.png must still stage, using the omarchy fallback.
rm "$theme_dir/unlock.png"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="10"><rect width="40" height="10" fill="#888"/></svg>\n' \
  >"$omarchy_path/logo.svg"
rm -rf "${dest:?}"/*
vfill_stage_theme "$ROOT" "$dest" "$theme_dir" "$omarchy_path" ||
  fail "staging succeeds for a theme without unlock.png"
pass "staging succeeds for a theme without unlock.png"
[[ -f $dest/logo.png ]] || fail "the fallback logo is rendered to logo.png"
pass "the fallback logo is rendered to logo.png"
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bash test/stage-test.sh`
Expected: FAIL — `vfill_stage_theme: command not found`.

- [ ] **Step 5: Write minimal implementation**

Append to `lib/vfill.sh`:

```bash
# Build a complete, recoloured theme in dest_dir. Kept free of root operations
# so the tests can stage into a scratch directory; callers that need to publish
# into /usr/share do the privileged copy themselves.
vfill_stage_theme() {
  local repo="$1" dest="$2" theme_dir="$3" omarchy_path="$4"
  local background foreground logo floats

  background=$(vfill_read_color "$theme_dir/colors.toml" background) || return 1
  foreground=$(vfill_read_color "$theme_dir/colors.toml" foreground) || return 1
  logo=$(vfill_resolve_logo "$theme_dir" "$omarchy_path") || return 1
  floats=$(vfill_hex_to_floats "$background") || return 1

  mkdir -p "$dest" || return 1

  install -m 0644 "$repo/theme/omarchy-vfill.plymouth" "$dest/omarchy-vfill.plymouth" || return 1
  install -m 0644 "$repo/theme/omarchy-vfill.script" "$dest/omarchy-vfill.script" || return 1

  sed -i \
    -e "s/^Window.SetBackgroundTopColor.*/Window.SetBackgroundTopColor($floats);/" \
    -e "s/^Window.SetBackgroundBottomColor.*/Window.SetBackgroundBottomColor($floats);/" \
    "$dest/omarchy-vfill.script" || return 1

  # The prompt furniture is recoloured to the theme foreground, exactly as
  # omarchy-plymouth-set does for Omarchy's own theme.
  local asset
  for asset in entry.png lock.png bullet.png; do
    install -m 0644 "$omarchy_path/default/plymouth/$asset" "$dest/$asset" || return 1
    magick "$dest/$asset" -channel RGB +level-colors "#$foreground","#$foreground" "$dest/$asset" || return 1
  done

  # A theme's own unlock.png is already coloured and is used as-is. The
  # greyscale logo.svg fallback is rendered and flattened to the foreground.
  if [[ $logo == *.svg ]]; then
    magick -background none "$logo" "$dest/logo.png" || return 1
    magick "$dest/logo.png" -channel RGB +level-colors "#$foreground","#$foreground" "$dest/logo.png" || return 1
  else
    install -m 0644 "$logo" "$dest/logo.png" || return 1
  fi

  vfill_write_marker "$dest/.vfill-marker" "$background" "$foreground" "$logo" || return 1
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash test/stage-test.sh`
Expected: PASS — seven `ok -` lines, exit 0.

- [ ] **Step 7: Run the whole suite**

Run: `bash test/all`
Expected: PASS — every file passes, `all test files passed`.

- [ ] **Step 8: Commit**

```bash
git add theme/ lib/vfill.sh test/stage-test.sh
git commit -m "Vendor the vertical-fill theme and add staging"
```

---

### Task 5: Retheme entry point and theme-set hook

> **Note (2026-10-06):** `--check`'s exit codes below are superseded. As shipped
> they are **0** a retheme is needed, **3** the splash is already current, **1**
> an error (no active theme, or no colour/logo), **2** `--check` combined with `--force`; usage errors
> (`--theme-dir needs a value`, an unknown option) exit **1**. "Already current" moved off 1 so a caller cannot read a broken
> theme as "nothing to do"; anything that is neither 0 nor 3 is a failure. The
> plan text that follows is left as it was written.

**Files:**
- Create: `bin/omarchy-vfill-retheme`
- Create: `hooks/theme-set.sh`

**Interfaces:**
- Consumes: `vfill_stage_theme`, `vfill_marker_matches`, `vfill_read_color`, `vfill_resolve_logo`, `vfill_initramfs_command`.
- Produces: `omarchy-vfill-retheme [--check]` — `--check` exits 0 when a retheme is needed and 1 when it is not, performing no writes.

- [ ] **Step 1: Write the retheme entry point**

Create `bin/omarchy-vfill-retheme`:

```bash
#!/bin/bash

# Recolour the installed omarchy-vfill Plymouth theme from the active Omarchy
# theme and rebuild the initramfs. Run as root; the theme-set hook elevates via
# pkexec, and it is safe to run by hand.
#
#   omarchy-vfill-retheme          recolour if needed, then rebuild
#   omarchy-vfill-retheme --check  exit 0 if a retheme is needed, 1 if not
#
# --check performs no writes and needs no privileges, so the hook can decide
# whether to prompt at all.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "$(readlink -f "$0")")/.." && pwd)
THEME_DEST=/usr/share/plymouth/themes/omarchy-vfill
OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
CURRENT_THEME=${VFILL_THEME_DIR:-$HOME/.local/state/omarchy/current/theme}

source "$REPO/lib/vfill.sh"

if [[ ! -d $CURRENT_THEME ]]; then
  echo "omarchy-vfill-retheme: no active Omarchy theme at $CURRENT_THEME" >&2
  exit 1
fi

background=$(vfill_read_color "$CURRENT_THEME/colors.toml" background) || {
  echo "omarchy-vfill-retheme: no background in $CURRENT_THEME/colors.toml" >&2
  exit 1
}
foreground=$(vfill_read_color "$CURRENT_THEME/colors.toml" foreground) || {
  echo "omarchy-vfill-retheme: no foreground in $CURRENT_THEME/colors.toml" >&2
  exit 1
}
logo=$(vfill_resolve_logo "$CURRENT_THEME" "$OMARCHY_PATH") || {
  echo "omarchy-vfill-retheme: no logo available" >&2
  exit 1
}

if vfill_marker_matches "$THEME_DEST/.vfill-marker" "$background" "$foreground" "$logo"; then
  [[ ${1:-} == "--check" ]] && exit 1
  echo "omarchy-vfill-retheme: already current, nothing to do"
  exit 0
fi

[[ ${1:-} == "--check" ]] && exit 0

if ((EUID != 0)); then
  echo "omarchy-vfill-retheme: must run as root" >&2
  exit 1
fi

staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT

vfill_stage_theme "$REPO" "$staging" "$CURRENT_THEME" "$OMARCHY_PATH" || {
  echo "omarchy-vfill-retheme: staging failed" >&2
  exit 1
}

install -d -m 0755 -o root -g root "$THEME_DEST"
for file in "$staging"/* "$staging"/.vfill-marker; do
  install -m 0644 -o root -g root "$file" "$THEME_DEST/$(basename "$file")"
done

plymouth-set-default-theme omarchy-vfill

rebuild=$(vfill_initramfs_command) || {
  echo "omarchy-vfill-retheme: no initramfs tool found" >&2
  exit 1
}
echo "omarchy-vfill-retheme: rebuilding initramfs with $rebuild"
$rebuild
```

- [ ] **Step 2: Write the hook**

Create `hooks/theme-set.sh`:

```bash
#!/bin/bash

# Omarchy theme-set hook: keep the omarchy-vfill boot splash in step with the
# desktop theme.
#
# Runs as the user. --check needs no privileges and performs no writes, so when
# nothing relevant changed this exits silently and no authentication prompt ever
# appears. Only a real change escalates.

set -uo pipefail

RETHEME=__RETHEME_PATH__

[[ -x $RETHEME ]] || exit 0

# Exit 0 from --check means a retheme is needed.
"$RETHEME" --check || exit 0

command -v omarchy-notification-send >/dev/null &&
  omarchy-notification-send "Boot splash" "Recolouring for the new theme" 2>/dev/null

pkexec "$RETHEME"
```

- [ ] **Step 3: Verify --check is side-effect free and honest**

Run:

```bash
cd ~/Projects/omarchy-plymouth-vfill
chmod +x bin/omarchy-vfill-retheme hooks/theme-set.sh
VFILL_THEME_DIR=$HOME/.local/state/omarchy/current/theme \
  bash bin/omarchy-vfill-retheme --check; echo "check exit=$?"
ls /usr/share/plymouth/themes/ | grep -c omarchy-vfill
```

Expected: `check exit=0` (theme is not installed yet, so a retheme is needed) and `0` (nothing was created — `--check` wrote nothing).

- [ ] **Step 4: Commit**

```bash
git add bin/omarchy-vfill-retheme hooks/theme-set.sh
git commit -m "Add retheme entry point and theme-set hook"
```

---

### Task 6: Install and uninstall

**Files:**
- Create: `install.sh`
- Create: `uninstall.sh`

**Interfaces:**
- Consumes: `bin/omarchy-vfill-retheme`, `hooks/theme-set.sh`, `vfill_initramfs_command`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write install.sh**

Create `install.sh`:

```bash
#!/bin/bash

# Install the omarchy-vfill Plymouth theme and its theme-set hook.
#
# The theme is installed under its own name, so no Omarchy component and no
# package upgrade ever rewrites it: omarchy-plymouth-set only writes
# themes/omarchy, pacman owns only that path, and omarchy-theme-set does not
# touch Plymouth at all.
#
# Idempotent: re-running reinstalls from the current source and recolours.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
HOOK_DIR="$HOME/.config/omarchy/hooks/theme-set.d"
HOOK_DEST="$HOOK_DIR/omarchy-vfill.sh"
LEGACY_DIR="$HOME/.config/omarchy/plymouth-vfill"

source "$REPO/lib/vfill.sh"

for required in magick plymouth-set-default-theme; do
  command -v "$required" >/dev/null || {
    echo "install: missing required command: $required" >&2
    exit 1
  }
done

vfill_initramfs_command >/dev/null || {
  echo "install: no supported initramfs tool (limine-mkinitcpio, mkinitcpio, dracut)" >&2
  exit 1
}

# The earlier approach patched Omarchy's own packaged theme from a hook. Leaving
# it in place would mean two mechanisms fighting over the boot splash.
if [[ -d $LEGACY_DIR ]] || [[ -f $HOOK_DIR/reapply-hook.sh ]]; then
  echo "install: a previous hook-patch installation is present."
  echo "  It patched Omarchy's packaged theme, which package upgrades overwrite."
  echo "  This will remove it and restore Omarchy's stock theme before continuing."
  read -r -p "  Remove it? [y/N] " reply
  [[ $reply == [yY] ]] || {
    echo "install: aborted; nothing was changed" >&2
    exit 1
  }

  rm -rf -- "$LEGACY_DIR"
  rm -f -- "$HOOK_DIR/reapply-hook.sh" \
    "$HOME/.config/omarchy/hooks/post-update.d/reapply-hook.sh"

  if command -v omarchy >/dev/null; then
    echo "install: restoring Omarchy's stock Plymouth theme"
    omarchy plymouth reset
  fi
fi

install -d -m 0755 "$HOOK_DIR"
sed "s#__RETHEME_PATH__#$REPO/bin/omarchy-vfill-retheme#" \
  "$REPO/hooks/theme-set.sh" >"$HOOK_DEST"
chmod +x "$HOOK_DEST"
chmod +x "$REPO/bin/omarchy-vfill-retheme"

echo "install: staging and applying the theme (requires root)"
if [[ -t 0 ]]; then
  sudo "$REPO/bin/omarchy-vfill-retheme"
else
  pkexec "$REPO/bin/omarchy-vfill-retheme"
fi

echo "install: done. Reboot to see the new boot splash."
```

- [ ] **Step 2: Write uninstall.sh**

Create `uninstall.sh`:

```bash
#!/bin/bash

# Remove the omarchy-vfill theme and hook, and hand the boot splash back to
# Omarchy's own theme.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
THEME_DEST=/usr/share/plymouth/themes/omarchy-vfill
HOOK_DEST="$HOME/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh"

source "$REPO/lib/vfill.sh"

rm -f -- "$HOOK_DEST"

rebuild=$(vfill_initramfs_command) || {
  echo "uninstall: no initramfs tool found" >&2
  exit 1
}

run_root() {
  if [[ -t 0 ]]; then
    sudo "$@"
  else
    pkexec "$@"
  fi
}

run_root /bin/bash -c "
  rm -rf -- '$THEME_DEST'
  plymouth-set-default-theme omarchy
  $rebuild
"

echo "uninstall: done. The stock Omarchy splash returns on the next boot."
```

- [ ] **Step 3: Verify both are syntactically valid and refuse cleanly**

Run:

```bash
cd ~/Projects/omarchy-plymouth-vfill
chmod +x install.sh uninstall.sh
bash -n install.sh && echo "install.sh parses"
bash -n uninstall.sh && echo "uninstall.sh parses"
bash -n bin/omarchy-vfill-retheme && echo "retheme parses"
bash -n lib/vfill.sh && echo "lib parses"
```

Expected: four `parses` lines.

- [ ] **Step 4: Commit**

```bash
git add install.sh uninstall.sh
git commit -m "Add install and uninstall scripts"
```

---

### Task 7: README and machine verification

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Write README.md**

Create `README.md`:

````markdown
# omarchy-plymouth-vfill

An Omarchy boot splash where the logo fills from the bottom up as the system
boots, instead of the stock horizontal progress bar.

## Why a separate theme

Omarchy's own Plymouth theme lives at `/usr/share/plymouth/themes/omarchy` and
is owned by the `omarchy-settings` package, so every upgrade overwrites it. This
installs under its own name instead:

- `omarchy-plymouth-set` only ever writes `themes/omarchy`.
- Pacman owns only the files under `themes/omarchy`.
- `omarchy-theme-set` does not touch Plymouth at all.

So nothing upstream rewrites `omarchy-vfill`, and keeping it in step with the
desktop theme becomes this project's job.

## Install

```bash
git clone <repo> ~/Projects/omarchy-plymouth-vfill
cd ~/Projects/omarchy-plymouth-vfill
./install.sh
```

Reboot to see it.

The installer detects an earlier hook-patch installation of the same idea and
offers to remove it first; leaving both in place would mean two mechanisms
fighting over the splash.

## Theme following

A `theme-set` hook keeps the splash in step with `omarchy theme set`. It
compares the active theme's background, foreground and logo against a marker
baked into the installed theme:

- Nothing relevant changed: exits silently, no prompt.
- Something changed: authenticates once, recolours, rebuilds the initramfs
  (roughly 90 seconds).

The logo comes from the active theme's `unlock.png` when it ships one, and
otherwise from Omarchy's `logo.svg` recoloured to the theme foreground. Not
every theme ships `unlock.png` — `aurora`, `dracula` and `texas-longhorns` do
not.

To recolour by hand at any time:

```bash
sudo ./bin/omarchy-vfill-retheme
```

## Uninstall

```bash
./uninstall.sh
```

Restores Omarchy's stock splash.

## Requirements

- Plymouth
- ImageMagick (`magick`) — already an effective Omarchy dependency
- One of: `limine-mkinitcpio`, `mkinitcpio`, `dracut`

## Tested

| Path | Status |
| --- | --- |
| `limine-mkinitcpio` (UKI) | Tested on real hardware |
| `mkinitcpio -P` | **Untested** — written from documentation |
| `dracut --force` | **Untested** — written from documentation |

Developed against Omarchy 4.0.4, Plymouth 26.134.222, on an AMD GPU with
`amdgpu`. If you run one of the untested paths, please report what happened.

## Known limitations

- There is a black gap between Plymouth exiting and the desktop appearing. That
  is a DRM handover blank and is outside this project; it is not caused by the
  fill.
- The SDDM greeter is not retinted. `omarchy-plymouth-set` retints it alongside
  Plymouth; this project deliberately does not.

## Tests

```bash
bash test/all
```

Pure logic only — no root and no Plymouth required.
````

- [ ] **Step 2: Run the full suite one final time**

Run: `bash test/all`
Expected: PASS — `all test files passed`.

- [ ] **Step 3: Install on the machine**

Run: `./install.sh`
Expected: prompts to remove the legacy installation, answers `y`, restores the stock theme, stages, sets `omarchy-vfill` as default, rebuilds the initramfs.

- [ ] **Step 4: Verify the installed theme before rebooting**

Run:

```bash
plymouth-set-default-theme
ls /usr/share/plymouth/themes/omarchy-vfill/
cat /usr/share/plymouth/themes/omarchy-vfill/.vfill-marker
grep -m1 '^Window.SetBackgroundTopColor' /usr/share/plymouth/themes/omarchy-vfill/omarchy-vfill.script
```

Expected: `omarchy-vfill`; the six files plus the marker; a marker whose
background matches the active theme; a background line carrying that theme's
colour as floats.

- [ ] **Step 5: Load the script under plymouthd**

Run:

```bash
sudo plymouthd --no-daemon --debug --debug-file=/tmp/vfill-check.log \
  --mode=boot --tty=tty6 --no-boot-log &
sleep 2 && sudo plymouth show-splash && sleep 2 && sudo plymouth quit
sleep 1
grep -iE 'error|invalid|unexpected|syntax' /tmp/vfill-check.log |
  grep -viE '/run/plymouth|plymouthd.defaults|bgrt|card0|could not (query|find|open)|Could not initialize heads'
```

Expected: no output from the final grep. The daemon buffers its log, so it is
read after the daemon exits.

- [ ] **Step 6: Verify the hook is silent when nothing changed**

Run: `bash ~/.config/omarchy/hooks/theme-set.d/omarchy-vfill.sh; echo "exit=$?"`
Expected: `exit=0`, no output, no authentication prompt — the theme was just
installed from the active theme, so the marker already matches.

- [ ] **Step 7: Reboot and confirm**

Expected: the logo fills from the bottom up after the disk password, reaching
full before handing off.

- [ ] **Step 8: Commit**

```bash
git add README.md
git commit -m "Add README"
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
| --- | --- |
| Theme installed under its own name | 4, 5 |
| Vendored PR script, not a patch | 4 |
| `fake_progress_duration` stays 15.0 | Constraint; Task 4 Step 1 verifies no edit |
| `install.sh` idempotent | 6 |
| `uninstall.sh` restores stock | 6 |
| `bin/omarchy-vfill-retheme` | 5 |
| `hooks/theme-set.sh` | 5 |
| Marker with bg/fg/logo/hash | 2 |
| Anchored colour match | 1 |
| Recolour entry/lock/bullet | 4 |
| Logo: unlock.png else logo.svg | 2, 4 |
| Background as floats | 1, 4 |
| Logo size read from image | Inherent to the vendored script; verified in Task 4 Step 1 |
| Initramfs detection, 3 branches | 3 |
| Untested paths labelled | 7 |
| Privilege: sudo with TTY, else pkexec | 5, 6 |
| Migration from hook-patch | 6 |
| Testing: render, load, retheme, reboot, uninstall | 4, 7 |
| Out of scope: black gap, SDDM | 7 (README) |

**Placeholder scan:** no TBD/TODO; every step carries runnable content.

**Type consistency:** `vfill_read_color`, `vfill_hex_to_floats`, `vfill_resolve_logo`, `vfill_write_marker`, `vfill_logo_hash`, `vfill_marker_matches`, `vfill_initramfs_command`, `vfill_stage_theme` are used with identical names and argument orders in every task that references them.

**Gap found and closed:** the spec's offline-render test is subsumed by Task 4's staging test, which asserts on the actual recoloured output rather than a throwaway composite. The reboot check remains in Task 7.

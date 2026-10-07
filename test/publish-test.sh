#!/bin/bash

# Exercises the privileged (non --check) path of bin/omarchy-vfill-retheme
# without any real privilege. The script runs inside an unprivileged user
# namespace (`unshare -r`), where EUID is 0 but maps back to the invoking user:
# it can write only what that user can already write. Every destination is a
# scratch directory (VFILL_THEME_DEST, VFILL_LOCK_FILE), and every command that
# would touch the real system -- plymouth-set-default-theme and the initramfs
# tool -- is a stub first on PATH that records its arguments and exits. sudo and
# pkexec are stubbed to fail loudly in case anything ever reaches for them.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

RETHEME="$ROOT/bin/omarchy-vfill-retheme"

command -v magick >/dev/null || fail "magick is available"
command -v unshare >/dev/null || fail "unshare is available"
unshare -r true 2>/dev/null || fail "unprivileged user namespaces are available"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

theme_dir="$scratch/theme"
omarchy_path="$scratch/omarchy"
stubs="$scratch/stubs"
log="$scratch/stub.log"
mkdir -p "$theme_dir" "$omarchy_path/default/plymouth" "$stubs"

cat >"$theme_dir/colors.toml" <<'EOF'
background = "#140F1F"
foreground = "#DFEDE5"
EOF
magick -size 40x10 xc:white -alpha set "$theme_dir/unlock.png"
for asset in entry.png lock.png bullet.png; do
  magick -size 8x8 xc:white -alpha set "$omarchy_path/default/plymouth/$asset"
done

# Each stub records its name and arguments, then exits with the status held
# in STUB_<NAME>_EXIT (default 0).
make_stub() {
  local name="$1" var="$2"
  cat >"$stubs/$name" <<EOF
#!/bin/bash
printf '%s %s\n' "$name" "\$*" >>"$log"
exit "\${$var:-0}"
EOF
  chmod +x "$stubs/$name"
}
make_stub plymouth-set-default-theme STUB_SETDEFAULT_EXIT
make_stub limine-mkinitcpio STUB_REBUILD_EXIT
for forbidden in sudo pkexec; do
  printf '#!/bin/bash\necho "%s must never run in tests" >&2\nexit 99\n' "$forbidden" >"$stubs/$forbidden"
  chmod +x "$stubs/$forbidden"
done

# Run the retheme script as namespace-root against a scratch destination.
run_retheme() {
  local dest="$1"
  shift
  env -u PKEXEC_UID -u SUDO_UID -u SUDO_USER \
    PATH="$stubs:$PATH" HOME="$scratch/home" \
    OMARCHY_PATH="$omarchy_path" \
    VFILL_THEME_DEST="$dest" VFILL_LOCK_FILE="$scratch/lock" \
    unshare -r "$RETHEME" --theme-dir "$theme_dir" "$@"
}

check() {
  VFILL_THEME_DEST="$1" OMARCHY_PATH="$omarchy_path" \
    "$RETHEME" --check --theme-dir "$theme_dir"
}

stub_calls() {
  [[ -f $log ]] && cat "$log"
}

# --- A successful run publishes, then --check reports current. -------------

dest="$scratch/dest-success"
: >"$log"
run_retheme "$dest" >/dev/null 2>&1
assert_equals "0" "$?" "a successful run exits 0"

[[ -f $dest/.vfill-marker && -f $dest/logo.png && -f $dest/omarchy-vfill.script ]] ||
  fail "a successful run publishes the theme and its marker" "$(ls -A "$dest" 2>&1)"
pass "a successful run publishes the theme and its marker"

assert_equals "plymouth-set-default-theme omarchy-vfill
limine-mkinitcpio " "$(stub_calls)" "a successful run sets the default, then rebuilds"

check "$dest"
assert_equals "3" "$?" "--check reports current (exit 3) right after a successful run"

assert_equals "$(sha256sum <"$dest/logo.png" | cut -d' ' -f1)" \
  "$(sed -nE 's/^logo_sha256=(.*)$/\1/p' "$dest/.vfill-marker")" \
  "the marker hashes the published logo bytes"

# The theme's own unlock.png is published as-is -- and, since root reads it once
# into a verified copy and stages, publishes and hashes that copy rather than
# re-reading the path, those bytes are the ones that were checked.
cmp -s "$theme_dir/unlock.png" "$dest/logo.png" ||
  fail "the published logo is byte-for-byte the theme's unlock.png"
pass "the published logo is byte-for-byte the theme's unlock.png"

# --- A matching marker short-circuits; --force restages anyway. ------------

: >"$log"
output=$(run_retheme "$dest" 2>&1)
assert_equals "0" "$?" "a run against a matching marker exits 0"
[[ $output == *"already current"* ]] || fail "a run against a matching marker says already current" "$output"
pass "a run against a matching marker says already current"
assert_equals "" "$(stub_calls)" "a run against a matching marker rebuilds nothing"

: >"$log"
touch -d '2000-01-01' "$dest/omarchy-vfill.script"
run_retheme "$dest" --force >/dev/null 2>&1
assert_equals "0" "$?" "--force against a matching marker exits 0"
assert_equals "plymouth-set-default-theme omarchy-vfill
limine-mkinitcpio " "$(stub_calls)" "--force restages and rebuilds despite a matching marker"
[[ $(stat -c %Y "$dest/omarchy-vfill.script") -gt 946684800 ]] ||
  fail "--force republishes the theme files"
pass "--force republishes the theme files"
check "$dest"
assert_equals "3" "$?" "--check reports current (exit 3) after a --force run"

# --check and --force together are rejected: --force only applies to a real run.
check_force=$(VFILL_THEME_DEST="$dest" "$RETHEME" --check --force --theme-dir "$theme_dir" 2>&1)
assert_equals "2" "$?" "--check --force is rejected as a usage error"

# --- A failing rebuild leaves no matching marker. -------------------------

: >"$log"
STUB_REBUILD_EXIT=1 run_retheme "$dest" --force >/dev/null 2>&1
[[ $? -ne 0 ]] || fail "a failing rebuild exits non-zero"
pass "a failing rebuild exits non-zero"
[[ ! -e $dest/.vfill-marker ]] || fail "a failing rebuild leaves no marker (the previous one is gone too)"
pass "a failing rebuild leaves no marker (the previous one is gone too)"
check "$dest"
assert_equals "0" "$?" "--check asks for a retheme after a failing rebuild"

dest_fresh="$scratch/dest-fresh-rebuild-fail"
STUB_REBUILD_EXIT=1 run_retheme "$dest_fresh" >/dev/null 2>&1
[[ ! -e $dest_fresh/.vfill-marker ]] || fail "a failing rebuild on a first install leaves no marker"
pass "a failing rebuild on a first install leaves no marker"

# --- A failing plymouth-set-default-theme leaves no marker either. --------

run_retheme "$dest" >/dev/null 2>&1 || fail "recovery run after a failed rebuild succeeds"
[[ -f $dest/.vfill-marker ]] || fail "recovery run restores the marker"
pass "a later successful run restores the marker"

: >"$log"
STUB_SETDEFAULT_EXIT=1 run_retheme "$dest" --force >/dev/null 2>&1
[[ $? -ne 0 ]] || fail "a failing set-default exits non-zero"
pass "a failing set-default exits non-zero"
[[ ! -e $dest/.vfill-marker ]] || fail "a failing set-default leaves no marker"
pass "a failing set-default leaves no marker"
[[ $(stub_calls) != *limine-mkinitcpio* ]] || fail "a failing set-default does not rebuild"
pass "a failing set-default does not rebuild"

# --- No stray staging directories are left beside the destination. -------

strays=$(find "$scratch" -maxdepth 1 -name 'dest-*.new.*' -o -maxdepth 1 -name 'dest-*.old.*')
assert_equals "" "$strays" "no .new/.old directories are left behind"

# --- Privileged runs serialise on the lock. -------------------------------

dest_lock="$scratch/dest-lock"
: >"$log"
exec {held}>>"$scratch/lock"
flock "$held" || fail "the test can take the lock"
# The waiting run must not inherit the test's descriptor: flock locks belong
# to the open file description, so an inherited copy would keep the lock held
# after the test closes its own.
run_retheme "$dest_lock" >/dev/null 2>&1 {held}>&- &
waiter=$!
sleep 2
assert_equals "" "$(stub_calls)" "a run waits while another holds the lock"
[[ ! -e $dest_lock ]] || fail "a waiting run publishes nothing"
pass "a waiting run publishes nothing"
exec {held}>&-
wait "$waiter"
assert_equals "0" "$?" "the waiting run completes once the lock is released"
[[ -f $dest_lock/.vfill-marker ]] || fail "the waiting run publishes after the lock is released"
pass "the waiting run publishes after the lock is released"

# --- The bytes published are the bytes that were checked, even when the theme's
#     unlock.png changes underneath. ------------------------------------------
# The retheme opens the theme's unlock.png once, checks the inode it actually
# opened, and stages, publishes and hashes that copy. Nothing re-reads the path
# afterwards -- which is what makes a racing swap after the check harmless, and
# the same reason root never blocks on a path swapped to a FIFO while it holds the
# lock.
#
# The swap is performed by a mktemp stub at the moment the retheme asks for its
# staging directory: after the verified copy, immediately before staging, which is
# exactly where a racing process would strike.

swap_theme="$scratch/theme-swapped"
mkdir -p "$swap_theme"
cp "$theme_dir/colors.toml" "$swap_theme/colors.toml"
magick -size 40x10 xc:white -alpha set "$swap_theme/unlock.png"
original_logo_sha=$(sha256sum "$swap_theme/unlock.png" | cut -d' ' -f1)

swapped="$scratch/swapped-bytes.png"
magick -size 40x10 xc:"#FF0000" -alpha set "$swapped"
swapped_sha=$(sha256sum "$swapped" | cut -d' ' -f1)
[[ $original_logo_sha != "$swapped_sha" ]] ||
  fail "prerequisite: the swapped artwork differs from the original"
pass "prerequisite: the swapped artwork differs from the original"

REAL_MKTEMP=$(command -v mktemp) || fail "mktemp is available"
cat >"$stubs/mktemp" <<STUB
#!/bin/bash
# Stands in for a process racing the retheme: it replaces the theme's artwork at
# the instant the staging directory is created, i.e. after the retheme has taken
# its verified copy.
if [[ "\$*" == *-d* ]]; then
  cp -- "$swapped" "$swap_theme/unlock.png"
fi
exec "$REAL_MKTEMP" "\$@"
STUB
chmod +x "$stubs/mktemp"

dest_swap="$scratch/dest-swapped"
: >"$log"
env -u PKEXEC_UID -u SUDO_UID -u SUDO_USER \
  PATH="$stubs:$PATH" HOME="$scratch/home" OMARCHY_PATH="$omarchy_path" \
  VFILL_THEME_DEST="$dest_swap" VFILL_LOCK_FILE="$scratch/lock" \
  unshare -r "$RETHEME" --theme-dir "$swap_theme" >/dev/null 2>&1
assert_equals "0" "$?" "a run whose artwork is swapped mid-run still succeeds"

assert_equals "$swapped_sha" "$(sha256sum "$swap_theme/unlock.png" | cut -d' ' -f1)" \
  "prerequisite: the swap really happened during the run"
assert_equals "$original_logo_sha" "$(sha256sum "$dest_swap/logo.png" | cut -d' ' -f1)" \
  "the published logo is the bytes that were checked, not the ones swapped in after"
assert_equals "$original_logo_sha" \
  "$(sed -nE 's/^logo_sha256=(.*)$/\1/p' "$dest_swap/.vfill-marker")" \
  "the marker hashes the bytes that were checked, not a fresh read of the path"

rm -f -- "$stubs/mktemp"

# --- A privileged run never hashes the theme's own path. -------------------
# Everything root reads the artwork for -- the marker comparison that decides
# whether to republish, and the marker it writes afterwards -- reads the verified
# copy. Hashing the path instead would be root opening user-controlled content
# (blocking, if it has become a FIFO, while it holds the lock) and would put the
# digest of whatever was swapped in since into a world-readable marker.
#
# A stale marker is in place so the comparison really does reach the hash: with no
# marker at all it returns before hashing anything.
hash_dest="$scratch/dest-hash-source"
mkdir -p "$hash_dest"
vfill_write_marker "$hash_dest/.vfill-marker" "000000" "DFEDE5" \
  "$theme_dir/unlock.png" "DFEDE5"

REAL_SHA256SUM=$(command -v sha256sum) || fail "sha256sum is available"
sha_log="$scratch/sha256sum.log"
: >"$sha_log"
cat >"$stubs/sha256sum" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$sha_log"
exec "$REAL_SHA256SUM" "\$@"
STUB
chmod +x "$stubs/sha256sum"

: >"$log"
env -u PKEXEC_UID -u SUDO_UID -u SUDO_USER \
  PATH="$stubs:$PATH" HOME="$scratch/home" OMARCHY_PATH="$omarchy_path" \
  VFILL_THEME_DEST="$hash_dest" VFILL_LOCK_FILE="$scratch/lock" \
  unshare -r "$RETHEME" --theme-dir "$theme_dir" >/dev/null 2>&1
assert_equals "0" "$?" "a run against a stale marker republishes and succeeds"
rm -f -- "$stubs/sha256sum"

[[ -s $sha_log ]] ||
  fail "prerequisite: the run hashed something, so the assertion below means something"
pass "prerequisite: the run hashed something at all"
grep -qF "$theme_dir/unlock.png" "$sha_log" &&
  fail "a privileged run never hashes the theme's own unlock.png path" "$(cat "$sha_log")"
pass "a privileged run never hashes the theme's own unlock.png path"

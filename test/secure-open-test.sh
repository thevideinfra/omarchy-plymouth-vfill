#!/bin/bash

# Exercises vfill_open_user_file, which root uses to check the opened inode
# (not the path) before publishing a theme-provided logo. Runs entirely
# unprivileged.
#
# vfill_open_user_file prints the descriptor number on success via stdout.
# Capturing it with $(...) or <(...) would run the call in a subshell, and
# the exec {fd}<"$path" inside would open the descriptor in that subshell's
# process, which then exits and closes it -- the caller would be left with a
# stale number that either points at nothing or, worse, has since been
# reused for something unrelated. So this test calls the function as a plain
# foreground command with its stdout redirected to a scratch file (a simple
# redirection does not fork a subshell), then reads the number back. The
# descriptor itself stays open in this same shell process throughout, which
# is what lets the "genuinely readable" assertion below prove something a
# bare exit-code check could not.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

my_uid=$(id -u)

fd_count() {
  find /proc/self/fd -mindepth 1 2>/dev/null | wc -l
}

# Calls vfill_open_user_file without command substitution and leaves the
# opened descriptor's number in CAPTURED_FD, open in this shell.
open_capture() {
  local path="$1" uid="$2" capture_file
  capture_file="$scratch/.fd-capture"
  if vfill_open_user_file "$path" "$uid" >"$capture_file"; then
    CAPTURED_FD=$(<"$capture_file")
    rm -f "$capture_file"
    return 0
  fi
  rm -f "$capture_file"
  return 1
}

# A regular file owned by the current uid opens, and the descriptor is
# genuinely readable in the caller -- not just a zero exit status.
regular="$scratch/regular.txt"
printf 'hello from vfill\n' >"$regular"
before=$(fd_count)
open_capture "$regular" "$my_uid" || fail "a regular file owned by the current uid opens"
pass "a regular file owned by the current uid opens"

content=$(cat <&"$CAPTURED_FD")
assert_equals "hello from vfill" "$content" \
  "the descriptor returned is genuinely readable in the caller's shell"

exec {CAPTURED_FD}<&-
after=$(fd_count)
assert_equals "$before" "$after" "the descriptor is closed once the caller is done with it"

# A symlink to a root-owned, world-readable file is refused: the opened
# inode belongs to root, not to us, regardless of what the path looks like.
[[ -f /etc/hostname ]] || fail "prerequisite: /etc/hostname exists on this system"
link="$scratch/link-to-hostname"
ln -s /etc/hostname "$link"
before=$(fd_count)
open_capture "$link" "$my_uid" &&
  fail "a symlink to a root-owned file is refused"
pass "a symlink to a root-owned file is refused"
after=$(fd_count)
assert_equals "$before" "$after" "a refused symlink leaks no descriptor"

# The same root-owned file, passed directly (no symlink), is refused too.
before=$(fd_count)
open_capture "/etc/hostname" "$my_uid" &&
  fail "a root-owned file passed directly is refused"
pass "a root-owned file passed directly is refused"
after=$(fd_count)
assert_equals "$before" "$after" "a refused direct root-owned file leaks no descriptor"

# A non-existent path is refused.
before=$(fd_count)
open_capture "$scratch/does-not-exist" "$my_uid" &&
  fail "a non-existent path is refused"
pass "a non-existent path is refused"
after=$(fd_count)
assert_equals "$before" "$after" "a refused non-existent path leaks no descriptor"

# A directory is refused: it is not a regular file, even though opening it
# for reading succeeds on Linux.
dir="$scratch/a-directory"
mkdir -p "$dir"
before=$(fd_count)
open_capture "$dir" "$my_uid" &&
  fail "a directory is refused"
pass "a directory is refused"
after=$(fd_count)
assert_equals "$before" "$after" "a refused directory leaks no descriptor"

# --- vfill_copy_user_file: the same check, and no blocking open. ------------
# Root reaches this while it holds /run/lock/omarchy-vfill.lock, so an unlock.png
# swapped to a FIFO must not block it there: `exec {fd}<` on a FIFO waits for a
# writer forever, and bash restarts the open through signals. Every call here goes
# through an OUTER timeout as well, so a regression cannot hang the suite -- and a
# status of 124 from that outer timeout is itself a failure, because it means the
# refusal was the test's doing and not the function's.
copy_under_outer_timeout() {
  local path="$1" uid="$2" dest="$3"
  timeout 15 bash -c '
    source "$1" || exit 1
    VFILL_OPEN_TIMEOUT=2 vfill_copy_user_file "$2" "$3" "$4"
  ' bash "$ROOT/lib/vfill.sh" "$path" "$uid" "$dest" 2>/dev/null
}

copy_dest="$scratch/copied-logo"

copy_under_outer_timeout "$regular" "$my_uid" "$copy_dest"
assert_equals "0" "$?" "a regular file owned by the current uid is copied"
cmp -s "$regular" "$copy_dest" ||
  fail "the copy is byte-for-byte the verified file" "$(cat "$copy_dest")"
pass "the copy is byte-for-byte the verified file"

rm -f "$copy_dest"
copy_under_outer_timeout "$link" "$my_uid" "$copy_dest"
[[ $? -ne 0 ]] || fail "a symlink to a root-owned file is refused for the copy too"
pass "a symlink to a root-owned file is refused for the copy too"
[[ ! -e $copy_dest ]] ||
  fail "a refused copy leaves no destination file behind" "$(ls -l "$copy_dest")"
pass "a refused copy leaves no destination file behind"

rm -f "$copy_dest"
copy_under_outer_timeout "$scratch/does-not-exist" "$my_uid" "$copy_dest"
[[ $? -ne 0 ]] || fail "a non-existent path is refused for the copy too"
pass "a non-existent path is refused for the copy too"

# The one this exists for: a FIFO. It must be refused, the refusal must come from
# the function's own bound rather than the outer timeout, and it must not have
# taken anything like as long as an unbounded open would (which is forever).
fifo="$scratch/unlock-as-a-fifo"
mkfifo "$fifo"
rm -f "$copy_dest"
start=$SECONDS
copy_under_outer_timeout "$fifo" "$my_uid" "$copy_dest"
status=$?
elapsed=$((SECONDS - start))

[[ $status -ne 0 ]] || fail "a FIFO is refused rather than copied"
pass "a FIFO is refused rather than copied"
[[ $status -ne 124 ]] ||
  fail "the FIFO refusal is the function's own bound, not the test's outer timeout" \
    "the call did not return within the outer 15 s: an unbounded open would hold the retheme lock here forever"
pass "the FIFO refusal is the function's own bound, not the test's outer timeout"
((elapsed < 10)) ||
  fail "the FIFO refusal is bounded by VFILL_OPEN_TIMEOUT" "took ${elapsed}s with a 2 s bound"
pass "the FIFO refusal is bounded by VFILL_OPEN_TIMEOUT"
[[ ! -e $copy_dest ]] ||
  fail "a refused FIFO leaves no destination file behind" "$(ls -l "$copy_dest")"
pass "a refused FIFO leaves no destination file behind"

# A directory is refused here too -- opening one for reading succeeds on Linux,
# so only the descriptor's own [[ -f ]] catches it.
rm -f "$copy_dest"
copy_under_outer_timeout "$dir" "$my_uid" "$copy_dest"
[[ $? -ne 0 ]] || fail "a directory is refused for the copy too"
pass "a directory is refused for the copy too"

# A file owned by somebody else is refused even though it is a regular file and
# opens instantly: the uid check is still the one that matters.
rm -f "$copy_dest"
copy_under_outer_timeout /etc/hostname "$my_uid" "$copy_dest"
[[ $? -ne 0 ]] || fail "a root-owned regular file is refused for the copy too"
pass "a root-owned regular file is refused for the copy too"

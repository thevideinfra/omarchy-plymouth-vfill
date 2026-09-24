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

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

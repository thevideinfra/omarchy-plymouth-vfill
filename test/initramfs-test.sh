#!/bin/bash

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
source "$ROOT/lib/vfill.sh"

scratch=$(new_scratch_dir)
trap 'rm -rf -- "$scratch"' EXIT

make_stub() {
  local name="$1"
  printf '#!/bin/bash\nexit 0\n' >"$scratch/bin/$name"
  /bin/chmod +x "$scratch/bin/$name"
}

mkdir -p "$scratch/bin"
real_path="$PATH"

# limine-mkinitcpio wins when present, matching omarchy-plymouth-set.
PATH="$scratch/bin"
make_stub limine-mkinitcpio
make_stub mkinitcpio
assert_equals "limine-mkinitcpio" "$(vfill_initramfs_command)" \
  "limine-mkinitcpio takes precedence"

/bin/rm "$scratch/bin/limine-mkinitcpio"
assert_equals "mkinitcpio -P" "$(vfill_initramfs_command)" \
  "mkinitcpio -P is used when limine-mkinitcpio is absent"

/bin/rm "$scratch/bin/mkinitcpio"
make_stub dracut
assert_equals "dracut --force" "$(vfill_initramfs_command)" \
  "dracut is the last resort"

/bin/rm "$scratch/bin/dracut"
vfill_initramfs_command >/dev/null 2>&1 &&
  fail "no known initramfs tool returns non-zero"
pass "no known initramfs tool returns non-zero"

PATH="$real_path"

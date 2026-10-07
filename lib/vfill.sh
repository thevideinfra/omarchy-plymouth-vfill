#!/bin/bash

# Shared helpers for omarchy-plymouth-vfill. Sourced by the install, uninstall
# and retheme entry points, and exercised directly by the tests. Everything here
# is pure: it reads what it is given and prints a result, so the logic can be
# tested without root and without touching a real Plymouth theme.

# The one bound root's reads of user-controlled paths run under, and the one
# mechanism that applies it.
#
# Why a bound at all. open(2) on a FIFO with no writer blocks until a writer
# arrives, which may be never, and bash has no redirection that opens with
# O_NONBLOCK. The privileged retheme reads the theme while it holds
# /run/lock/omarchy-vfill.lock, so a path swapped to a FIFO in the window after
# an [[ -f ]] test wedged root there: every later retheme and the whole of
# uninstall.sh's privileged transaction then waited on a lock nobody would ever
# release. Running the reader in a child under timeout turns that wedge into a
# bounded refusal.
#
# A missing timeout(1) is a refusal, not a licence to read unbounded: reading
# unbounded is the thing this exists to prevent.
#
# VFILL_OPEN_TIMEOUT is overridable only so the tests need not wait out the real
# bound, exactly like VFILL_LOCK_FILE in bin/omarchy-vfill-retheme: it is read
# inside the already-elevated process, where sudo's env_reset and pkexec have
# dropped it. It is validated before it reaches timeout's argv, so a value that
# is not a plain number of seconds falls back rather than making the bound
# whatever it says. 20 s is the -limit time the magick calls already use.
#
# -k 1: TERM is enough for a process blocked in open(2), but a reader that
# ignores it must still go.
#
# $1 names the path for the refusal message; everything after it is the command.
vfill_run_bounded() {
  local what="$1"
  shift
  local secs

  command -v timeout >/dev/null || {
    printf 'vfill: timeout(1) is not available, so %s cannot be read under a bound; refusing\n' \
      "$what" >&2
    return 1
  }

  secs=${VFILL_OPEN_TIMEOUT:-20}
  [[ $secs =~ ^[1-9][0-9]*$ ]] || secs=20

  timeout -k 1 "$secs" "$@"
}

# Read a colour key out of an Omarchy colors.toml. The match is anchored so
# dark_background and lighter_background cannot satisfy a lookup for background.
#
# Root runs this six times per retheme -- three in bin/omarchy-vfill-retheme,
# three more inside vfill_stage_theme -- after the lock is taken, on a path the
# user controls. sed's open of a FIFO with no writer never returns, so the read
# goes through vfill_run_bounded, the same bound vfill_copy_user_file puts around
# the logo open.
#
# The pre-check is -e and deliberately NOT -f. A regular-file test here would be
# a TOCTOU check that defends nothing -- the file can become a FIFO in the window
# between the test and sed's open -- while making the FIFO case look handled
# instead of bounded. The bound is what defends; -e survives only so a theme with
# no colors.toml at all returns quietly. A colors.toml that exists but is a
# directory, a device node or anything else sed cannot read now fails through
# sed's stderr instead of silently, which -f used to swallow.
#
# What this costs, stated honestly. The bound is per read, not per run, and a
# FIFO fed by a cooperating writer can let every read SUCCEED just inside the
# bound rather than fail: six colour reads plus the logo open then hold
# /run/lock/omarchy-vfill.lock for close to seven times the bound -- about 140 s
# at the 20 s default -- blocking every later retheme and the whole of
# uninstall.sh's privileged transaction, repeatably, and in mode auto without a
# password. That is an availability cost against the user's own theme directory
# by a process already running as them, and it replaces a hold that was
# unbounded, so it is accepted rather than fixed. Capping the whole read phase,
# or reading colors.toml once through a single bounded child and parsing the
# copy, is what would close it.
#
# A bound is the whole requirement here, and there is deliberately no inode
# ownership check: root legitimately reads a colors.toml it does not own, nothing
# read is ever published, and what is returned is already constrained to six hex
# digits by the expression below.
vfill_read_color() {
  local toml="$1" key="$2" value

  [[ -e $toml ]] || return 1

  value=$(vfill_run_bounded "$toml" \
    sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?#?([0-9a-fA-F]{6})\"?[[:space:]]*\$/\\1/p" \
    "$toml" | head -1)

  [[ -n $value ]] || return 1
  printf '%s\n' "$value"
}

# The fallback logo.svg (Omarchy's own, used when a theme ships no unlock.png)
# is recoloured to the theme's accent, so it stands out rather than blending
# into the foreground-tinted prompt furniture; a theme with no accent falls
# back to foreground. A theme's own unlock.png is already coloured and is
# never touched by this.
vfill_logo_color() {
  local toml="$1"

  vfill_read_color "$toml" accent || vfill_read_color "$toml" foreground
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

# Resource limits for every magick invocation. magick renders the prompt
# furniture and the logo.svg fallback, and a pathological SVG must not be able
# to exhaust the machine -- especially since the retheme runs as root. Declared
# once and reused, so the call sites below cannot drift apart.
#
# Declared unconditionally, and deliberately not under a [[ -z ${VAR+x} ]]
# guard: that guard is satisfied by a plain environment variable, and bash never
# builds an array out of the environment, so VFILL_MAGICK_LIMITS=BOGUS removed
# every limit and injected a stray argv word into each call. Not readonly, so
# sourcing this file twice is still harmless.
declare -a VFILL_MAGICK_LIMITS=(
  -limit memory 128MiB
  -limit map 256MiB
  -limit disk 256MiB
  -limit width 4096
  -limit height 4096
  -limit time 20
)

# The largest theme-supplied unlock.png worth using. Real ones are a few tens of
# kilobytes; anything past this is either a mistake or an attempt to make the
# boot splash rebuild expensive, and the bundled fallback logo is a better
# answer than a failed install.
#
# Also assigned unconditionally, for the same reason and one more: this value
# reaches an arithmetic context, where VFILL_MAX_UNLOCK_BYTES='x[$(cmd)]' from
# the environment would have run a command substitution.
VFILL_MAX_UNLOCK_BYTES=$((8 * 1024 * 1024))

# Width the logo.svg fallback is rendered at; matches the stock themes' unlock.png width.
VFILL_FALLBACK_LOGO_WIDTH=800

# Render a byte count the way the size limit is written in a message, so the
# message cannot drift from the bound it is reporting.
vfill_format_bytes() {
  local bytes="$1"

  if ((bytes >= 1024 * 1024)) && ((bytes % (1024 * 1024) == 0)); then
    printf '%s MiB\n' "$((bytes / 1024 / 1024))"
  else
    printf '%s bytes\n' "$bytes"
  fi
}

# Prefer the active theme's own artwork. Themes are not required to ship
# unlock.png (aurora, dracula and texas-longhorns do not), so fall back to
# Omarchy's logo.svg, which is greyscale plus alpha and recolours cleanly.
#
# An unlock.png over the size bound is skipped rather than fatal: the fallback
# logo still gives the user a working splash. The size is read with stat -L,
# matching the symlink-following [[ -f ]] test above it and the read that
# eventually happens, so a symlink cannot hide the real size. This is a resource
# cap, not a trust boundary -- a racing swap after this check is still caught by
# the descriptor ownership check in vfill_open_user_file, which this deliberately
# leaves alone.
#
# The cap fails CLOSED: a file whose size cannot be read takes the fallback too.
# Treating an unstattable unlock.png as "within the limit" skipped the only
# check there was and used it anyway.
vfill_resolve_logo() {
  local theme_dir="$1" omarchy_path="$2" size bound

  # A bound that is not a plain decimal byte count never reaches (( )), where
  # 'x[$(cmd)]' would run a command substitution.
  #
  # Unset is not the same as wrong. This file sets the bound at source time, so
  # an unset one means a caller unset it, not that anyone supplied nonsense --
  # and complaining about a value nobody gave sent the user looking for a
  # variable they had never heard of. Only a value that is actually there, and
  # is not a byte count, is worth a word.
  if [[ -z ${VFILL_MAX_UNLOCK_BYTES+set} ]]; then
    bound=$((8 * 1024 * 1024))
  else
    bound=$VFILL_MAX_UNLOCK_BYTES
    if [[ ! $bound =~ ^[0-9]+$ ]]; then
      printf 'vfill: ignoring a VFILL_MAX_UNLOCK_BYTES that is not a byte count; using %s\n' \
        "$(vfill_format_bytes $((8 * 1024 * 1024)))" >&2
      bound=$((8 * 1024 * 1024))
    fi
  fi

  if [[ -f $theme_dir/unlock.png ]]; then
    size=$(stat -L -c %s "$theme_dir/unlock.png" 2>/dev/null) || size=""
    if [[ ! $size =~ ^[0-9]+$ ]]; then
      printf 'vfill: ignoring %s: cannot read its size; using the fallback logo instead\n' \
        "$theme_dir/unlock.png" >&2
    elif ((size > bound)); then
      printf 'vfill: ignoring %s: %s bytes exceeds the %s limit for a theme logo; using the fallback logo instead\n' \
        "$theme_dir/unlock.png" "$size" "$(vfill_format_bytes "$bound")" >&2
    else
      printf '%s\n' "$theme_dir/unlock.png"
      return 0
    fi
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
#
# The optional sixth argument is the file whose bytes are hashed, when that is
# not the logo path itself. A privileged caller passes the copy it published
# from a verified descriptor, so root never hashes a user-controlled path (a
# racing swap could otherwise put the hash of a root-only file into this 0644
# file). For an unlock.png the published copy is byte-identical to the source,
# so --check, which hashes the source path, still sees a match.
vfill_write_marker() {
  local marker="$1" background="$2" foreground="$3" logo="$4" logo_color="$5" hash_from="${6:-$4}"
  local hash

  hash=$(vfill_logo_hash "$hash_from") || return 1

  cat >"$marker" <<EOF
background=$background
foreground=$foreground
logo_source=$logo
logo_color=$logo_color
logo_sha256=$hash
EOF
}

vfill_logo_hash() {
  local logo="$1"

  [[ -f $logo ]] || return 1
  sha256sum "$logo" | cut -d' ' -f1
}

# Hash the logo as well as its path: re-theming can leave the path identical
# while replacing the artwork underneath it.
#
# The optional sixth argument is the file whose bytes are hashed, the same shape
# as vfill_write_marker's. A privileged caller passes the verified copy it took of
# the theme's unlock.png: hashing the path instead would have root open
# user-controlled content, which is a blocking open on a FIFO while it holds the
# retheme lock, and a hash of whatever was swapped in since the check. The copy is
# byte-identical to the source, so an unprivileged --check hashing the path still
# agrees with the marker a privileged run wrote.
vfill_marker_matches() {
  local marker="$1" background="$2" foreground="$3" logo="$4" logo_color="$5"
  local hash_from="${6:-$4}"
  local want_hash

  [[ -f $marker ]] || return 1
  want_hash=$(vfill_logo_hash "$hash_from") || return 1

  local have_background have_foreground have_logo have_logo_color have_hash
  have_background=$(sed -nE 's/^background=(.*)$/\1/p' "$marker")
  have_foreground=$(sed -nE 's/^foreground=(.*)$/\1/p' "$marker")
  have_logo=$(sed -nE 's/^logo_source=(.*)$/\1/p' "$marker")
  have_logo_color=$(sed -nE 's/^logo_color=(.*)$/\1/p' "$marker")
  have_hash=$(sed -nE 's/^logo_sha256=(.*)$/\1/p' "$marker")

  [[ $have_background == "$background" ]] || return 1
  [[ $have_foreground == "$foreground" ]] || return 1
  [[ $have_logo == "$logo" ]] || return 1
  [[ $have_logo_color == "$logo_color" ]] || return 1
  [[ $have_hash == "$want_hash" ]] || return 1

  return 0
}

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

# Build a complete, recoloured theme in dest_dir. Kept free of root operations
# so the tests can stage into a scratch directory; callers that need to publish
# into /usr/share do the privileged copy themselves.
#
# The optional fifth argument is an already-resolved logo path. Pass it when
# the caller has already resolved (and, for a privileged caller, verified) the
# logo once: resolving it again here would create a TOCTOU window, since a
# racing process could swap in an unlock.png between the caller's resolution
# and this function's own lookup. When omitted, this resolves the logo itself,
# exactly as before.
#
# The optional sixth argument is the file the logo's BYTES are read from, when
# that is not the logo path itself. A privileged caller passes the verified copy
# it took: the fifth argument still names the logo, so the marker records the real
# source and the .svg fallback is still recognised by name, but root never opens
# the user's path again -- not to copy it, and not to hash it for the marker.
vfill_stage_theme() {
  local repo="$1" dest="$2" theme_dir="$3" omarchy_path="$4" logo_override="${5:-}"
  local logo_content="${6:-}"
  local background foreground logo_color logo floats

  background=$(vfill_read_color "$theme_dir/colors.toml" background) || return 1
  foreground=$(vfill_read_color "$theme_dir/colors.toml" foreground) || return 1
  logo_color=$(vfill_logo_color "$theme_dir/colors.toml") || return 1
  if [[ -n $logo_override ]]; then
    logo="$logo_override"
  else
    logo=$(vfill_resolve_logo "$theme_dir" "$omarchy_path") || return 1
  fi
  [[ -n $logo_content ]] || logo_content="$logo"
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
    magick "${VFILL_MAGICK_LIMITS[@]}" "$dest/$asset" -channel RGB +level-colors "#$foreground","#$foreground" "$dest/$asset" || return 1
  done

  # A theme's own unlock.png is already coloured and is used as-is. The
  # greyscale logo.svg fallback is rendered and flattened to the theme's
  # accent colour, or the foreground when the theme has no accent.
  if [[ $logo == *.svg ]]; then
    magick "${VFILL_MAGICK_LIMITS[@]}" -background none "$logo_content" -resize "${VFILL_FALLBACK_LOGO_WIDTH}x" "$dest/logo.png" || return 1
    magick "${VFILL_MAGICK_LIMITS[@]}" "$dest/logo.png" -channel RGB +level-colors "#$logo_color","#$logo_color" "$dest/logo.png" || return 1
  else
    install -m 0644 "$logo_content" "$dest/logo.png" || return 1
  fi

  vfill_write_marker "$dest/.vfill-marker" "$background" "$foreground" "$logo" "$logo_color" "$logo_content" || return 1
}

# Open a file for reading and confirm the inode actually opened is a regular file
# owned by the expected user. Checks the descriptor, not the path, so a symlink or
# a file swapped after the path was inspected cannot redirect the read to
# something the user does not own. On success prints the descriptor number, which
# stays open in the calling shell; the caller reads from it and closes it.
vfill_open_user_file() {
  local path="$1" uid="$2" fd owner

  # A bare `exec redirection` (no command word) applies all its redirections
  # to the current shell for good, not just for this statement -- so a plain
  # `exec {fd}<"$path" 2>/dev/null` would, whenever the open SUCCEEDS, leave
  # this shell's stderr permanently pointed at /dev/null. (When the open
  # fails, bash reports the error and applies neither redirection.) Grouping
  # scopes the 2>/dev/null to just this open attempt; the fd it allocates
  # still persists in the calling shell afterward, same as a bare exec would.
  { exec {fd}<"$path"; } 2>/dev/null || return 1

  if [[ ! -f /proc/self/fd/$fd ]]; then
    exec {fd}<&-
    return 1
  fi

  owner=$(stat -L -c %u "/proc/self/fd/$fd" 2>/dev/null) || {
    exec {fd}<&-
    return 1
  }

  if [[ $owner != "$uid" ]]; then
    exec {fd}<&-
    return 1
  fi

  printf '%s\n' "$fd"
}

# Where mode auto's polkit rule lives, and the one name it ever has. The default
# is the only directory a real run writes to or removes from;
# VFILL_POLKIT_RULES_DIR exists so the tests can replay the privileged
# transaction against a scratch directory instead of /etc/polkit-1/rules.d.
#
# This is NOT the VFILL_THEME_DEST situation. That one is read by
# bin/omarchy-vfill-retheme inside the already-elevated process, where sudo's
# env_reset and pkexec have long since dropped it. This one is read by the
# UNPRIVILEGED half of install.sh and uninstall.sh and then handed into the root
# transaction as an argv word, which smuggles it straight past that scrubbing. So
# honouring it unconditionally let the environment choose where root writes a
# drop-in, and what uninstall removes: VFILL_POLKIT_RULES_DIR=/etc/sudoers.d had
# root install a file there, and one line in a shell profile made ./uninstall.sh
# leave passwordless root behind.
#
# The gate is the same shape as VFILL_RETHEME's in bin/omarchy-vfill-reboot, and
# carries the same lesson: a marker variable on its own gates nothing, because
# the environment supplies both the marker and the value it guards. What makes
# this safe is the second half -- even with VFILL_TEST_POLKIT_RULES_DIR=1 set,
# the value has to canonicalise to somewhere under /tmp, /var/tmp or /dev/shm,
# where no polkit, sudo or systemd drop-in is ever read from. Canonicalising
# first is what stops /tmp/../etc/sudoers.d from passing.
#
# Anything else is refused outright rather than quietly ignored: an install that
# stops and says why is easier to understand than one that writes somewhere the
# operator never asked for. Callers that must not abort -- uninstall.sh, which
# would otherwise strand passwordless root -- fall back to the default instead.
#
# A value that does not exist yet is accepted, deliberately: install.sh's "this
# polkit has no rules.d" refusal has to be reachable from the tests, and a
# missing directory under a scratch prefix is how they reach it.
#
# The scratch prefix is checked exactly once, here, in the unprivileged half, so
# a component of the path it returns can still be swapped before root writes
# through it -- this gate bounds which directories an operator can ask for, not
# what the inode is at write time. That residual is accepted: reaching it needs
# VFILL_TEST_POLKIT_RULES_DIR set as well, the write is destructive-only, and the
# rule's bytes are cmp-pinned before root is asked to install them.
VFILL_POLKIT_RULES_DIR_DEFAULT=/etc/polkit-1/rules.d
VFILL_POLKIT_RULE_NAME=49-omarchy-vfill.rules

vfill_polkit_rules_dir() {
  local requested=${VFILL_POLKIT_RULES_DIR:-} canonical prefix
  local default=$VFILL_POLKIT_RULES_DIR_DEFAULT

  if [[ -z $requested || $requested == "$default" ]]; then
    printf '%s\n' "$default"
    return 0
  fi

  if [[ ${VFILL_TEST_POLKIT_RULES_DIR:-} != 1 ]]; then
    printf 'vfill: refusing VFILL_POLKIT_RULES_DIR=%s: mode auto'"'"'s polkit rule only ever goes in %s\n' \
      "$requested" "$default" >&2
    return 1
  fi

  # -m, not -f: the path is allowed not to exist yet.
  canonical=$(readlink -m -- "$requested" 2>/dev/null) || canonical=""
  if [[ -n $canonical ]]; then
    for prefix in /tmp /var/tmp /dev/shm; do
      if [[ $canonical == "$prefix"/* ]]; then
        printf '%s\n' "$canonical"
        return 0
      fi
    done
  fi

  printf 'vfill: refusing VFILL_POLKIT_RULES_DIR=%s: even with VFILL_TEST_POLKIT_RULES_DIR set it may only name a scratch directory under /tmp, /var/tmp or /dev/shm\n' \
    "$requested" >&2
  return 1
}

# Copy a file the invoking user owns into $dest, reading only from a descriptor
# whose inode has been checked, and without letting a file that is not a regular
# file block root while it holds the retheme lock.
#
# Why a child process. Bash has no redirection that opens with O_NONBLOCK, so
# `exec {fd}<"$path"` on a FIFO blocks in open(2) for as long as there is no
# writer -- and a signal does not break it out, bash just restarts the open
# (measured, not assumed). `exec {fd}<>"$path"` does not block, but O_RDWR brings
# O_CREAT with it: on a dangling symlink root would create the target --
# /etc/nologin, say -- and it would leave root holding a write descriptor on
# user-controlled content. So the open runs in a child, under the shared bound in
# vfill_run_bounded, which turns a wedge into a bounded refusal; that function
# has the rest of the reasoning and owns VFILL_OPEN_TIMEOUT.
#
# The child holds the descriptor, so the bytes reach the caller as $dest rather
# than as a descriptor number -- which keeps the property the descriptor was for:
# what lands in $dest is what was read from the checked inode, never a fresh read
# of a path that could have been swapped since. The check itself is
# vfill_open_user_file, unchanged, called as a plain foreground command inside the
# child because command substitution would open the descriptor in a subshell that
# then exits and closes it.
#
# $dest is removed when this returns non-zero, so a caller cannot mistake a
# truncated or empty file for a verified copy.
vfill_copy_user_file() {
  local path="$1" uid="$2" dest="$3"
  local lib fd_capture status

  lib=${BASH_SOURCE[0]}
  [[ -f $lib ]] || return 1

  fd_capture=$(mktemp) || return 1

  vfill_run_bounded "$path" bash -c '
    set -uo pipefail
    source "$1" || exit 1
    vfill_open_user_file "$2" "$3" >"$4" || exit 1
    fd=$(<"$4")
    cat <&"$fd"
  ' bash "$lib" "$path" "$uid" "$fd_capture" >"$dest"
  status=$?

  rm -f -- "$fd_capture"

  if ((status != 0)); then
    rm -f -- "$dest"
    return 1
  fi

  return 0
}

# Render the theme-set hook, pointing it at the installed root-owned retheme
# script. Refuses a relative path: the hook runs from the user's session, where
# the working directory is arbitrary.
vfill_render_hook() {
  local template="$1" retheme="$2"

  [[ $retheme == /* ]] || return 1
  [[ -f $template ]] || return 1

  sed "s#__RETHEME_PATH__#$retheme#" "$template"
}

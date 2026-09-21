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
#
# The optional fifth argument is the file whose bytes are hashed, when that is
# not the logo path itself. A privileged caller passes the copy it published
# from a verified descriptor, so root never hashes a user-controlled path (a
# racing swap could otherwise put the hash of a root-only file into this 0644
# file). For an unlock.png the published copy is byte-identical to the source,
# so --check, which hashes the source path, still sees a match.
vfill_write_marker() {
  local marker="$1" background="$2" foreground="$3" logo="$4" hash_from="${5:-$4}"
  local hash

  hash=$(vfill_logo_hash "$hash_from") || return 1

  cat >"$marker" <<EOF
background=$background
foreground=$foreground
logo_source=$logo
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
vfill_stage_theme() {
  local repo="$1" dest="$2" theme_dir="$3" omarchy_path="$4" logo_override="${5:-}"
  local background foreground logo floats

  background=$(vfill_read_color "$theme_dir/colors.toml" background) || return 1
  foreground=$(vfill_read_color "$theme_dir/colors.toml" foreground) || return 1
  if [[ -n $logo_override ]]; then
    logo="$logo_override"
  else
    logo=$(vfill_resolve_logo "$theme_dir" "$omarchy_path") || return 1
  fi
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

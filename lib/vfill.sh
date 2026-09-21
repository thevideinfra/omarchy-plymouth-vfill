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

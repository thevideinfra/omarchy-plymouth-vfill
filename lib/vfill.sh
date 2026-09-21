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

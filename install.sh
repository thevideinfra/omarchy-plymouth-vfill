#!/bin/bash

# Install the omarchy-vfill Plymouth theme.
#
# Everything root executes or sources is copied root-owned into
# /usr/local/lib/omarchy-vfill/ in one privileged transaction; the checkout
# under $HOME is only ever the installation source, never something root runs
# or sources directly. See ruling-6-root-owned-install.md.
#
# Idempotent: re-running reinstalls from the current source and republishes the
# theme with --force, so updated theme files take effect even when the colours
# and logo have not changed.
#
# How the splash keeps up with the desktop theme is the user's choice, made
# here and recorded in $PREFIX/mode so the operator can see which mode is
# active. Nothing reads that file: a re-install settles every mode's artefacts
# whichever way it went, and the uninstaller removes all of them
# unconditionally, so a mode file lost or never written changes nothing:
#
#   theme-set  a theme-set hook updates it when the colours change
#   reboot     the "Plymouth vfill reboot" action updates it
#   manual     nothing does; the user runs the retheme command
#   auto       the same hook as theme-set, plus a polkit rule that lets it
#              elevate that one root-owned program without a password
#
# Whichever mode is chosen, this always works:
#   sudo /usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme --force

set -uo pipefail

if ((EUID == 0)); then
  echo "install: run as your normal user, not as root" >&2
  exit 1
fi

REPO=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
HOOK_DIR="$HOME/.config/omarchy/hooks/theme-set.d"
HOOK_DEST="$HOOK_DIR/omarchy-vfill.sh"
LEGACY_DIR="$HOME/.config/omarchy/plymouth-vfill"
PREFIX=/usr/local/lib/omarchy-vfill
THEME_DIR="$HOME/.local/state/omarchy/current/theme"
# Root-owned, so they are installed and removed by the privileged transaction
# below rather than here. Passed into it as arguments so the tests can replay
# that transaction against scratch paths.
REBOOT_BIN=/usr/local/bin/omarchy-vfill-reboot
DESKTOP_ENTRY=/usr/local/share/applications/omarchy-vfill-reboot.desktop

source "$REPO/lib/vfill.sh"

# Mode auto's polkit rule. VFILL_POLKIT_RULES_DIR is read here, unprivileged,
# and then handed into the root transaction as an argv word -- which is exactly
# how it got past the env scrubbing that makes VFILL_THEME_DEST harmless, so it
# is gated rather than honoured. vfill_polkit_rules_dir has the whole argument;
# everything it does not allow ends the install here, before anything is
# inspected or changed.
POLKIT_RULE_NAME=$VFILL_POLKIT_RULE_NAME
POLKIT_RULES_DIR=$(vfill_polkit_rules_dir) || {
  echo "install: nothing was changed." >&2
  exit 1
}
POLKIT_RULE="$POLKIT_RULES_DIR/$POLKIT_RULE_NAME"
# Removed by every mode other than auto whatever the override says, so a stale
# override in the environment can never be the only path a mode switch cleans up.
POLKIT_RULE_DEFAULT="$VFILL_POLKIT_RULES_DIR_DEFAULT/$POLKIT_RULE_NAME"
POLKIT_RULE_SRC="$REPO/share/$POLKIT_RULE_NAME"

MODE=""
# Mode auto is the one mode that cannot be chosen by accident: non-interactively
# it needs this second flag as well, and interactively it needs the word "yes".
I_UNDERSTAND=false

while (($# > 0)); do
  case "$1" in
    --mode)
      # Refused before shifting. A missing or empty value used to leave MODE
      # empty, which skipped the validation below, fell into the prompt and --
      # with no tty -- silently took the default: the one mode that adds a
      # recurring password prompt. The shift also failed silently at $#==0.
      if (($# < 2)) || [[ -z $2 ]]; then
        echo "install: --mode needs a value" >&2
        echo "install: expected one of: theme-set, reboot, manual, auto" >&2
        exit 1
      fi
      MODE="$2"
      shift
      ;;
    --i-understand)
      # Takes no value, so there is nothing to refuse here; on its own it
      # changes nothing, and only --mode auto requires it.
      I_UNDERSTAND=true
      ;;
    *)
      echo "install: unknown option: $1" >&2
      echo "install: usage: ./install.sh [--mode theme-set|reboot|manual|auto] [--i-understand]" >&2
      exit 1
      ;;
  esac
  shift
done

# Validated before anything is inspected or changed, so a typo costs nothing.
if [[ -n $MODE ]]; then
  case "$MODE" in
    theme-set | reboot | manual | auto) ;;
    *)
      echo "install: unknown mode: $MODE" >&2
      echo "install: expected one of: theme-set, reboot, manual, auto" >&2
      exit 1
      ;;
  esac
fi

# Why mode auto cannot work on this machine, or empty when it can. Everything
# here is checked before anything is written: a rule that can never match is
# worse than no rule, because the splash would look after itself and does not.
AUTO_REFUSAL=""
auto_supported() {
  AUTO_REFUSAL=""

  # Looked for, never run. A rules file is read by polkitd; with no polkitd it
  # would just sit there.
  if ! command -v polkitd >/dev/null && [[ ! -x /usr/lib/polkit-1/polkitd ]]; then
    AUTO_REFUSAL="polkitd was not found, so a polkit rule would never be read"
    return 1
  fi

  # JavaScript rules under rules.d are polkit 0.106 and newer. Older polkit has
  # no such directory and would ignore the rule entirely.
  if [[ ! -d $POLKIT_RULES_DIR ]]; then
    AUTO_REFUSAL="$POLKIT_RULES_DIR does not exist, so this polkit is too old for JavaScript rules (0.106 or newer is needed)"
    return 1
  fi

  # The rule matches only a subject in group wheel, so without it nothing
  # changes: every retheme would still ask for a password.
  local groups=""
  groups=$(id -nG 2>/dev/null) || groups=""
  case " $groups " in
    *" wheel "*) ;;
    *)
      AUTO_REFUSAL="you are not in group wheel, so the rule would never match your session"
      return 1
      ;;
  esac

  return 0
}

refuse_auto() {
  echo "install: mode auto is not available here: $AUTO_REFUSAL." >&2
  echo "install:   Use mode 1 (theme-set) instead -- the same hook, asking for your" >&2
  echo "install:   password when the colours change." >&2
}

# The rule this installer is prepared to hand root, byte for byte. The file in
# the checkout is still the only thing the transaction copies -- this is a
# comparison baseline, never a source -- and test/install-test.sh asserts the two
# are identical, so changing one without the other is a failing test.
polkit_rule_expected() {
  cat <<'RULE'
// /etc/polkit-1/rules.d/49-omarchy-vfill.rules, root:root 0644
//
// Installed only by install mode `auto`, from inside install.sh's single
// privileged transaction, and removed again by every other mode and by
// uninstall.sh. install.sh compares this file byte for byte against the rule it
// ships before letting root install it: the program path below has to name the
// installed retheme exactly, because a stale path here would grant passwordless
// root to the wrong program, and an edited rule could widen what is approved.
//
// Both the program and the whole command line are required to be that one path,
// so only the bare, argument-free invocation is passwordless. The program check
// on its own approved every argument the retheme accepts as well -- including
// `--theme-dir <path>`, which names the directory root reads colors.toml and
// unlock.png from. Any local active wheel process could therefore have had root
// publish colours and artwork of its own choosing into the live Plymouth theme
// and the next initramfs, with no prompt, which is more than the consent text
// promises. The theme-set hook consequently passes no arguments at all and lets
// the retheme resolve the invoking user's theme from PKEXEC_UID.
//
// pkexec's manual says not to use command_line for security checks, because it
// is argv joined with single spaces and so cannot be taken apart again. This
// rule never takes it apart: it compares it for equality with a string that
// contains no space, and only a single-word argv -- the argument-free
// invocation -- can produce that. `program`, which pkexec resolves itself,
// stays the authoritative check on *what* runs; command_line narrows it to one
// invocation of it.
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.policykit.exec" &&
      action.lookup("program") == "/usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme" &&
      action.lookup("command_line") == "/usr/local/lib/omarchy-vfill/bin/omarchy-vfill-retheme" &&
      subject.isInLocalSession() && subject.active && subject.isInGroup("wheel")) {
    return polkit.Result.YES;
  }
});
RULE
}

# The rule grants passwordless root, so what root installs has to be this exact
# rule -- not merely a file that mentions the right program somewhere.
#
# The previous check was a grep for the program string anywhere in the file, which
# is a typo guard and not a tamper guard: any file that named the retheme in a
# comment passed, so a crafted rules file was enough to have root write whatever
# that file contained. Together with a crafted VFILL_POLKIT_RULES_DIR (now gated)
# that meant root writing an attacker's drop-in into a directory of their choice.
#
# The limit, stated plainly: whoever can edit share/49-omarchy-vfill.rules can
# usually edit this file too. This guards a rules file that drifted, was patched
# downstream, or was swapped on its own -- not an attacker who owns the checkout.
check_rule_path() {
  [[ -f $POLKIT_RULE_SRC ]] || {
    echo "install: $POLKIT_RULE_SRC is missing; mode auto cannot be installed" >&2
    return 1
  }

  polkit_rule_expected | cmp -s - "$POLKIT_RULE_SRC" || {
    echo "install: $POLKIT_RULE_SRC is not the rule this installer approves" >&2
    echo "install:   It is compared byte for byte against the rule written out in" >&2
    echo "install:   install.sh, which grants passwordless root to" >&2
    echo "install:   \"$PREFIX/bin/omarchy-vfill-retheme\" with no arguments and" >&2
    echo "install:   nothing else. An edited, stale or patched rule is refused rather" >&2
    echo "install:   than installed, because installing it would grant passwordless root" >&2
    echo "install:   to whatever it actually says. Refusing to install it." >&2
    return 1
  }

  return 0
}

# What the rule actually approves, and nothing more. This used to say "that one
# program only -- it is root-owned, so what the rule approves cannot be changed
# by you", which claimed more than the rule did: pinning the program alone left
# every argument approved too, --theme-dir among them. It also said the worst case
# was "not a privilege leak", which is not this installer's to promise -- what the
# rule is worth rests entirely on the retheme being correct.
auto_consent() {
  echo "  Mode auto installs $POLKIT_RULE, which means:"
  echo "    - Any process running as you, in an active local session, may run"
  echo "      $PREFIX/bin/omarchy-vfill-retheme as root"
  echo "      with no prompt -- that exact command and no arguments. The rule"
  echo "      approves the program and the whole command line, and the program is"
  echo "      root-owned, so neither is yours to change. Run with no arguments it"
  echo "      recolours the splash from your own current Omarchy theme."
  echo "    - It can therefore trigger unlimited initramfs rebuilds: disk and CPU"
  echo "      churn."
  echo "    - It writes the boot image; the current image survives until a rebuild"
  echo "      succeeds."
  echo "    - Mode auto is only as safe as that one script is correct. Every bug in"
  echo "      it -- anything it would run, write or trust -- becomes a bug that runs"
  echo "      as root without anyone being asked first."
  echo "    - Remove it with ./uninstall.sh, or by switching to another mode."
}

# Non-interactively, mode auto needs the second flag as well: nothing that
# merely passes --mode along should be able to turn off the password prompt.
if [[ $MODE == auto ]]; then
  $I_UNDERSTAND || {
    echo "install: --mode auto on its own is refused." >&2
    echo "install:   It installs a polkit rule that lets any process running as you, in" >&2
    echo "install:   an active local session, run this as root with no prompt:" >&2
    echo "install:     $PREFIX/bin/omarchy-vfill-retheme" >&2
    echo "install:   That one root-owned program, with no arguments, which can then" >&2
    echo "install:   rebuild the initramfs as often as it likes." >&2
    echo "install:   If that is what you want, say so explicitly:" >&2
    echo "install:     ./install.sh --mode auto --i-understand" >&2
    exit 1
  }

  auto_supported || {
    refuse_auto
    exit 1
  }
  check_rule_path || exit 1
fi

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
  echo "  That restore rebuilds the initramfs once; this install rebuilds it again."
  # Defaulted because `read` leaves its variable UNSET on a read error -- a
  # closed stdin, as a desktop launch has -- and set -u then killed the script
  # with "reply: unbound variable" instead of taking the safe answer below.
  reply=""
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

# Ask only when --mode did not already answer. A bad answer is re-asked rather
# than guessed at: each mode costs the user something different (a password
# prompt per theme change, a slower reboot, or remembering a command), so
# picking one for them is worse than asking again.
#
# No answer at all -- an empty or closed stdin, as in a scripted install --
# takes the default rather than looping forever.
if [[ -z $MODE ]]; then
  echo "How should the boot splash follow your desktop theme?"
  echo "  1) At theme change — authenticate when the theme's colours change (default)"
  echo "  2) Before reboot — update it from the \"Plymouth vfill reboot\" action"
  echo "  3) Manually — run the update command yourself"
  echo "  4) At theme change, without a password — as 1, plus a polkit rule (advanced)"

  while [[ -z $MODE ]]; do
    if ! read -r -p "  Choice [1]: " reply; then
      echo "install: no answer given; using the default (at theme change)"
      MODE=theme-set
      break
    fi

    case "${reply:-1}" in
      1) MODE=theme-set ;;
      2) MODE=reboot ;;
      3) MODE=manual ;;
      4)
        # Never reached by pressing Enter -- "${reply:-1}" sends an empty answer
        # to 1 -- and never taken without the word "yes" typed in full.
        if ! auto_supported; then
          refuse_auto
          continue
        fi

        auto_consent
        confirm=""
        if ! read -r -p "  Type yes (in full) to choose mode auto: " confirm; then
          echo "install: no answer given; mode auto not chosen"
          continue
        fi

        if [[ $confirm == yes ]]; then
          check_rule_path || exit 1
          MODE=auto
        else
          echo "  Mode auto not chosen."
        fi
        ;;
      *) echo "  Please answer 1, 2, 3 or 4." ;;
    esac
  done
fi

run_root() {
  if [[ -t 0 ]]; then
    sudo "$@"
  else
    pkexec "$@"
  fi
}

echo "install: staging the theme into $PREFIX and applying it (requires root)"

# The retheme script runs as root, so it and everything it sources must live
# where the user cannot write. The checkout is only the installation source.
#
# Every root-owned artefact of every mode is settled inside this one
# transaction -- the mode file, the reboot command and its desktop entry
# (installed for mode reboot, removed for the others) and mode auto's polkit
# rule (installed for auto, removed for the others) -- so switching modes on a
# re-install still costs the user exactly one authentication.
run_root /bin/bash -c '
  set -euo pipefail
  prefix="$1" repo="$2" theme_dir="$3" mode="$4" reboot_bin="$5" desktop_entry="$6"
  polkit_rule="$7" polkit_rule_default="$8"

  install -d -m 0755 -o root -g root "$prefix" "$prefix/bin" "$prefix/lib" "$prefix/theme"
  install -m 0755 -o root -g root "$repo/bin/omarchy-vfill-retheme" "$prefix/bin/omarchy-vfill-retheme"
  install -m 0644 -o root -g root "$repo/lib/vfill.sh" "$prefix/lib/vfill.sh"
  install -m 0644 -o root -g root \
    "$repo/theme/omarchy-vfill.plymouth" "$repo/theme/omarchy-vfill.script" "$prefix/theme/"

  # Records which mode is active for the operator to read, and nothing more:
  # as the header says, no code reads this file back. Root-owned 0644, so the
  # user may read it and not change it.
  printf "%s\n" "$mode" | install -m 0644 -o root -g root /dev/stdin "$prefix/mode"

  if [[ $mode == reboot ]]; then
    # Created only when missing. /usr/local/bin and
    # /usr/local/share/applications normally already exist and belong to the
    # system; install -d on them would rewrite their mode and owner.
    for dir in "$(dirname "$reboot_bin")" "$(dirname "$desktop_entry")"; do
      [[ -d $dir ]] || install -d -m 0755 -o root -g root "$dir"
    done
    install -m 0755 -o root -g root "$repo/bin/omarchy-vfill-reboot" "$reboot_bin"
    install -m 0644 -o root -g root "$repo/share/omarchy-vfill-reboot.desktop" "$desktop_entry"
  else
    rm -f -- "$reboot_bin" "$desktop_entry"
  fi

  if [[ $mode == auto ]]; then
    # Copied from the checkout like every other artefact -- never written here
    # from a heredoc -- and never into a directory this creates: the installer
    # refused mode auto already if rules.d was missing, because a polkit too
    # old to have it is too old to read the rule.
    install -m 0644 -o root -g root "$repo/share/49-omarchy-vfill.rules" "$polkit_rule"
  else
    # Both paths, always. Removing only the overridden one meant a single line in
    # a shell profile could leave a mode switch away from auto with passwordless
    # root still installed at the default path. Removing a file that is not there
    # is free, and the two are the same path on every real run.
    rm -f -- "$polkit_rule" "$polkit_rule_default"
  fi

  exec "$prefix/bin/omarchy-vfill-retheme" --force --theme-dir "$theme_dir"
' bash "$PREFIX" "$REPO" "$THEME_DIR" "$MODE" "$REBOOT_BIN" "$DESKTOP_ENTRY" \
  "$POLKIT_RULE" "$POLKIT_RULE_DEFAULT" || {
  # Everything above is honest about not knowing how far it got, because it
  # cannot: the transaction stages the prefix, writes the mode file, settles
  # mode reboot's artefacts and only then execs the retheme, which swaps the
  # live theme directory in and repoints the Plymouth default BEFORE it rebuilds
  # the initramfs and installs the marker. So a failure at the rebuild or the
  # marker leaves the live theme already replaced. Claiming otherwise told the
  # operator to walk away from a half-applied splash.
  echo "install: privileged install/retheme step failed." >&2
  echo "install:   Depending on how far it got, $PREFIX, the recorded mode and" >&2
  echo "install:   mode reboot's or mode auto's artefacts may already be in place," >&2
  echo "install:   and the live Plymouth theme and the Plymouth default may already have been" >&2
  echo "install:   changed with an initramfs that does not yet match them." >&2
  echo "install:   No theme-set hook was installed or removed by this run;" >&2
  echo "install:   one left by a previous install is still active." >&2
  echo "install:   Re-run ./install.sh to finish the job, or ./uninstall.sh to" >&2
  echo "install:   back it out; either one leaves the splash in a known state." >&2
  exit 1
}

# The hook lives under $HOME and is the user's own file, so it is settled here
# rather than in the transaction -- and only now, because until the transaction
# succeeded there was no installed retheme for it to point at. A hook left by a
# previous install in a different mode is removed for the same reason it is
# installed: the mode file and the artefacts on disk have to agree.
if [[ $MODE == theme-set || $MODE == auto ]]; then
  install -d -m 0755 "$HOOK_DIR" || {
    echo "install: failed to create $HOOK_DIR" >&2
    exit 1
  }

  # Rendered to a temp file and swapped in, never written over the live hook: a
  # redirection onto $HOOK_DEST truncates it first, so a failed render on a
  # re-install would leave an empty file that omarchy-hook still executes. The
  # temp name starts with a dot, so omarchy-hook's dir/* glob never matches it
  # even in the instant it exists, and it is made executable before the swap so
  # the hook is never present-but-not-runnable.
  hook_tmp=$(mktemp "$HOOK_DIR/.omarchy-vfill.sh.XXXXXX") || {
    echo "install: failed to create a temporary file in $HOOK_DIR" >&2
    exit 1
  }
  if ! vfill_render_hook "$REPO/hooks/theme-set.sh" "$PREFIX/bin/omarchy-vfill-retheme" >"$hook_tmp"; then
    rm -f -- "$hook_tmp"
    echo "install: failed to render the theme-set hook; the previous hook, if any, is untouched" >&2
    exit 1
  fi
  chmod 0755 "$hook_tmp" || {
    rm -f -- "$hook_tmp"
    echo "install: failed to make the theme-set hook executable" >&2
    exit 1
  }
  mv -T -- "$hook_tmp" "$HOOK_DEST" || {
    rm -f -- "$hook_tmp"
    echo "install: failed to install the theme-set hook" >&2
    exit 1
  }
elif [[ -f $HOOK_DEST ]]; then
  echo "install: removing the theme-set hook from a previous install"
  rm -f -- "$HOOK_DEST"
fi

echo "install: done. Reboot to see the new boot splash."

case "$MODE" in
  theme-set)
    echo "install: mode: at theme change. $HOOK_DEST"
    echo "install:   updates the splash when the theme's colours change, asking for your"
    echo "install:   password and rebuilding the initramfs (about 90 seconds) when it does."
    echo "install:   A theme change that alters nothing it bakes in costs nothing at all."
    ;;
  reboot)
    echo "install: mode: before reboot. Nothing happens on a theme change; choose"
    echo "install:   \"Plymouth vfill reboot\" from your launcher (or run"
    echo "install:   $REBOOT_BIN) and the splash is brought up to"
    echo "install:   date first -- about 90 seconds -- and the machine reboots only if that worked."
    ;;
  manual)
    echo "install: mode: manually. Nothing updates the splash for you."
    ;;
  auto)
    echo "install: mode: at theme change, without a password. $HOOK_DEST"
    echo "install:   updates the splash when the theme's colours change, and $POLKIT_RULE"
    echo "install:   lets it do that without asking: any process running as you, in an active"
    echo "install:   local session, may run $PREFIX/bin/omarchy-vfill-retheme"
    echo "install:   as root with no prompt -- that one root-owned program, with no"
    echo "install:   arguments. Rebuilding still takes about 90 seconds; you just will not"
    echo "install:   be asked first. Mode auto is only as safe as that script is correct."
    echo "install:   Remove the rule with ./uninstall.sh, or by re-installing in another mode."
    ;;
esac

echo "install: whatever the mode, you can always update the splash by hand with:"
echo "install:   sudo $PREFIX/bin/omarchy-vfill-retheme --force"

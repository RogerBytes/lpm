# --- bash completion for lpm ---
#
# Bash counterpart of completions/_lpm (zsh). Both query lpm itself, never the Lutris
# database directly, so the Flatpak/native detection and the blacklisted-game filtering
# (shared giga-prefixes) live in one place only (zgu-lutris-utils.sh).
#
# Manual install (if install.sh has not done it):
#   sudo cp completions/lpm.bash /usr/local/share/bash-completion/completions/lpm
#   (then open a new terminal, or "source" that file)

# Installed game slugs ("lpm list", format "slug  Name", two-space separator -- see
# zgp-game-lister.sh). Filter on that separator rather than on the "no games" message
# so it works in any lpm language.
_lpm_installed_slugs() {
  lpm list 2>/dev/null | awk -F'  ' 'NF>1{print $1}'
}

# Installed runner names ("lpm list-runner", one per line). A real runner name is a
# single word, so filter NF==1 to skip the "no runner" message regardless of language.
_lpm_installed_runners() {
  lpm list-runner 2>/dev/null | awk 'NF==1{print $1}'
}

_lpm_commands="install install-runner uninstall uninstall-runner pack pack-runner \
isolate list list-isolable info create-prefix exe-install shortcut icon splash logo sync-media lsfg \
launcher launcher-entries tools vsync killwine list-runner list-remote-runners check lutris-version self-update log"

# Valid compression levels (0 to 22, see bin/lpm: "-[0-9]|-1[0-9]|-2[0-2]") -- a
# single attached token ("-9", like gzip), not an option followed by a value.
_lpm_compression_opts="-0 -1 -2 -3 -4 -5 -6 -7 -8 -9 -10 -11 -12 -13 -14 -15 -16 -17 \
-18 -19 -20 -21 -22"

_lpm() {
  # words and cword are set by _init_completion (bash-completion) and unused here (we use
  # COMP_WORDS / COMP_CWORD); declared local so they do not leak into the user's shell.
  # shellcheck disable=SC2034
  local cur prev words cword
  _init_completion || {
    # _init_completion comes from the bash-completion package; if it is not loaded,
    # fall back to a minimal setup rather than breaking completion for the whole shell.
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
  }

  local command="${COMP_WORDS[1]:-}"

  # First word: subcommand, or -h/--help/-v/--version
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    # Global options (valid BEFORE the subcommand, see docs/commands/options.md)
    COMPREPLY=($(compgen -W "${_lpm_commands} -h --help -v --version -y --allow-scripts --ignore-hash --hash" -- "${cur}"))
    return 0
  fi

  # Values of options that take one (separate "option value" form)
  case "${command}:${prev}" in
    install:-s|install:--shortcut|shortcut:-s|shortcut:--shortcut)
      COMPREPLY=($(compgen -W "menu desktop both none" -- "${cur}"))
      return 0
      ;;
    create-prefix:-r|create-prefix:--runner|exe-install:-r|exe-install:--runner)
      COMPREPLY=($(compgen -W "$(_lpm_installed_runners)" -- "${cur}"))
      return 0
      ;;
    create-prefix:-a|create-prefix:--arch|exe-install:-a|exe-install:--arch)
      COMPREPLY=($(compgen -W "win32 win64" -- "${cur}"))
      return 0
      ;;
    exe-install:-f|exe-install:--final-exe)
      COMPREPLY=($(compgen -f -- "${cur}"))
      return 0
      ;;
    icon:--url|splash:--url|logo:--url)
      COMPREPLY=()  # free-form URL
      return 0
      ;;
  esac

  case "${command}" in
    install)
      COMPREPLY=($(compgen -W "-y --allow-scripts --ignore-hash -s --shortcut --desktop-dir= -n --no-loadingscreen" -- "${cur}"))
      # .zgp file completion in addition to options: compgen -f then filter on the
      # extension, so bash handles path escaping as usual.
      if [[ "${cur}" != -* ]]; then
        COMPREPLY+=($(compgen -f -X '!*.zgp' -- "${cur}"))
      fi
      ;;
    install-runner)
      COMPREPLY=($(compgen -W "-y --ignore-hash" -- "${cur}"))
      if [[ "${cur}" != -* ]]; then
        COMPREPLY+=($(compgen -f -X '!*.zgr' -- "${cur}"))
      fi
      ;;
    uninstall)
      COMPREPLY=($(compgen -W "-y --desktop-dir= $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    uninstall-runner)
      COMPREPLY=($(compgen -W "-y $(_lpm_installed_runners)" -- "${cur}"))
      ;;
    pack)
      COMPREPLY=($(compgen -W "--all --hash ${_lpm_compression_opts} $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    pack-runner)
      COMPREPLY=($(compgen -W "--all --hash ${_lpm_compression_opts} $(_lpm_installed_runners)" -- "${cur}"))
      ;;
    isolate)
      # "isolate" works per STORE, not per game: offer the known store codes plus the
      # slugs of currently isolable games (each resolves to its store via
      # zgp_resolve_store_arg). "lpm list-isolable" (column 1) lists those slugs.
      COMPREPLY=($(compgen -W "-y egs ea ubisoft battlenet $(lpm list-isolable 2>/dev/null | awk -F'  ' 'NF>1{print $1}')" -- "${cur}"))
      ;;
    info)
      # A single slug is expected: no completion beyond the first argument.
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        COMPREPLY=($(compgen -W "$(_lpm_installed_slugs)" -- "${cur}"))
      fi
      ;;
    create-prefix)
      # Free-form names ("Display name" or "Display name|custom-slug"): no file
      # completion, only the -y option.
      COMPREPLY=($(compgen -W "-y -r --runner -a --arch" -- "${cur}"))
      ;;
    exe-install)
      COMPREPLY=($(compgen -W "-y -r --runner -a --arch -f --final-exe" -- "${cur}"))
      # Complete common Windows installer files (one pass per extension rather than a
      # -X pattern with alternation, to avoid depending on "shopt -s extglob"). The
      # optional "|name|slug" part is typed by hand.
      if [[ "${cur}" != -* ]]; then
        for ext in exe EXE msi MSI bat BAT cmd CMD; do
          COMPREPLY+=($(compgen -f -X "!*.${ext}" -- "${cur}"))
        done
      fi
      ;;
    shortcut)
      COMPREPLY=($(compgen -W "--all -s --shortcut -n --no-loadingscreen -k --allow-hooks --desktop-dir= $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    icon|splash|logo)
      # "--all" or a list of installed game slugs; --url forces a specific image.
      COMPREPLY=($(compgen -W "--all --url $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    sync-media)
      COMPREPLY=($(compgen -W "--all $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    lsfg)
      # "lpm lsfg [slugs...] [on|off]" and "lpm launcher [slugs...] [on|off]": installed
      # Wine/Proton game slugs, plus "on"/"off" last (see zgl-lsfg-manager.sh /
      # zgl-launcher-manager.sh, same argument scheme). Both sets are offered at every
      # position.
      COMPREPLY=($(compgen -W "on off $(_lpm_installed_slugs)" -- "${cur}"))
      COMPREPLY+=($(compgen -W "status" -- "${cur}"))
      ;;
    launcher)
      COMPREPLY=($(compgen -W "on off status --if-needed $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    tools)
      # "lpm tools [slug] [tool] [exe|folder]": 1st = installed game slug, 2nd = tool
      # (winetricks|regedit|winecfg|console|exe|folder|favorite), 3rd = .exe file (tool=exe)
      # or real folder (tool=favorite); unused for the other tools.
      case "${COMP_CWORD}" in
        2)
          COMPREPLY=($(compgen -W "$(_lpm_installed_slugs)" -- "${cur}"))
          ;;
        3)
          COMPREPLY=($(compgen -W "winetricks regedit winecfg console exe folder favorite env runner mangohud gamepad" -- "${cur}"))
          ;;
        4)
          if [[ "${prev}" != -* ]]; then
            case "${COMP_WORDS[3]:-}" in
              exe) COMPREPLY=($(compgen -f -X '!*.exe' -- "${cur}")) ;;
              favorite) COMPREPLY=($(compgen -d -- "${cur}")) ;;
              env) COMPREPLY=($(compgen -W "list set unset apply" -- "${cur}")) ;;
              mangohud) COMPREPLY=($(compgen -W "on off status" -- "${cur}")) ;;
              gamepad) COMPREPLY=($(compgen -W "on off edit status" -- "${cur}")) ;;
              runner) COMPREPLY=($(compgen -W "$(_lpm_installed_runners)" -- "${cur}")) ;;
            esac
          fi
          ;;
      esac
      ;;
    vsync)
      # "lpm vsync status" | "lpm vsync <slug> [status|on|off] [setting...]": 1st =
      # "status" or an installed game slug, 2nd = action, then settings (see
      # zgp-game-vsync.sh; none given = all).
      case "${COMP_CWORD}" in
        2) COMPREPLY=($(compgen -W "status $(_lpm_installed_slugs)" -- "${cur}")) ;;
        3) [[ "${COMP_WORDS[2]:-}" != status ]] && COMPREPLY=($(compgen -W "status on off" -- "${cur}")) ;;
        *)
          case "${COMP_WORDS[3]:-}" in
            on|off) COMPREPLY=($(compgen -W "d3d9 d3d11 d3d12 gl-nvidia gl-mesa" -- "${cur}")) ;;
          esac
          ;;
      esac
      ;;
    launcher-entries)
      # "lpm launcher-entries <slug> get|set <fichier.json>"
      case "${COMP_CWORD}" in
        2) COMPREPLY=($(compgen -W "$(_lpm_installed_slugs)" -- "${cur}")) ;;
        3) COMPREPLY=($(compgen -W "get set" -- "${cur}")) ;;
        4) [[ "${COMP_WORDS[3]:-}" = set ]] && COMPREPLY=($(compgen -f -X '!*.json' -- "${cur}")) ;;
      esac
      ;;
    killwine)
      COMPREPLY=($(compgen -W "-y" -- "${cur}"))
      ;;
    check)
      COMPREPLY=($(compgen -W "-y" -- "${cur}"))
      ;;
    self-update)
      COMPREPLY=($(compgen -W "check install" -- "${cur}"))
      ;;
    lutris-version)
      # No argument: show the state. Otherwise force a choice or clear it -- no other
      # value is accepted by zgc-lutris-version-checker.sh.
      COMPREPLY=($(compgen -W "flatpak native reset" -- "${cur}"))
      ;;
    log)
      case "${prev}" in
        -n|--grep)
          # The next value (line count or pattern) is free-form: no useful completion.
          COMPREPLY=()
          return 0
          ;;
      esac
      COMPREPLY=($(compgen -W "-n --all --grep --clear" -- "${cur}"))
      ;;
    list|list-isolable|list-runner|list-remote-runners)
      # No arguments expected.
      COMPREPLY=()
      ;;
    *)
      COMPREPLY=()
      ;;
  esac

  return 0
}

complete -F _lpm lpm
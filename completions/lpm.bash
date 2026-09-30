# --- Complétion bash pour lpm ---
#
# Équivalent bash de completions/_lpm (zsh) : mêmes sources de vérité (lpm lui-même,
# jamais la base Lutris directement), pour ne jamais diverger sur la logique de
# détection Flatpak/paquet natif ou le filtrage des jeux blacklistés (giga-préfixes
# partagés), qui ne vit qu'à un seul endroit (zgu-lutris-utils.sh).
#
# Installation manuelle (si install.sh ne l'a pas déjà fait) :
#   sudo cp completions/lpm.bash /usr/local/share/bash-completion/completions/lpm
#   (puis ouvrir un nouveau terminal, ou "source /usr/local/share/bash-completion/completions/lpm")

# Slugs des jeux installés ("lpm list", format "slug  Nom du jeu", séparateur deux
# espaces -- voir zgp-game-lister.sh : echo "${slug}  ${name}"). Filtre structurel sur
# ce séparateur plutôt que sur le texte du message "Aucun jeu installé." : indépendant
# de la langue active de lpm.
_lpm_installed_slugs() {
  lpm list 2>/dev/null | awk -F'  ' 'NF>1{print $1}'
}

# Noms des runners installés ("lpm list-runner", un nom par ligne). Un nom de runner
# réel est toujours un seul mot (basename de dossier) ; filtre NF==1 pour ignorer le
# message "Aucun runner installé.", sans dépendre de la langue active de lpm -- même
# logique que _lpm_installed_slugs ci-dessus.
_lpm_installed_runners() {
  lpm list-runner 2>/dev/null | awk 'NF==1{print $1}'
}

_lpm_commands="install install-runner uninstall uninstall-runner pack pack-runner \
isolate list list-isolable info create-prefix exe-install shortcut icon splash lsfg \
launcher tools killwine list-runner list-remote-runners check lutris-version log"

# Niveaux de compression valides (0 à 22, voir bin/lpm : "-[0-9]|-1[0-9]|-2[0-2]") --
# un token collé ("-9", comme gzip), pas une option suivie d'une valeur séparée.
_lpm_compression_opts="-0 -1 -2 -3 -4 -5 -6 -7 -8 -9 -10 -11 -12 -13 -14 -15 -16 -17 \
-18 -19 -20 -21 -22"

_lpm() {
  local cur prev words cword
  _init_completion || {
    # _init_completion vient du paquet bash-completion (fonctions communes) ; si le
    # système ne l'a pas chargé pour une raison quelconque, repli minimal plutôt que de
    # planter la complétion pour tout le shell.
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
  }

  local command="${COMP_WORDS[1]:-}"

  # Premier mot : sous-commande, ou -h/--help/-v/--version
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=($(compgen -W "${_lpm_commands} -h --help -v --version" -- "${cur}"))
    return 0
  fi

  case "${command}" in
    install)
      COMPREPLY=($(compgen -W "-y --allow-scripts" -- "${cur}"))
      # Complétion de fichiers .zgp en plus des options : compgen -f puis filtre
      # sur l'extension, pour laisser bash gérer l'échappement des chemins comme
      # d'habitude (espaces, apostrophes...).
      if [[ "${cur}" != -* ]]; then
        COMPREPLY+=($(compgen -f -X '!*.zgp' -- "${cur}"))
      fi
      ;;
    install-runner)
      COMPREPLY=($(compgen -W "-y" -- "${cur}"))
      if [[ "${cur}" != -* ]]; then
        COMPREPLY+=($(compgen -f -X '!*.zgr' -- "${cur}"))
      fi
      ;;
    uninstall)
      COMPREPLY=($(compgen -W "-y $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    uninstall-runner)
      COMPREPLY=($(compgen -W "-y $(_lpm_installed_runners)" -- "${cur}"))
      ;;
    pack)
      COMPREPLY=($(compgen -W "--all ${_lpm_compression_opts} $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    pack-runner)
      COMPREPLY=($(compgen -W "--all ${_lpm_compression_opts} $(_lpm_installed_runners)" -- "${cur}"))
      ;;
    isolate)
      # "isolate" opère par STORE, pas par jeu : on propose les codes de store connus, ainsi
      # que les slugs de jeux actuellement isolables (chacun résout vers son store via
      # zgp_resolve_store_arg) -- pas de complétion dynamique fiable au-delà sans dupliquer
      # la détection de zgu_get_blacklisted_slugs ; "lpm list-isolable" (colonne 1) donne les
      # slugs déjà connus comme isolables.
      COMPREPLY=($(compgen -W "egs ea ubisoft battlenet $(lpm list-isolable 2>/dev/null | awk -F'  ' 'NF>1{print $1}')" -- "${cur}"))
      ;;
    info)
      # Un seul slug attendu : pas de complétion au-delà du premier argument.
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        COMPREPLY=($(compgen -W "$(_lpm_installed_slugs)" -- "${cur}"))
      fi
      ;;
    create-prefix)
      # Noms libres ("Nom affiché" ou "Nom affiché|slug-personnalise") : pas de
      # complétion de fichiers, juste l'option -y.
      COMPREPLY=($(compgen -W "-y" -- "${cur}"))
      ;;
    exe-install)
      COMPREPLY=($(compgen -W "-y" -- "${cur}"))
      # Complétion de fichiers d'installateurs Windows courants (une passe par
      # extension plutôt qu'un motif -X avec alternation, pour rester compatible
      # sans dépendre de "shopt -s extglob"). Comme pour install/install-runner,
      # on laisse bash gérer l'échappement des chemins ; la partie "|nom|slug"
      # éventuelle se tape ensuite à la main.
      if [[ "${cur}" != -* ]]; then
        for ext in exe EXE msi MSI bat BAT cmd CMD; do
          COMPREPLY+=($(compgen -f -X "!*.${ext}" -- "${cur}"))
        done
      fi
      ;;
    shortcut|icon|splash)
      # "--all" ou une liste de slugs de jeux déjà installés.
      COMPREPLY=($(compgen -W "--all $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    lsfg|launcher)
      # "lpm lsfg [slugs...] [on|off]" et "lpm launcher [slugs...] [on|off]" : slugs de
      # jeux Wine/Proton installés, plus "on"/"off" en dernière position (voir
      # zgl-lsfg-manager.sh / zgl-launcher-manager.sh, même schéma d'arguments pour les
      # deux commandes). Le dernier mot complété peut être un slug ou l'action selon où
      # on en est ; on propose les deux ensembles à chaque position, comme pour les
      # autres sous-commandes ici.
      COMPREPLY=($(compgen -W "on off $(_lpm_installed_slugs)" -- "${cur}"))
      ;;
    tools)
      # "lpm tools [slug] [outil] [exe|dossier]" : 1er argument = slug de jeu installé,
      # 2e = outil (winetricks|regedit|winecfg|console|exe|folder|favorite), 3e = fichier
      # .exe (si outil=exe) ou dossier réel (si outil=favorite) -- sans intérêt pour les
      # 4 autres outils.
      case "${COMP_CWORD}" in
        2)
          COMPREPLY=($(compgen -W "$(_lpm_installed_slugs)" -- "${cur}"))
          ;;
        3)
          COMPREPLY=($(compgen -W "winetricks regedit winecfg console exe folder favorite" -- "${cur}"))
          ;;
        4)
          if [[ "${prev}" != -* ]]; then
            case "${words[3]:-}" in
              exe) COMPREPLY=($(compgen -f -X '!*.exe' -- "${cur}")) ;;
              favorite) COMPREPLY=($(compgen -d -- "${cur}")) ;;
            esac
          fi
          ;;
      esac
      ;;
    killwine)
      COMPREPLY=($(compgen -W "-y" -- "${cur}"))
      ;;
    check)
      COMPREPLY=($(compgen -W "-y" -- "${cur}"))
      ;;
    lutris-version)
      # Sans argument : affiche l'état. Sinon : force un choix ou l'efface -- jamais
      # d'autre valeur acceptée par zgc-lutris-version-checker.sh.
      COMPREPLY=($(compgen -W "flatpak native reset" -- "${cur}"))
      ;;
    log)
      case "${prev}" in
        -n|--grep)
          # Valeur attendue ensuite (nombre de lignes ou motif) : pas de complétion
          # utile, on laisse le champ libre.
          COMPREPLY=()
          return 0
          ;;
      esac
      COMPREPLY=($(compgen -W "-n --all --grep --clear" -- "${cur}"))
      ;;
    list|list-isolable|list-runner|list-remote-runners)
      # Aucun argument attendu.
      COMPREPLY=()
      ;;
    *)
      COMPREPLY=()
      ;;
  esac

  return 0
}

complete -F _lpm lpm
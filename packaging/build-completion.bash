# --- Complétion bash pour packaging/build.sh ---
#
# build.sh est un script de projet, lancé par chemin relatif ("./build.sh"), pas une
# commande installée sur le système : contrairement à completions/lpm.bash (complétion de
# la commande "lpm", installée par install.sh/les paquets), ce fichier ne s'installe nulle
# part -- il faut le charger explicitement dans le shell courant.
#
# Usage ponctuel (le temps de la session de terminal) :
#   source packaging/build-completion.bash
#
# Usage permanent (à chaque nouveau terminal), ajouter dans ~/.bashrc :
#   source "/chemin/complet/vers/Ludis Package Manager/packaging/build-completion.bash"

_lpm_build_sh_complete() {
  local cur
  cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=($(compgen -W "deb rpm arch all" -- "${cur}"))
}

complete -F _lpm_build_sh_complete build.sh
complete -F _lpm_build_sh_complete ./build.sh

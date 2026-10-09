# --- bash completion for packaging/build.sh ---
#
# build.sh is a project script run by relative path ("./build.sh"), not an installed command:
# unlike completions/lpm.bash (completion for "lpm", installed by install.sh/packages), this
# file is not installed anywhere and must be sourced explicitly.
#
# One-off usage (current terminal session):
#   source packaging/build-completion.bash
#
# Permanent usage (every new terminal), add to ~/.bashrc:
#   source "/full/path/to/Ludis Prefix Manager/packaging/build-completion.bash"

_lpm_build_sh_complete() {
  local cur
  cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=($(compgen -W "deb rpm arch all" -- "${cur}"))
}

complete -F _lpm_build_sh_complete build.sh
complete -F _lpm_build_sh_complete ./build.sh

#!/bin/bash

# --- Shared utility: optional sha256 integrity check of .zgp/.zgr archives ---
#
# The reference hash is a separate "sidecar" file, NEVER embedded in the archive: impossible by
# construction, since adding the hash to the archive after computing it would change its bytes and
# invalidate it (see zgp-game-packer.sh/zgr-runner-packer.sh for generation). The sidecar contains
# only the hexadecimal hash, one line -- not the classic "sha256sum -c" format that includes the file
# name: renaming the archive after download (e.g. "MyGame (1).zgp") would make the check fail wrongly
# although the archive is unchanged.
#
# Two possible sidecar locations for an archive "<dir>/<archive>":
#   1. "<dir>/hash/<archive>.sha256" -- takes priority, to keep a set of packages organized (several
#      .zgp/.zgr shared together, all hashes grouped apart).
#   2. "<dir>/<archive>.sha256" -- fallback, for simple sharing of a single file without a dedicated folder.
# If both exist, the one in hash/ wins; a disagreement between the two is not detected (edge case too
# rare to justify the complexity).

# zgu_find_hash_sidecar <archive_path>
# Prints the path of the sidecar found on stdout, nothing if absent (return code 1).
zgu_find_hash_sidecar() {
  local archive_path="$1"
  local dir base candidate
  dir="$(dirname -- "${archive_path}")"
  base="$(basename -- "${archive_path}")"

  candidate="${dir}/hash/${base}.sha256"
  if [[ -f "${candidate}" ]]; then
    echo "${candidate}"
    return 0
  fi

  candidate="${dir}/${base}.sha256"
  if [[ -f "${candidate}" ]]; then
    echo "${candidate}"
    return 0
  fi

  return 1
}

# zgu_verify_archive_hash <archive_path> <hash_file>
# Return code 0 if the hash matches, 1 otherwise. An unreadable, empty, truncated sidecar, or one not
# containing a valid sha256 hash (64 hexadecimal characters), is treated EXACTLY like a real mismatch,
# with no distinction for the caller: a broken sidecar is no more trustworthy than a mismatching hash,
# and both must trigger the same alert rather than failing silently or crashing the script.
zgu_verify_archive_hash() {
  local archive_path="$1"
  local hash_file="$2"
  local expected actual

  expected=$(tr -d '[:space:]' < "${hash_file}" 2>/dev/null)
  if [[ ! "${expected}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    return 1
  fi

  actual=$(sha256sum -- "${archive_path}" 2>/dev/null | cut -d' ' -f1)
  [[ -n "${actual}" ]] || return 1

  [[ "${actual,,}" = "${expected,,}" ]]
}

# zgu_write_hash_sidecar <archive_path> <output_dir>
# Computes the sha256 of <archive_path> (already completely written and frozen on disk -- NEVER call
# before the archive is finished, see the header) and writes the sidecar to
# "<output_dir>/hash/<basename archive_path>.sha256", creating hash/ if needed. Return code 1 if the
# computation fails (archive not found, sha256sum missing...), without ever making the caller's
# packaging fail (the archive stays valid without its sidecar).
zgu_write_hash_sidecar() {
  local archive_path="$1"
  local output_dir="$2"
  local base hash_dir hash_value

  [[ -f "${archive_path}" ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1

  base="$(basename -- "${archive_path}")"
  hash_dir="${output_dir}/hash"
  mkdir -p "${hash_dir}" || return 1

  hash_value=$(sha256sum -- "${archive_path}" 2>/dev/null | cut -d' ' -f1)
  [[ -n "${hash_value}" ]] || return 1

  echo "${hash_value}" > "${hash_dir}/${base}.sha256"
}

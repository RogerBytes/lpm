#!/bin/bash

# --- lpm self-update ---
#
# Checks whether a newer lpm version is published on GitHub and, for a package install (.deb / .rpm /
# Arch .pkg.tar.zst), downloads it, verifies its SHA-256 and installs it with privilege elevation
# (pkexec = system password dialog).
#   lpm self-update check    -> "[UPDATE-INFO] <latest version>|<release url>|<method>"
#   lpm self-update install  -> downloads, verifies, installs; "[UPDATED] <version>" on success
# Method: deb / rpm / pkg (package) or manual (install.sh, dev mode, unknown: never installed
# automatically -- lpm cannot know where or how the user installed it).
# Lines read by the GUI: "[STEP] n total label", "[PROGRESS] pct" (download).

# $1 = installed version (LPM_VERSION from bin/lpm, with or without "v"), $2 = check | install
current_version="${1#v}"
sub_arg="${2:-check}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-github-release-utils.sh
source "${script_dir}/zgu-github-release-utils.sh"

# FD 3 = real script output (for "[PROGRESS]" from a loop/pipe).
exec 3>&1

say_err() {
  zgu_log "zgc-self-update" "ERREUR" "$1"
  echo "$1" >&2
}

# Invalid argument: rejected right away, without querying GitHub.
if [[ "${sub_arg}" != "check" ]] && [[ "${sub_arg}" != "install" ]]; then
  say_err "$(t self_update.invalid_arg "${sub_arg}")"
  exit 1
fi

# "<owner>/<repo>" derived from the same constant as the runners (single place to change, see
# zgu-github-release-utils.sh).
repo_path=$(echo "${GITHUB_RELEASE_URL}" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/releases/.*|\1|')
releases_api="https://api.github.com/repos/${repo_path}/releases?per_page=20"

if ! command -v python3 >/dev/null 2>&1; then
  say_err "$(t list_remote.python_missing)"
  exit 1
fi

# Install origin, based on the owner of THIS script: only a package installed in /usr/lib/lpm is
# managed by a package manager. /usr/local/lib/lpm (install.sh), dev mode or any other location
# -> "manual".
detect_method() {
  if [[ "${script_dir}" = "/usr/lib/lpm" ]]; then
    local self="${script_dir}/zgc-self-update.sh"
    if command -v dpkg >/dev/null 2>&1 && dpkg -S "${self}" 2>/dev/null | grep -q '^lpm:'; then
      echo deb; return
    fi
    if command -v rpm >/dev/null 2>&1 && rpm -qf "${self}" >/dev/null 2>&1; then
      echo rpm; return
    fi
    if command -v pacman >/dev/null 2>&1 && pacman -Qo "${self}" >/dev/null 2>&1; then
      echo pkg; return
    fi
  fi
  echo manual
}

method=$(detect_method)

release_json=$(zgu_fetch_url "${releases_api}")
if [[ -z "${release_json}" ]]; then
  say_err "$(t self_update.fetch_failed)"
  exit 1
fi

# Latest lpm release: tag like "v0.9.4" (the special runners release "zgr-pkg", drafts and
# pre-releases are ignored), highest by version number. Output: version, page url, and the
# name/url/size/digest of the package matching the method.
release_info=$(python3 -c '
import sys, json, re
method = sys.argv[2]
suffix = {"deb": ".deb", "rpm": ".rpm", "pkg": ".pkg.tar.zst"}.get(method, "")
best = None
try:
    for rel in json.loads(sys.argv[1]):
        tag = str(rel.get("tag_name", ""))
        if rel.get("draft") or rel.get("prerelease") or not re.fullmatch(r"v?\d+(\.\d+)+", tag):
            continue
        ver = tuple(int(x) for x in tag.lstrip("v").split("."))
        if best is None or ver > best[0]:
            best = (ver, rel)
    if best:
        rel = best[1]
        name = url = size = digest = ""
        if suffix:
            for a in rel.get("assets", []):
                if a.get("name", "").endswith(suffix):
                    name, url = a["name"], a.get("browser_download_url", "")
                    size, digest = a.get("size", 0), a.get("digest") or ""
                    break
        fields = [str(rel["tag_name"]).lstrip("v"), rel.get("html_url", ""), name, url, str(size), digest]
        print("\x1f".join(fields))
except Exception:
    pass
' "${release_json}" "${method}")

if [[ -z "${release_info}" ]]; then
  say_err "$(t self_update.no_release)"
  exit 1
fi

IFS=$'\x1f' read -r latest_version release_url asset_name asset_url asset_size asset_digest <<< "${release_info}"

is_newer() {
  [[ "${latest_version}" != "${current_version}" ]] \
    && [[ "$(printf '%s\n%s\n' "${current_version}" "${latest_version}" | sort -V | tail -n1)" = "${latest_version}" ]]
}

if [[ "${sub_arg}" = "check" ]]; then
  printf '[UPDATE-INFO] %s|%s|%s\n' "${latest_version}" "${release_url}" "${method}"
  exit 0
fi

# --- install ---
if [[ "${method}" = "manual" ]]; then
  say_err "$(t self_update.manual_unsupported "${release_url}")"
  exit 1
fi

if ! is_newer; then
  echo "$(t self_update.up_to_date "${current_version}")"
  exit 0
fi

if [[ -z "${asset_url}" ]]; then
  say_err "$(t self_update.no_asset "${method}" "${latest_version}")"
  exit 1
fi

# Never install a package as root if its integrity cannot be verified.
if [[ -z "${asset_digest}" ]]; then
  say_err "$(t self_update.no_digest)"
  exit 1
fi

if ! command -v pkexec >/dev/null 2>&1; then
  say_err "$(t self_update.pkexec_missing)"
  exit 1
fi

tmp_dir=$(mktemp -d)
chmod 755 "${tmp_dir}"   # readable by the package manager run as root (sandboxed apt)
trap 'rm -rf -- "${tmp_dir}"' EXIT
pkg_file="${tmp_dir}/${asset_name##*/}"

printf '[STEP] 1 3 %s\n' "$(t self_update.step_download)"
if command -v curl >/dev/null 2>&1; then
  curl -Lfs -o "${pkg_file}" "${asset_url}" &
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "${pkg_file}" "${asset_url}" &
else
  say_err "$(t list_remote.network_tool_missing)"
  exit 1
fi
dl_pid=$!
while kill -0 "${dl_pid}" 2>/dev/null; do
  if [[ "${asset_size}" =~ ^[0-9]+$ ]] && (( asset_size > 0 )); then
    cur=$(stat -c%s "${pkg_file}" 2>/dev/null || echo 0)
    pct=$(( cur * 100 / asset_size ))
    (( pct > 100 )) && pct=100
    printf '[PROGRESS] %s\n' "${pct}" >&3
  fi
  sleep 0.3
done
if ! wait "${dl_pid}" || [[ ! -s "${pkg_file}" ]]; then
  say_err "$(t self_update.download_failed)"
  exit 1
fi

printf '[STEP] 2 3 %s\n' "$(t self_update.step_verify)"
if ! zgu_sha256_matches "${pkg_file}" "${asset_digest}"; then
  say_err "$(t self_update.checksum_invalid)"
  exit 1
fi
chmod 644 "${pkg_file}"

printf '[STEP] 3 3 %s\n' "$(t self_update.step_install)"
case "${method}" in
  deb)
    pkexec env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg_file}"
    install_rc=$?
    ;;
  rpm)
    if command -v dnf >/dev/null 2>&1; then
      pkexec dnf install -y "${pkg_file}"
    elif command -v zypper >/dev/null 2>&1; then
      pkexec zypper --non-interactive install --allow-unsigned-rpm "${pkg_file}"
    else
      pkexec rpm -U "${pkg_file}"
    fi
    install_rc=$?
    ;;
  pkg)
    pkexec pacman -U --noconfirm "${pkg_file}"
    install_rc=$?
    ;;
esac

if [[ "${install_rc}" -ne 0 ]]; then
  say_err "$(t self_update.install_failed "${install_rc}")"
  exit 1
fi

zgu_log "zgc-self-update" "OK" "ancienne=${current_version} nouvelle=${latest_version} methode=${method}"
printf '[UPDATED] %s\n' "${latest_version}"
exit 0

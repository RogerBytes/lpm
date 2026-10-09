#!/bin/bash

# --- Shared utilities for interacting with the GitHub release of the runners ---
#
# Common logic of zgc-dependency-checker.sh, zgr-runner-installer.sh and zgr-runner-remote-lister.sh:
# building the GitHub API URL from the release page URL, silently fetching a URL (curl if available,
# otherwise wget), and verifying a SHA256 digest in the "sha256:<hash>" format returned by the GitHub
# API.
#
# This file prints NOTHING (no zenity, no echo/say_err): each caller is responsible for its own error
# message and cleanup on failure (CLI and GUI modes report failures differently); only the shared
# computation logic lives here.

# URL of the GitHub release page containing the prebuilt runner packages (.zgr). SINGLE entry point:
# the only line to change to point lpm to another runner repo/release. zgc-dependency-checker.sh,
# zgr-runner-installer.sh and zgr-runner-remote-lister.sh source this file and reuse this constant.
# shellcheck disable=SC2034 # read by the scripts that source this file (e.g. zgc-dependency-checker.sh)
readonly GITHUB_RELEASE_URL="https://github.com/RogerBytes/lpm/releases/tag/zgr-pkg"

# Converts the URL of a GitHub release page (.../releases/tag/<tag>) into an API URL
# (https://api.github.com/repos/<owner>/<repo>/releases/tags/<tag>).
zgu_github_api_url() {
  local release_url="$1"
  echo "${release_url}" | sed -E 's|https?://github\.com/([^/]+)/([^/]+)/releases/tag/([^/]+)|https://api.github.com/repos/\1/\2/releases/tags/\3|'
}

# Fetches the content of a URL on stdout, silently, via curl if available otherwise wget. Returns 1 if
# neither tool is available (callers normally checked earlier; this is a safety net).
zgu_fetch_url() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    # -f: on an HTTP error (e.g. GitHub API rate limit or 404), curl fails silently (empty output,
    # non-zero return code) instead of returning the JSON error body as if it were a valid response, which
    # callers could confuse with a real "no runner available" answer and hide the network/API problem.
    curl -sf "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "${url}"
  else
    return 1
  fi
}

# Compares the SHA256 of a local file to an expected digest in the "sha256:<hash>" format (as returned
# by the "digest" field of GitHub API assets). An empty digest means GitHub provided none for this
# asset: nothing to verify, the function returns 0 (success).
# Returns 0 if the hashes match (or expected_digest is empty), 1 otherwise.
zgu_sha256_matches() {
  local archive_path="$1"
  local expected_digest="$2"

  [[ -z "${expected_digest}" ]] && return 0

  local expected_sha="${expected_digest#sha256:}"
  local actual_sha
  actual_sha=$(sha256sum "${archive_path}" 2>/dev/null | awk '{print $1}')

  [[ "${actual_sha}" = "${expected_sha}" ]]
}

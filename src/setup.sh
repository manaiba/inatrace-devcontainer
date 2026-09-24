#!/usr/bin/env bash
#
# setup.sh — clone (or fetch) every repository listed in repos.txt
#
# This script lives in the workspace directory (mounted at /src in the
# container) and clones the repos as siblings of itself, right here.
#
# Idempotent and safe to re-run:
#   * Missing repos are cloned fresh.
#   * Existing repos are `git fetch`ed only — NEVER auto-merged/pulled, so you
#     stay in control of merges.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="${SCRIPT_DIR}/repos.txt"

# Clone the repos right here, alongside this script (i.e. /src in the container).
SRC_DIR="${SCRIPT_DIR}"

if [ ! -f "${REPOS_FILE}" ]; then
  echo "ERROR: ${REPOS_FILE} not found." >&2
  exit 1
fi

mkdir -p "${SRC_DIR}"

# --- Authenticate to GitHub with the mounted token (HTTPS; no SSH keys) ---
# The token is mounted read-only at /run/secrets/gh_token. setup.sh runs at
# container-create time with NO TTY, so git must never prompt:
#   * GIT_TERMINAL_PROMPT=0   -> never ask for HTTPS username/password.
#   * GIT_SSH_COMMAND BatchMode -> never ask to confirm an SSH host key.
# We then inject config into EVERY git command via the environment (no config
# files, so it can't be defeated by a read-only/ineffective global config):
# rewrite git@github.com: -> https://github.com/ and attach the token as an
# HTTP Authorization header. The git@github.com: URLs in repos.txt keep working.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

TOKEN_PATH="/run/secrets/gh_token"
if [ -r "${TOKEN_PATH}" ] && [ -s "${TOKEN_PATH}" ]; then
  GH_PAT="$(tr -d '\r\n' < "${TOKEN_PATH}")"

  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf"
  export GIT_CONFIG_VALUE_0="git@github.com:"
  export GIT_CONFIG_KEY_1="http.https://github.com/.extraheader"
  export GIT_CONFIG_VALUE_1="Authorization: Basic $(printf 'x-access-token:%s' "${GH_PAT}" | base64 | tr -d '\n')"

  # Best-effort: also persist auth for interactive shells (gh stores the token
  # in ~/.config/gh and wires up git's credential helper). Not required for the
  # clones below, which authenticate via the header injected above.
  if printf '%s' "${GH_PAT}" | gh auth login --with-token >/dev/null 2>&1; then
    gh auth setup-git 2>/dev/null || true
    git config --global url."https://github.com/".insteadOf "git@github.com:" 2>/dev/null || true
    echo "==> [auth]    GitHub token loaded; SSH URLs rewritten to HTTPS (non-interactive)."
  else
    echo "==> [auth]    GitHub token loaded via HTTPS header (gh login skipped)." >&2
  fi
else
  echo "WARNING: GitHub token not found/readable at ${TOKEN_PATH}." >&2
  echo "         Expected host file: ~/${GH_TOKEN_FILE:-.gh_token_manaiba} (mounted read-only)." >&2
  echo "         Private clones will fail until the token is provided." >&2
fi

cloned=()
existing=()
failed=()

while IFS= read -r line || [ -n "${line}" ]; do
  # Trim surrounding whitespace.
  line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # Skip blank lines and comments.
  [ -z "${line}" ] && continue
  case "${line}" in \#*) continue ;; esac

  # Fields: <git-url> [target-dir-name]
  url="$(printf '%s' "${line}" | awk '{print $1}')"
  target="$(printf '%s' "${line}" | awk '{print $2}')"

  # Default target dir = repo name (URL basename minus trailing ".git").
  if [ -z "${target}" ]; then
    target="$(basename "${url}")"
    target="${target%.git}"
  fi

  dest="${SRC_DIR}/${target}"

  if [ -d "${dest}/.git" ]; then
    echo "==> [exists]  ${target}: fetching updates (no merge)…"
    if git -C "${dest}" fetch --all --prune; then
      existing+=("${target}")
    else
      echo "    !! fetch failed for ${target}" >&2
      failed+=("${target} (fetch)")
    fi
  elif [ -d "${dest}" ]; then
    echo "==> [skip]    ${target}: directory exists but is not a git repo." >&2
    failed+=("${target} (not a git repo)")
  else
    echo "==> [clone]   ${target}: ${url}"
    if git clone "${url}" "${dest}"; then
      cloned+=("${target}")
    else
      echo "    !! clone failed for ${target}" >&2
      failed+=("${target} (clone)")
    fi
  fi
done < "${REPOS_FILE}"

# ----------------------------- Summary -----------------------------
echo
echo "──────────────── setup summary ────────────────"
echo "Cloned fresh  : ${#cloned[@]}"
for r in "${cloned[@]:-}";   do [ -n "${r}" ] && echo "    + ${r}"; done
echo "Already there : ${#existing[@]}"
for r in "${existing[@]:-}"; do [ -n "${r}" ] && echo "    = ${r}"; done
echo "Failed        : ${#failed[@]}"
for r in "${failed[@]:-}";   do [ -n "${r}" ] && echo "    ! ${r}"; done
echo "────────────────────────────────────────────────"
echo
echo "Done. To start working:  claude   (you are already in ${SRC_DIR})"

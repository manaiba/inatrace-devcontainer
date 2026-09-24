#!/usr/bin/env bash
#
# cleanup.sh — runs on the HOST. Stops dev containers this project left behind.
#
# Every dev container ever created for this folder is labelled
# `devcontainer.local_folder=<repo root>`, whatever the devcontainer.json of
# the day looked like. The containers of the CURRENT stack carry a second
# label, `com.docker.compose.project=<name from compose.yaml>`, because they
# are created by Compose. Anything with the first label but not the second is
# therefore an instance from an older configuration — most notably the
# single-container setup that preceded the Compose migration.
#
# Those leftovers matter because they keep their published ports. A container
# still holding 5432 or 8000 makes the new stack fail to start with:
#
#   Bind for 0.0.0.0:5432 failed: port is already allocated
#
# Stopping is the default and is reversible (`docker start <name>`). Pass
# --remove to delete the containers as well; that is safe for the data this
# project cares about — /src is a host bind mount and the inatrace-* named
# volumes (Claude state, bash history, VS Code server, the nested Docker
# daemon's storage) outlive any container — but it does discard each
# container's writable layer, i.e. anything installed by hand inside it.
#
# Images and volumes are never touched.
#
#   ./cleanup.sh              stop stale containers
#   ./cleanup.sh --remove     stop AND delete them
#   ./cleanup.sh --dry-run    list what would happen, change nothing
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "${here}")"

usage() {
  cat <<'EOF'
usage: cleanup.sh [--remove] [--dry-run]

  -r, --remove    delete the stale containers after stopping them
  -n, --dry-run   only report what would be stopped/removed
  -h, --help      this message
EOF
}

remove=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--remove)  remove=1 ;;
    -n|--dry-run) dry_run=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "cleanup.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! docker info >/dev/null 2>&1; then
  echo "cleanup.sh: cannot talk to the Docker daemon — is it running?" >&2
  exit 1
fi

# The Compose project name, read from compose.yaml rather than hard-coded here,
# so renaming the stack in one place does not silently make this script treat
# the live containers as stale. `^name:` is anchored to column 0 on purpose:
# the `name:` keys under `volumes:` are indented and must not match.
project="$(awk '/^name:[[:space:]]/ { print $2; exit }' "${here}/compose.yaml")"
: "${project:=devcontainer-inatrace}"

# --- Select the leftovers -----------------------------------------------
# --filter matches the label value exactly, so a checkout of this repo at a
# different path (a git worktree, a second clone) is left alone.
mapfile -t candidates < <(
  docker ps -aq --filter "label=devcontainer.local_folder=${root}"
)

stale=()
for id in "${candidates[@]}"; do
  belongs_to="$(docker inspect "${id}" \
    --format '{{index .Config.Labels "com.docker.compose.project"}}')"
  [ "${belongs_to}" = "${project}" ] || stale+=("${id}")
done

if [ ${#stale[@]} -eq 0 ]; then
  echo "cleanup.sh: no stale dev containers for ${root}."
else
  echo "cleanup.sh: stale dev containers for ${root}:"
  for id in "${stale[@]}"; do
    # .Name carries a leading slash; PortBindings is empty for a stopped
    # container, which is exactly the state we are trying to reach.
    name="$(docker inspect "${id}" --format '{{.Name}}')"
    status="$(docker inspect "${id}" --format '{{.State.Status}}')"
    ports="$(docker inspect "${id}" \
      --format '{{range $p, $_ := .HostConfig.PortBindings}}{{$p}} {{end}}')"
    printf '  %-24s %-10s %s\n' "${name#/}" "${status}" "${ports:-(no published ports)}"
  done

  if [ "${dry_run}" -eq 1 ]; then
    echo "cleanup.sh: --dry-run, nothing stopped."
  else
    docker stop "${stale[@]}" >/dev/null
    echo "cleanup.sh: stopped ${#stale[@]} container(s)."
    if [ "${remove}" -eq 1 ]; then
      docker rm "${stale[@]}" >/dev/null
      echo "cleanup.sh: removed ${#stale[@]} container(s)."
    else
      echo "cleanup.sh: run with --remove to delete them, or restart one with" \
           "\`docker start <name>\`."
    fi
  fi
fi

# --- Warn about ports held by containers from OTHER projects ------------
# Out of scope to touch — they belong to somebody else's stack — but they
# produce the identical "port is already allocated" failure, so naming them
# here saves the next round of detective work.
mapfile -t wanted < <(
  awk '
    { sub(/#.*/, "") }                            # drop trailing comments
    /^[[:space:]]*-[[:space:]]*"[0-9][0-9.:]*"/ { # a quoted port mapping
      gsub(/[^0-9.:]/, "")
      n = split($0, f, ":")
      if (n >= 2) print f[n-1]                    # host port: second-to-last
    }
  ' "${here}/compose.yaml" | sort -un
)

mapfile -t ours < <(
  docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}'
)

conflicts=()
while IFS='|' read -r name portmap; do
  for own in ${ours[@]+"${ours[@]}"}; do
    [ "${name}" = "${own}" ] && continue 2
  done
  for port in ${wanted[@]+"${wanted[@]}"}; do
    case "${portmap}" in
      *":${port}->"*) conflicts+=("${name} holds ${port}") ;;
    esac
  done
done < <(docker ps --format '{{.Names}}|{{.Ports}}')

if [ ${#conflicts[@]} -gt 0 ]; then
  echo "cleanup.sh: WARNING — ports this stack publishes are taken by containers" \
       "from other projects:" >&2
  printf '  %s\n' "${conflicts[@]}" >&2
  echo "cleanup.sh: stop them by hand if the stack fails to start." >&2
fi

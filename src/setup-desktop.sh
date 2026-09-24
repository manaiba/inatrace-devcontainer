#!/usr/bin/env bash
#
# setup-desktop.sh — connect Claude Code to the host desktop bridges.
#
# The plumbing itself (packages, sockets, environment) is set up by the
# Dockerfile and devcontainer.json. This script only writes the configuration
# that has to live in the container's HOME, which is backed by a named volume
# and therefore survives — and shadows — image rebuilds:
#
#   1. a Playwright MCP server, so Claude can drive a real browser whose window
#      opens on YOUR screen through the host's Wayland compositor;
#   2. the onboarding flag, so a rebuild doesn't replay the setup wizard;
#   3. voice input (/voice), which records through the host's microphone.
#
# Idempotent and safe to re-run by hand:
#   ./setup-desktop.sh
#
set -euo pipefail

MCP_CONFIG="${HOME}/.config/playwright-mcp.json"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR}/settings.json"
CLAUDE_STATE="${CLAUDE_CONFIG_DIR}/.claude.json"
HEADLESS="${PLAYWRIGHT_HEADLESS:-false}"

# --- 1. Playwright MCP server -------------------------------------------------
#
# Browser flags:
#   --no-sandbox             Chrome's sandbox needs privileges the container
#                            does not have; without it the browser core-dumps.
#   --disable-dev-shm-usage  Docker's default /dev/shm is 64 MB, too small for
#                            Chromium.
#   --ozone-platform=wayland (headed only) render on the HOST's compositor via
#                            the bind-mounted Wayland socket, so you can watch
#                            Claude drive the browser. Rendering is software
#                            only — the container has no /dev/dri — and
#                            Chromium logs D-Bus/DRM errors on startup that are
#                            noise, not failures.
if [ "${HEADLESS}" = "true" ]; then
  browser_args='"--no-sandbox", "--disable-dev-shm-usage"'
else
  browser_args='"--no-sandbox", "--disable-dev-shm-usage", "--ozone-platform=wayland", "--enable-features=UseOzonePlatform"'
fi

mkdir -p "$(dirname "${MCP_CONFIG}")"
cat > "${MCP_CONFIG}" <<EOF
{
  "browser": {
    "browserName": "chromium",
    "launchOptions": {
      "headless": ${HEADLESS},
      "args": [${browser_args}]
    },
    "contextOptions": {
      "viewport": { "width": 1280, "height": 820 }
    }
  }
}
EOF

# Re-registering is fine: the old entry is dropped first, so `add` never fails
# with "already exists".
claude mcp remove -s user playwright >/dev/null 2>&1 || true
if claude mcp add -s user playwright -- playwright-mcp --config "${MCP_CONFIG}"; then
  if [ "${HEADLESS}" = "true" ]; then
    echo "==> [browser] Playwright MCP server registered (headless)."
  else
    echo "==> [browser] Playwright MCP server registered; Chromium opens on your desktop via Wayland."
  fi
else
  echo "    !! failed to register the playwright MCP server" >&2
fi

# --- 2. Onboarding flag -------------------------------------------------------
#
# Claude keeps its account identity and the "onboarding done" flag in
# .claude.json. CLAUDE_CONFIG_DIR (see the Dockerfile) puts that file on the
# inatrace-claude volume, so the LOGIN itself survives a rebuild — but a fresh
# volume, or one that predates that change, has no file at all, and Claude then
# replays the onboarding wizard on first launch. That looks exactly like being
# asked to authenticate again even though the token is sitting right there.
#
# setdefault, never overwrite: if you have already been through the wizard, this
# leaves your answers alone.
python3 - "${CLAUDE_STATE}" <<'PY'
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        state = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    state = {}

state.setdefault("hasCompletedOnboarding", True)

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
# .claude.json holds the OAuth account; keep it owner-only, as Claude writes it.
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
echo "==> [claude]  Onboarding marked complete (login persists on the inatrace-claude volume)."

# --- 3. Voice input -----------------------------------------------------------
#
# Merged into the existing settings.json rather than overwritten: that file is
# seeded by the Dockerfile but lives on the `inatrace-claude` volume, so it may
# already carry settings this script must not clobber.
mkdir -p "$(dirname "${CLAUDE_SETTINGS}")"
python3 - "${CLAUDE_SETTINGS}" <<'PY'
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        settings = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

# "hold" = hold a key to talk, release to send. Only set on first run, so a
# manual change to either field survives the next container create.
voice = settings.setdefault("voice", {})
voice.setdefault("enabled", True)
voice.setdefault("mode", "hold")

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
echo "==> [voice]   Claude voice input enabled (host microphone via PulseAudio)."

# --- 4. Sanity check ----------------------------------------------------------
# Reports what is actually reachable right now. Failures here mean the host
# sockets are not live (no desktop session, or a Wayland display other than
# wayland-0) — not that the image is wrong.
echo
echo "──────────── desktop bridges ────────────"
if pactl info >/dev/null 2>&1; then
  echo "  audio     OK  ($(pactl info | sed -n 's/^Server Name: //p'))"
else
  echo "  audio     UNAVAILABLE — check ${PULSE_SERVER:-\$PULSE_SERVER} on the host"
fi
# Probe the socket itself, not `wl-paste`: an empty clipboard makes wl-paste
# exit non-zero even when the compositor is perfectly reachable. A regular file
# here means initialize.sh wrote a placeholder because the host had no session.
if [ -S "${WAYLAND_DISPLAY:-}" ]; then
  echo "  clipboard OK  (${WAYLAND_DISPLAY})"
else
  echo "  clipboard UNAVAILABLE — ${WAYLAND_DISPLAY:-\$WAYLAND_DISPLAY} is not a live socket"
fi
echo "─────────────────────────────────────────"

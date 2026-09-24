# syntax=docker/dockerfile:1

# Debian 12 (bookworm), matching the "dossel" server.
#
# Plain Debian rather than a language base image: inatrace spans Java, Node and
# React Native, so no single runtime deserves to be the base. Each is installed
# explicitly below. (Temurin publishes no bookworm tag — only Ubuntu, Alpine and
# UBI — and every apt repo line in this file is pinned to bookworm.)
#
# This used to be python:3.12-bookworm, from when the workspace held a Django /
# geospatial stack. Nothing in inatrace is Python; a bare python3 is installed
# further down for node-gyp's benefit and nothing else.
FROM debian:bookworm

# ============================================================================
# LAYER ORDER IS DELIBERATE — least-likely-to-change first.
#
# Every layer below an edited one is rebuilt, so the blocks are ordered by how
# often they actually change in this repo's history, not by topic. The two
# expensive downloads (Chromium ~685 MB, Claude Code ~275 MB) sit near the
# bottom, and the block people edit most — the convenience CLI tools — sits
# BELOW them, after a brief switch back to root. Adding a tool to that block
# therefore costs one apt layer instead of re-downloading a gigabyte.
#
# The apt/npm caches are BuildKit cache mounts, so even an invalidated layer
# reinstalls from local .deb files instead of hitting the network. They are not
# version pins: `apt-get update` still refreshes the indexes on every run, and a
# cached .deb is only reused when its version matches what the index asks for.
#
# To deliberately pick up newer packages, bypass the layer cache:
#   devcontainer build --workspace-folder . --no-cache
# ============================================================================

# ---- Locale: UTF-8 everywhere ----
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# ---- Let apt keep its downloads, so the cache mounts below are useful ----
# The Debian images ship /etc/apt/apt.conf.d/docker-clean, which deletes every
# .deb right after installing it. With it in place a /var/cache/apt cache mount
# would always be empty.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
      > /etc/apt/apt.conf.d/keep-cache

# ---- Build toolchain ----
# The stable half of the system packages: everything the build itself needs
# (curl, git, gnupg, ca-certificates) plus build-essential, which node-gyp shells
# out to. Editing this list is rare — the convenience CLI tools live in their own
# block at the very bottom of this file, precisely so adding one does not
# rebuild from here.
#
# The GDAL/PROJ/GEOS stack that used to be here went with the Python base image:
# it served the geospatial repos of the previous workspace, and no inatrace repo
# links against any of it.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      gnupg \
      gnupg2 \
      locales \
      sudo

# ---- Non-root user `dev` with passwordless sudo ----
# Early on purpose: this never changes, and everything that runs as `dev`
# further down depends on it. It cannot go any earlier, though — /etc/sudoers.d
# is created by the `sudo` PACKAGE, so this must stay below the apt block that
# installs it. That ordering is free: both blocks are equally stable.
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# The single workspace mount lands at /src (host ./src). It holds setup.sh,
# repos.txt, CLAUDE.md and the cloned repos. Create it so the mount point exists
# and is owned by `dev`; the bind mount overlays it at runtime.
RUN mkdir -p /src && chown -R ${USERNAME}:${USERNAME} /src
WORKDIR /src

# A private XDG_RUNTIME_DIR for the container (pointed at by compose.yaml).
# Wayland clients — a headed Chromium, `wl-paste` — expect one to exist, and a
# container has no logind session to create it. libwayland insists on mode 0700
# owned by the running user. The host's Wayland socket is NOT placed here: it is
# bind-mounted at /tmp/host-wayland and referenced by absolute path instead.
RUN mkdir -p /tmp/xdg-runtime \
    && chown ${USERNAME}:${USERNAME} /tmp/xdg-runtime \
    && chmod 700 /tmp/xdg-runtime

# ---- Host desktop bridges: microphone, clipboard, headed browser ----
# The container has no /dev/snd and no display of its own. Everything below
# talks to the HOST desktop through the two sockets bind-mounted in
# compose.yaml (see "volumes" / "environment" there):
#   * microphone  -> Claude Code's /voice records via SoX's `rec` or `arecord`;
#   * clipboard   -> pasting an image into Claude shells out to `wl-paste`;
#   * headed browser -> Chromium renders on the host's Wayland compositor.
# libsox-fmt-pulse is what makes `rec` work without an ALSA card: installing
# sox alone only pulls the ALSA backend, which has no device to open here.
# libwayland-client0 is the library Chromium dlopen()s for
# `--ozone-platform=wayland`; wl-clipboard already depends on it, but it is
# load-bearing enough to name explicitly.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      sox \
      libsox-fmt-pulse \
      alsa-utils \
      libasound2-plugins \
      pulseaudio-utils \
      wl-clipboard \
      xclip \
      libwayland-client0

# Route ALSA through the PulseAudio socket: without this, `arecord` (and SoX's
# ALSA backend) fail with "cannot find card '0'", since there is no /dev/snd.
RUN printf 'pcm.!default { type pulse }\nctl.!default { type pulse }\n' > /etc/asound.conf

# ---- GitHub CLI (gh) ----
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh

# ---- MySQL client tools (mysql, mysqldump, mysqladmin…) ----
# From MySQL's own repo, not Debian: bookworm's `default-mysql-client` is
# MariaDB's, which cannot authenticate against MySQL 8.4's default
# caching_sha2_password and fails at connect time. inatrace runs MySQL 8.4, so
# the client comes from the matching 8.4 LTS channel.
#
# (This block used to install postgresql-client-18 from PGDG, for the Postgres
# service of the previous workspace. inatrace has no Postgres.)
#
# The key file is dated, and Oracle renews it IN PLACE under a new year rather
# than changing the key id: RPM-GPG-KEY-mysql-2023 expired on 2025-10-22 and
# apt then rejects the repo with "EXPKEYSIG B7B3B788A8D3785C ... is not signed".
# The -2025 file is the same key id renewed to 2027-10-23. When that lapses,
# bump to the next year's file (there is no undated "latest" URL).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 \
      | gpg --dearmor -o /usr/share/keyrings/mysql-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/mysql-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/mysql-archive-keyring.gpg] https://repo.mysql.com/apt/debian/ bookworm mysql-8.4-lts" \
      > /etc/apt/sources.list.d/mysql.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends mysql-community-client

# ---- Node 24 LTS + npm (NodeSource) ----
# Below the stable system packages because the LTS line does move (this was
# Node 20 until recently), and above Playwright, which needs npm.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs

# ---- Playwright MCP server (lets Claude drive a real browser) ----
# Installed globally as root, so the `dev` user cannot break it; the browser
# binary is downloaded later, as `dev`, into ~/.cache/ms-playwright/.
# The MCP server decides which Playwright version everything else must use — it
# resolves `playwright-core` from its own dependency tree, so a mismatched
# global playwright would download a Chromium build it then refuses to launch.
# Hence the version is read from the package instead of pinned by hand.
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD stops npm's postinstall from fetching the
# browser into /root/.cache, where the `dev` user could never reach it.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    MCP_PW_VERSION="$(npm view @playwright/mcp@latest dependencies.playwright)" \
    && echo "@playwright/mcp pins playwright ${MCP_PW_VERSION}" \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install -g \
         "playwright@${MCP_PW_VERSION}" \
         "@playwright/mcp@latest"

# ---- Playwright Chromium system dependencies ----
# `install-deps chromium` is effectively an apt-get of ~40 system libraries
# (libatk, libnss3, libgbm, fonts, …) that the Chromium build needs. Runs as
# root, and through the global playwright installed just above so the libraries
# match the exact build that will be downloaded — no second version pinned by
# hand. The Chromium *binary* is installed later, as `dev`, so it lands in that
# user's ~/.cache/ms-playwright/.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    playwright install-deps chromium

USER ${USERNAME}

# ---- Playwright Chromium browser binary ----
# ONE Chromium build, matching the globally installed Playwright that
# `@playwright/mcp` pins (see the root stage above). Must run as the `dev` user
# (NOT root): it lands in ~/.cache/ms-playwright/, which is exactly where
# Playwright looks for it at runtime.
#
# There used to be a second build here, pinned to match a repo of the previous
# workspace — but no repo in repos.txt depends on Playwright at all, so it was
# ~270 MB downloaded for nobody. The MCP server is the only consumer. If a repo
# ever does add Playwright, give it the version pinned above rather than
# reintroducing a parallel build.
#
# This fetches TWO artefacts, and both are wanted: the headed Chromium, which
# the MCP server drives on your Wayland session, and the headless shell, which
# is what `headless: true` uses. The shell is kept ON PURPOSE — it is what makes
# PLAYWRIGHT_HEADLESS="true" (see compose.yaml) work on a host with no desktop
# session, so a colleague on macOS or X11 gets a working browser out of the box.
# Dropping it is a `--no-shell` away, at the cost of that fallback.
#
# ~685 MB, and there is no cache mount for it: the browser has to end up IN the
# image, and a cache mount's contents never do. Hence its position this far
# down — only an edit above it, or to these lines, pays for it again.
RUN playwright install chromium

# ---- Shell dotfiles ----
# tmux status bar, bash-completion loader, and a HISTFILE pointing at the
# ~/.commandhistory volume so shell history survives rebuilds. `devcontainer
# exec ... bash` is a non-login interactive shell, so the completion loader is
# sourced from ~/.bashrc; bash-completion lazy-loads git's completion on demand.
# `history -a` appends after each command, so nothing is lost if the shell exits
# without writing on close.
RUN printf '# Default status bar colour\nset -g status-style bg=colour20\n' \
      > /home/${USERNAME}/.tmux.conf \
    && printf '\n# Enable bash-completion (git, etc.)\nif [ -f /usr/share/bash-completion/bash_completion ]; then\n    . /usr/share/bash-completion/bash_completion\nfi\n' \
      >> /home/${USERNAME}/.bashrc \
    && mkdir -p /home/${USERNAME}/.commandhistory \
    && printf '\n# Persist bash history to the mounted ~/.commandhistory volume\nexport HISTFILE=/home/%s/.commandhistory/.bash_history\nexport HISTSIZE=100000\nexport HISTFILESIZE=200000\nexport PROMPT_COMMAND=%s\n' \
      "${USERNAME}" "'history -a'" >> /home/${USERNAME}/.bashrc

# ---- GitHub auth via token (no SSH keys mounted) ----
# Name of the token file expected under your HOST home directory. Override at
# build time, e.g.:
#   devcontainer build --workspace-folder . --build-arg GH_TOKEN_FILE=.gh_token_work
# (also update the matching mount in compose.yaml).
ARG GH_TOKEN_FILE=.gh_token_manaiba
ENV GH_TOKEN_FILE=${GH_TOKEN_FILE}

# The host ~/.gitconfig is mounted READ-ONLY at ~/.gitconfig.host. Use a
# writable global config that includes it, so `gh auth setup-git` and the
# git@->https URL rewrite in setup.sh can be written without touching the
# read-only host file.
ENV GIT_CONFIG_GLOBAL=/home/${USERNAME}/.gitconfig.local
RUN printf '[include]\n\tpath = /home/%s/.gitconfig.host\n' "${USERNAME}" \
      > /home/${USERNAME}/.gitconfig.local

# ---- Claude Code ----
# Native installer is the CURRENT recommended method, verified against
# https://code.claude.com/docs/en/setup on 2026-06-03.
# If the native installer is ever unavailable, the npm fallback (Node 18+) is:
#   npm install -g @anthropic-ai/claude-code
#
# ~275 MB. The instruction never changes, so the layer cache holds until
# something above it moves — which is exactly why so little is left below.
RUN curl -fsSL https://claude.ai/install.sh | bash

# The native installer drops the `claude` binary in ~/.local/bin.
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# ---- Keep Claude's config inside the persisted volume ----
# By default Claude Code splits its user state in two: ~/.claude/ (settings,
# sessions, and the OAuth token in .credentials.json) and ~/.claude.json, which
# sits NEXT TO that directory and holds the account identity, the onboarding
# flag and the user-level MCP registrations. compose.yaml backs ~/.claude with a
# named volume — but not the file beside it, so every rebuild dropped
# ~/.claude.json and Claude asked you to log in again despite the token being
# right there.
#
# CLAUDE_CONFIG_DIR moves BOTH into one directory, which is already the volume.
# Verified against 2.1.220: with it set, .claude.json is created inside the
# directory rather than in $HOME.
ENV CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude

# ---- Run Claude with permissions bypassed by default ----
# Safe here because the whole environment is a sandboxed container with access
# limited to the mounted workspace. User-level settings apply to every session.
RUN mkdir -p /home/${USERNAME}/.claude \
    && printf '{\n  "permissions": {\n    "defaultMode": "bypassPermissions",\n    "skipDangerousModePermissionPrompt": true\n  }\n}\n' \
      > /home/${USERNAME}/.claude/settings.json

# ---- Convenience CLI tools (THE BLOCK YOU ARE MOST LIKELY TO EDIT) ----
# Deliberately last, after a short hop back to root. Nothing else depends on
# these, so adding one rebuilds this layer alone — instead of dragging Chromium
# (~685 MB) and Claude Code (~275 MB) along, which is what happened when `less`
# was added while this list lived at the top of the file.
#
# Add new interactive tooling HERE, not to the geospatial block above.
#
# xvfb: `playwright install-deps` does NOT install it, and MapLibre/WebGL
# rendering needs a virtual X server.
USER root
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      bash-completion \
      htop \
      jq \
      less \
      sqlite3 \
      tmux \
      tree \
      vim \
      xvfb \
      # node-gyp shells out to python3 when an npm dependency has to be built
      # from source (inatrace-mobile's `realm` carries a binding.gyp; it ships
      # prebuilds, but they are not guaranteed for every platform/version).
      # This is Debian's 3.11 and the ONLY Python left in the image.
      python3

# ---- Java 17 + Maven ----
# inatrace-backend is a Spring Boot 3.3 app with <java.version>17</java.version>
# and NO Maven wrapper (no ./mvnw), so both the JDK and `mvn` come from here.
# openjdk-17-jdk-headless is named explicitly rather than default-jdk: bookworm's
# default happens to be 17 today, and this pins it to what the pom asks for.
#
# Down here with the convenience tools, not up in the base apt block, for the
# reason this file keeps repeating: a JDK bump should rebuild one apt layer, not
# Chromium (~685 MB) and Claude Code (~275 MB) along with it.
#
# Debian's /usr/lib/jvm/default-java symlink comes from java-common, which a
# direct openjdk-17-* install does not pull in, so JAVA_HOME gets its own
# arch-agnostic symlink (the team is not all on amd64).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      openjdk-17-jdk-headless \
    && ln -sfn "/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)" \
         /usr/lib/jvm/default-java
ENV JAVA_HOME=/usr/lib/jvm/default-java

# Maven from Apache's binary tarball, NOT `apt-get install maven`: Debian ships
# 3.8.7, and the tarball pins an exact version so every developer's build is
# identical. It is just a directory of jars plus a launcher script.
ARG MAVEN_VERSION=3.9.9
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      -o /tmp/maven.tar.gz \
    && mkdir -p /opt/maven \
    && tar -xzf /tmp/maven.tar.gz -C /opt/maven --strip-components=1 \
    && rm /tmp/maven.tar.gz \
    && ln -sfn /opt/maven/bin/mvn /usr/local/bin/mvn

# ---- Docker engine, for docker-IN-docker ----
# A full daemon inside the dev container, NOT the host socket bind-mounted in.
# The difference matters for how this workspace is used: services are started
# with plain `docker run -p 3306:3306 ...` and then reached on localhost by an
# app running in this same container. Nested containers publish their ports on
# the dev container's own network namespace, so that just works; sibling
# containers on the host daemon would not be on localhost at all.
#
# Requires `privileged: true` and a named volume for /var/lib/docker — both in
# compose.yaml. The volume is not optional: /var/lib/docker on the container's
# own overlayfs cannot host the overlay2 storage driver.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         docker-ce \
         docker-ce-cli \
         containerd.io \
         docker-buildx-plugin \
         docker-compose-plugin \
    && usermod -aG docker ${USERNAME}

# dockerd is started by this script, wired up as the container's entrypoint in
# compose.yaml. It runs as `dev` (the image's USER), so the daemon itself is
# raised through the passwordless sudo configured above, then the script execs
# the compose `command` (sleep infinity) so PID 1 stays put.
#
# The socket check makes it idempotent, and the wait loop means the first
# `docker` command after an attach does not race the daemon's startup.
RUN cat > /usr/local/share/docker-init.sh <<'EOS'
#!/usr/bin/env bash
set -e

if [ ! -S /var/run/docker.sock ]; then
  sudo sh -c 'dockerd > /var/log/dockerd.log 2>&1 &'
  for _ in $(seq 1 30); do
    docker info > /dev/null 2>&1 && break
    sleep 1
  done
  docker info > /dev/null 2>&1 || echo "docker-init: dockerd did not come up - see /var/log/dockerd.log" >&2
fi

exec "$@"
EOS
RUN chmod +x /usr/local/share/docker-init.sh

USER ${USERNAME}

# ---- Mount point for the persisted VS Code server volume ----
# compose.yaml backs /home/dev/.vscode-server with a named volume so extensions
# installed by hand survive a rebuild. The directory has to EXIST in the image,
# owned by `dev`: Docker seeds a fresh named volume from the image path, and
# copies its ownership with it. Without this line the volume would be created
# empty and root-owned, and the VS Code server — which runs as `dev` — could not
# write its extensions into it.
#
# Last in the file on purpose: it is the cheapest possible layer, and putting it
# next to the other ~/ setup up top would rebuild Claude Code (~275 MB) below it.
RUN mkdir -p /home/${USERNAME}/.vscode-server

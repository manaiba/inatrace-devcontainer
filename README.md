# INATrace dev container

A shared [Dev Container](https://containers.dev/) for working on
[**INATrace**](https://github.com/agstack/inatrace): the open-source traceability
system for agricultural supply chains, part of the
[AgStack Foundation](https://github.com/agstack). INATrace gives cooperatives an
internal management system and a digital record of the supply chain, from farmer
and plot data to processing, orders and payments. It also supports compliance
with regulations like the EU Deforestation Regulation (EUDR).

INATrace is split across several repositories, and each one needs a different
toolchain: Java and Maven for the backend, Angular for the web app, Expo and
React Native for the mobile app, and a MySQL database underneath. This workspace
clones them side by side into one container that has all of those tools
installed, so everyone gets the same JDK, Maven, Node, Docker, MySQL client and
GitHub CLI. Onboarding becomes "open the folder, build the container."

## The repositories

`src/setup.sh` clones every repo listed in `src/repos.txt` into `src/`, which is
mounted at `/src` in the container:

| Repo | What it is | Stack |
|------|------------|-------|
| [`inatrace-backend`](https://github.com/agstack/inatrace-backend) | REST API, business logic, persistence. Serves every endpoint under `/api` and holds the technical documentation (`TECHNICAL_DOCUMENTATION.md`) | Java 17 · Spring Boot 3.3 · Maven · MySQL 8.4 |
| [`inatrace-frontend`](https://github.com/agstack/inatrace-frontend) | The web application used by cooperatives, companies and admins | Angular 10 · TypeScript |
| [`inatrace-mobile`](https://github.com/agstack/inatrace-mobile) | Field app for farmer profiles and GPS plot mapping, with offline collection and sync | Expo 53 · React Native 0.79 · Realm |
| [`inatrace`](https://github.com/agstack/inatrace) | Meta repository: project overview, governance, cross-repo specs such as the Asset Registry integration | Markdown |

The URLs in `repos.txt` point at the **upstream `agstack`** repos, so `origin`
is upstream. Work happens on the **`manaiba` forks**, and `setup.sh` does not add
them. After a fresh clone, add the fork where you need it:

```bash
git -C /src/inatrace-backend remote add manaiba git@github.com:manaiba/inatrace-backend.git
```

INATrace also has a fifth component, the Hyperledger Fabric
[coffee network](https://github.com/agstack/inatrace-coffee-network). It is not
in `repos.txt`, and nothing below needs it.

### How the pieces talk to each other

```
 browser ──► inatrace-frontend (ng serve, :4200)
                 │  proxies /api  (proxy.INATrace-local.conf.json)
                 ▼
             inatrace-backend (Spring Boot, :8080) ◄── inatrace-mobile (Expo, :9081)
                 │                                     EXPO_PUBLIC_API_URI
                 ▼
             MySQL 8.4 (:3306, nested container)
```

The backend creates its tables and seeds starter data on first startup, so an
empty `inatrace` database is all it needs.

## Quick start

1. Complete the [prerequisites](#prerequisites), including the
   [GitHub token](#github-authentication).
2. Open the workspace. In VS Code, use **Dev Containers: Reopen in Container**.
   From a terminal:
   ```bash
   devcontainer up --workspace-folder .
   devcontainer exec --workspace-folder . bash    # lands in /src
   ```
   The first create clones all four repos.
3. Start MySQL, then the backend, then the frontend, following each repo's
   README (see [Running INATrace](#running-inatrace)).
4. On the host, open <http://127.0.0.1:9080> for the web app and
   <http://127.0.0.1:9000/swagger-ui.html> for the API.

## Running INATrace

Each repo's own README covers how to run it:

- [`inatrace-backend`](https://github.com/agstack/inatrace-backend#readme)
- [`inatrace-frontend`](https://github.com/agstack/inatrace-frontend#readme)
- [`inatrace-mobile`](https://github.com/agstack/inatrace-mobile#readme)

## Ports

Ports are published by `.devcontainer/compose.yaml`, so they work with the
`devcontainer` CLI and plain Docker as well as with VS Code:

| Host | Container | Service |
|------|-----------|---------|
| 9000 | 8080 | `inatrace-backend` (Spring Boot) |
| 9080 | 4200 | `inatrace-frontend` (`ng serve`) |
| 9081 | 9081 | `inatrace-mobile` (Expo Metro) |

MySQL (3306) and MailHog (1025/8025) are not published to the host. They are
reachable from inside the container only.

- **Bind to `0.0.0.0`.** A server that listens on `127.0.0.1` inside the
  container cannot be reached through the published port. The frontend's
  `npm run dev` already binds `0.0.0.0`.
- **Publishing happens at container create time.** After changing ports,
  recreate the container with `--remove-existing-container`.
- **Use `127.0.0.1` on the host, not `localhost`, with Podman.** Rootless Podman
  publishes ports on IPv4 only, but `localhost` often resolves to IPv6 `::1`
  first, and that connection is reset.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/), running and usable without
  `sudo` (`docker ps` works).
- The **VS Code Dev Containers extension**, or the **Dev Containers CLI**:
  ```bash
  npm install -g @devcontainers/cli
  ```
- A **GitHub token** saved on the host (default `~/.gh_token_manaiba`). See
  [GitHub authentication](#github-authentication). No SSH keys are mounted into
  the container.
- Optional, for [desktop bridges](#desktop-bridges): a **Linux host with a
  Wayland session** and PipeWire/PulseAudio. Without one the container still
  works, but it has no microphone, clipboard or visible browser.

## GitHub authentication

Cloning uses a **GitHub token** instead of SSH keys, so a single, narrowly scoped
credential enters the container and your `~/.ssh` keyring stays on the host.

**1. Generate the token.** Create a **fine-grained personal access token** at
<https://github.com/settings/personal-access-tokens>:

- **Resource owner:** `manaiba`, the org that holds the forks.
- **Repository access:** *Only select repositories*, then pick the INATrace forks.
- **Repository permissions:** **Contents: Read-only** (clone and fetch) and
  **Metadata: Read-only** (mandatory). Leave everything else at *No access*.

> With read-only `Contents` the container can clone and fetch but cannot push.
> To push to the forks from inside the container, grant **Contents: Read and
> write** instead. The upstream `agstack` repos are public, so they clone either
> way.

**2. Save it on the host:**

```bash
printf '%s\n' 'github_pat_xxx' > ~/.gh_token_manaiba
chmod 600 ~/.gh_token_manaiba
```

The token is mounted read-only at `/run/secrets/gh_token`. `setup.sh` logs `gh`
in with it and rewrites `git@github.com:` URLs to authenticated HTTPS, so
SSH-style URLs work without SSH keys.

To use a different filename, change it in **both** places in
`.devcontainer/compose.yaml`: the `GH_TOKEN_FILE` build arg and the gh-token
entry under the `app` service's `volumes:`.

`initialize.sh` creates an empty token file if none exists, so Docker does not
replace it with a root-owned directory. An empty file still means no
authentication, and `setup.sh` warns about it.

## What's in the image

- **JDK 17** + **Maven 3.9.9**, which is what `inatrace-backend`'s `pom.xml`
  requires
- **Node 24 LTS** + npm, for `inatrace-frontend` and `inatrace-mobile` (the
  frontend's README asks for Node 14; see [TODO](#todo))
- **Docker engine**: a full daemon inside the container (see
  [Docker-in-Docker](#docker-in-docker))
- **MySQL 8.4 client**
- **Git**, **GitHub CLI (`gh`)**, tmux, vim, htop, tree, jq, build tools, and
  `python3` so node-gyp can build native npm modules
- **Playwright** + Chromium, wired to Claude as an MCP server
- **Claude Code**, preinstalled (see [Claude Code](#claude-code))

## Workspace layout

```
.devcontainer/        container definition; stays on the host, never mounted
├── compose.yaml      the single-service stack: `app`
├── Dockerfile        the toolchain image
├── devcontainer.json
├── initialize.sh     runs on the HOST before the stack is created
└── cleanup.sh        stops dev containers left behind by older configurations
README.md             this file
src/                  mounted at /src in the container
├── repos.txt         the INATrace repos to clone
├── setup.sh          clones missing repos, fetches existing ones
├── setup-desktop.sh  wires Claude to the host browser, mic and clipboard
├── CLAUDE.md         workspace rules for Claude Code
└── inatrace*/        the cloned repos, each its own git repo (git-ignored)
```

`src/` is the only directory mounted into the container. `.devcontainer/` is
build-time input only.

Re-running `setup.sh` is safe. It clones missing repos and only `git fetch`es
existing ones. It never merges or pulls, so your branches stay as you left them.
To add a repo, append its URL to `repos.txt`, optionally followed by a target
folder name.

## Claude Code

Claude Code is preinstalled. It runs in `/src`, so it can see all four repos at
once:

```bash
claude
```

[`src/CLAUDE.md`](src/CLAUDE.md) sets the workspace rules: each repo is
independent, commits never span repos, and each repo's own `CLAUDE.md` takes
precedence.

## Container internals

### Docker-in-Docker

The `app` container runs a **Docker daemon of its own** instead of mounting the
host's socket. Services started with `docker run -p …` publish into the dev
container's own network namespace, so the backend reaches MySQL at
`localhost:3306` exactly as its default configuration expects. Containers on the
host daemon would be siblings, not on `localhost`.

This costs `privileged: true` in `compose.yaml`, plus the `inatrace-docker`
volume for `/var/lib/docker`. The nested daemon has its **own image store**:
images pulled on the host are not visible inside, and images pulled inside are
not visible on the host.

### What survives a rebuild

| Volume | Mounted at | Holds |
|--------|-----------|-------|
| `inatrace-claude` | `/home/dev/.claude` | Claude Code settings, sessions and login |
| `inatrace-bash-history` | `/home/dev/.commandhistory` | shell history |
| `inatrace-vscode-server` | `/home/dev/.vscode-server` | VS Code server and hand-installed extensions |
| `inatrace-docker` | `/var/lib/docker` | nested Docker images, containers and volumes, including MySQL's data |

A fresh volume is seeded from the image once. After that the volume's copy wins,
which is why `setup-desktop.sh` merges into Claude's `settings.json` instead of
overwriting it. `CLAUDE_CONFIG_DIR` points into the volume, so Claude stays
logged in across rebuilds.

### Image build cache

The Dockerfile is ordered **least likely to change first**. The big downloads,
Chromium (about 685 MB) and Claude Code (about 275 MB), sit near the bottom, and
the frequently edited blocks sit below them: CLI tools, the JDK, Maven and
Docker. **Add new tools to the last apt block**, not the build-toolchain block at
the top. Apt and npm downloads use BuildKit cache mounts.

```bash
devcontainer up --workspace-folder . --remove-existing-container   # after editing the Dockerfile
devcontainer build --workspace-folder . --no-cache                 # pick up newer packages
```

Oracle's MySQL signing key has a year-stamped filename and expires. The
Dockerfile uses `RPM-GPG-KEY-mysql-2025`, which is valid until 2027-10-23. Once
it expires, the image fails to build with `EXPKEYSIG`. Switch to the next year's
file then.

### Stale containers

The stack is named `devcontainer-inatrace`. A container from an older
configuration of this folder can still hold the published ports, and the new
stack then fails with `port is already allocated`. Run
`.devcontainer/cleanup.sh` on the host to stop those leftovers. Add `--dry-run`
to only list them, or `--remove` to delete them too.

## Desktop bridges

On a Linux/Wayland host, two sockets from your desktop session are mounted into
the container:

- **A browser window on your screen.** Claude drives Chromium through the
  Playwright MCP server, and the window opens on your desktop so you can watch
  it test the INATrace web app.
- **Pasting images into Claude.** The clipboard is read with `wl-paste`.
- **Voice input (`/voice`)** through your host microphone.

| What | How |
|------|-----|
| Audio | `$XDG_RUNTIME_DIR/pulse/native` → `/tmp/host-pulse` (`PULSE_SERVER`) |
| Clipboard + browser | `$XDG_RUNTIME_DIR/wayland-0` → `/tmp/host-wayland` (`WAYLAND_DISPLAY`) |
| Runtime dir | `/tmp/xdg-runtime`, created by the Dockerfile |

`initialize.sh` makes sure both sockets exist before the container is created.
`setup-desktop.sh` registers the MCP server and reports which bridges are live.
You can re-run it at any time.

To troubleshoot, from inside the container:

```bash
pactl info                   # should report the host's PipeWire/Pulse server
wl-paste --list-types        # after copying an image, should list image/png
```

- **Wayland display other than `wayland-0`:** change the name in both
  `compose.yaml` and `initialize.sh`.
- **X11, macOS or a headless host:** the container starts without the bridges.
  Set `PLAYWRIGHT_HEADLESS: "true"` in `compose.yaml` for a headless browser.
- **VS Code voice:** the Claude Code *extension* cannot dictate in a Dev
  Container. The bridge works for the CLI running inside the container.

## TODO

- [ ] Provide Node 14 for `inatrace-frontend` (Angular 10) next to Node 24, and
      confirm `ng serve` and `ng build` work in the image.
- [ ] Persist `~/.m2` and the npm cache so an image rebuild does not
      re-download every dependency.
- [ ] Decide whether MySQL (and MailHog) should be `compose.yaml` services
      instead of nested `docker run` commands.
- [ ] Android SDK / Expo tooling for `inatrace-mobile`. So far only the Metro
      port is wired up.

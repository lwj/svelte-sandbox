# svelte-sandbox

Run [Claude Code](https://claude.com/claude-code) against a SvelteKit project inside a disposable Docker container — pre-wired with the [Svelte MCP server](https://svelte.dev/docs/mcp/overview), with your host Claude Code setup (skills, MCP servers, statusline, auth) mirrored in **read-only**.

The idea: let the agent work with relaxed permissions without giving it your machine. The only host location it can write to is the project folder you point it at.

## What you get

- **One command** that builds the image (first run), scaffolds a fresh SvelteKit app via `sv create` (or picks up an existing one), registers the Svelte MCP with Claude Code, makes an initial git checkpoint, and drops you into a `claude` session.
- **Your config, not a blank slate.** `~/.claude` and `~/.claude.json` are mounted read-only and selectively copied into the container, so your skills, agents, MCP servers, settings, and auth come along — but nothing inside the container can modify the originals. Heavy host-specific state (session transcripts, file history) is skipped; the container keeps its own history in a persistent volume, so previous sandbox sessions stay resumable.
- **A real sandbox posture.** The container runs as the unprivileged `node` user with all capabilities dropped (except the four needed to fix volume ownership at startup, after which it de-escalates via `gosu`).
- **Clean dependency isolation.** `node_modules` lives in a per-project named Docker volume, so the container keeps Linux-native modules instead of fighting your host's over the bind mount.
- **Headless Chromium baked in.** The agent can take screenshots and run browser automation out of the box — Debian's `chromium` works on amd64 and arm64, and puppeteer is pointed at it (`PUPPETEER_EXECUTABLE_PATH`) so nothing tries to download an x64-only browser at runtime.

## Requirements

- Docker (Desktop on macOS, Engine on Linux)
- bash

## Quick start

```sh
git clone https://github.com/lwj/svelte-sandbox.git && cd svelte-sandbox
./svelte-sandbox
```

First run builds the image, then scaffolds a SvelteKit project into `./svelte-app` — answer the `sv create` prompts however you like (the dependency install happens once, during MCP setup, with the package manager you choose there). After that you're in Claude Code, inside the container, with the Svelte MCP available.

Tip: put the script on your `PATH` with a symlink and run it from anywhere — the script resolves the symlink back to the repo when it needs the Dockerfile. Pick any directory that's already on your `PATH`, or set one up:

```sh
mkdir -p ~/.local/bin
ln -s "$PWD/svelte-sandbox" ~/.local/bin/
# if ~/.local/bin isn't on your PATH yet (echo $PATH to check):
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc   # or ~/.bashrc — pick up the PATH change in the current shell
```

Symlink rather than copy: a copied script can run an already-built image, but `--build` needs the repo next to it.

### Logging in (macOS especially)

Your host auth is mirrored into the container along with the rest of your config. On Linux that usually means the sandbox is logged in from the first run. On **macOS**, Claude Code stores credentials in the Keychain rather than in `~/.claude`, so the mirror can't carry them — run `/login` once inside the sandbox. The login is saved to the persistent `svelte-sandbox-claude` volume, so every run after that is logged in automatically.

## Usage

```
svelte-sandbox [options] [project-path] [-- claude-args...]
```

| Option | Effect |
| --- | --- |
| `--remote` | Use the hosted Svelte MCP (`mcp.svelte.dev`) instead of running it locally via `npx @sveltejs/mcp`. |
| `--build` | (Re)build the Docker image before running — also fetches the latest Claude Code and `sv` releases. |
| `--port N` | Publish container port `N` on `127.0.0.1:N` for the dev server (default: `5173`). `--port none` publishes nothing. |
| `--clean` | Remove the `node_modules` volume for `[project-path]` and exit. |
| `-h`, `--help` | Show help. |

`project-path` defaults to `./svelte-app` (relative to your current directory). If the directory already contains a `package.json`, it's treated as an existing project: no scaffolding, just MCP setup if it's missing.

Anything unrecognised — and everything after `--` — is forwarded to `claude` inside the container:

```sh
# Fresh app in ./svelte-app, default settings
svelte-sandbox

# Existing project, hosted MCP, skip permission prompts inside the sandbox
svelte-sandbox --remote ~/code/my-app -- --dangerously-skip-permissions

# Pick a model
svelte-sandbox ./my-app -- --model opus

# Dev server on a different port; clean a project's dependency volume
svelte-sandbox --port 3000
svelte-sandbox --clean ./my-app
```

### Viewing the dev server

Port 5173 (or your `--port` choice) is published to `127.0.0.1` on the host — loopback only, not your LAN. Vite binds container-localhost by default, which isn't reachable across the container boundary, so the dev server has to be started with `--host`.

Since you land directly in Claude Code, the agent handles this: the entrypoint appends a note to the container-side user-level `CLAUDE.md` telling it to start the dev server with `--host --port <N>`. Just ask Claude to run the dev server, then open `http://localhost:5173` in your host browser. (If you do run it by hand — e.g. via Claude's `!` shell mode — remember the `--host` yourself: `npm run dev -- --host`.)

## How it works

The host-side script builds the image if needed, assembles the mounts below, and starts the container. Inside, the entrypoint briefly runs as root to fix volume ownership, drops to the unprivileged `node` user, mirrors your host Claude config in, scaffolds or detects the project, ensures the Svelte MCP is registered, and finally launches `claude`.

### Mounts

| Mount | Type | Purpose |
| --- | --- | --- |
| `<project-path>` → same path in container | bind, rw | Your project. The path is identical inside and out, so file references stay valid. |
| `~/.claude` → `/host-claude` | bind, **ro** | Host config source; selectively copied into the container's `~/.claude` at startup (skills, agents, commands, settings, credentials — not transcripts/file history). |
| `~/.claude.json` → `/host-claude.json` | bind, **ro** | Same, for the top-level config file. |
| `svelte-sandbox-claude` → `/home/node/.claude` | named volume | Persists container-side Claude state across runs (e.g. a `claude` login done inside the sandbox). |
| `svelte-sandbox-nm-<hash>` → `<project>/node_modules` | named volume | Per-project Linux-native dependencies, keyed by project path. |

### The Svelte MCP

By default the MCP runs **locally** inside the container (`npx -y @sveltejs/mcp`). With `--remote` it points Claude Code at the hosted server at `mcp.svelte.dev` instead. Registration is written to the project's `.mcp.json` (project scope), so it travels with the repo. If `sv add mcp` doesn't register it for any reason, the entrypoint falls back to `claude mcp add` directly.

## Security model — read this

This sandbox protects your **filesystem**, not your secrets or your network:

- The container can write only to the project directory you mounted (plus its own volumes). Your host `~/.claude` config cannot be modified from inside.
- **But your auth is mirrored in.** Your Claude credentials are copied *into* the container so the session works without re-login, and the container has unrestricted network access. An agent running with `--dangerously-skip-permissions` could, in principle, use or leak those credentials. Don't point it at untrusted prompts/repos and assume the sandbox makes that safe.
- The published dev-server port binds `127.0.0.1` only, so nothing in the sandbox is exposed to your LAN.
- The project directory is read-write by design — the agent can change anything in it. The initial git checkpoint (on fresh scaffolds) gives you a clean diff/rollback point.

## Updating, resetting, cleaning up

```sh
# Get the latest Claude Code + sv inside the image
svelte-sandbox --build

# Remove a project's node_modules volume (fresh install next run)
svelte-sandbox --clean ./my-app

# Reset container-side Claude state (forces fresh login/config next run)
docker volume rm svelte-sandbox-claude

# List any leftover per-project node_modules volumes
docker volume ls --filter name=svelte-sandbox-nm-

# Remove the image entirely
docker rmi svelte-sandbox:latest
```

## Known limitations

- **macOS needs one login.** Keychain-stored credentials can't be mirrored — see [Logging in](#logging-in-macos-especially). After the first `/login` inside the sandbox you're set.
- **Host config wins on every start.** Mirrored items (settings, skills, agents, credentials) are re-copied at each launch, so changes made to those *inside* the container are overwritten by the host versions next run. Container-only state — session history, transcripts, an in-container login — lives in the persistent volume and survives.
- **The dev server needs `--host`.** The port is published, but Vite binds container-localhost by default. The agent is instructed (via the container-side `CLAUDE.md`) to start it correctly; only manual runs need you to remember `--host`.
- **Claude asks to approve the Svelte MCP server on every run.** The approval is stored in `~/.claude.json`, which is ephemeral inside the container, so it can't stick. It's one keypress, and it's left in place deliberately — an explicit consent step before enabling a project-scoped MCP server.
- **Linux UID mismatch.** Files the container writes to the project bind mount are owned by uid 1000 (`node`). On Docker Desktop for macOS this is transparent; on Linux it only lines up if your user is uid 1000.

## Files

- [`svelte-sandbox`](./svelte-sandbox) — host-side wrapper: builds the image, assembles mounts, runs the container.
- [`Dockerfile`](./Dockerfile) — `node:22-bookworm-slim` + git + Chromium + Claude Code + `sv` + pnpm (via corepack).
- [`entrypoint.sh`](./entrypoint.sh) — runs in-container: drops privileges, mirrors config, scaffolds/detects the project, ensures the MCP, launches `claude`.

## License

[MIT](./LICENSE)

#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/workspace}"
MCP_MODE="${MCP_MODE:-local}"

# Started as root: fix ownership of the node_modules volume (named volumes mount
# in root-owned), then drop to the unprivileged node user for everything else.
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$PROJECT_DIR/node_modules"
  chown node:node "$PROJECT_DIR/node_modules" || true
  exec gosu node "$0" "$@"
fi

export HOME=/home/node
cd "$PROJECT_DIR"

# --- Mirror host Claude Code config into the container ----------------------
# Sources are mounted read-only, so nothing here can alter your host config.
# Heavy, host-specific state (session transcripts, file history, ...) is
# skipped: it is slow to copy and references host sessions. The container's
# own history lives in the persistent ~/.claude volume and is never deleted
# here, so transcripts from previous sandbox runs stay resumable.
if [ -d /host-claude ]; then
  echo "==> Mirroring host Claude Code config (skills, statusline, MCPs, auth)"
  mkdir -p "$HOME/.claude"
  shopt -s dotglob nullglob
  for src in /host-claude/*; do
    case "$(basename "$src")" in
      projects|file-history|todos|shell-snapshots|statsig|debug|downloads) continue ;;
    esac
    cp -a "$src" "$HOME/.claude/" 2>/dev/null || true
  done
  shopt -u dotglob nullglob
fi
if [ -f /host-claude.json ]; then
  cp -a /host-claude.json "$HOME/.claude.json" 2>/dev/null || true
fi

# --- Dev-server guidance for the agent ---------------------------------------
# The user lands straight in claude, not a shell, so the instruction to bind
# the dev server on all interfaces goes to the agent via the user-level
# CLAUDE.md (container-side only — the host's copy is never touched). The
# mirror above re-copies any host CLAUDE.md each start, so re-append unless
# the marker is already present.
if [ -n "${DEV_PORT:-}" ] && ! grep -qs 'svelte-sandbox:dev-server' "$HOME/.claude/CLAUDE.md"; then
  mkdir -p "$HOME/.claude"
  cat >> "$HOME/.claude/CLAUDE.md" <<EOF

<!-- svelte-sandbox:dev-server -->
# Sandbox environment

You are running inside the svelte-sandbox Docker container. Only port $DEV_PORT
is published to the user's host machine (as 127.0.0.1:$DEV_PORT). When starting
the dev server, bind all interfaces and use that port:

    npm run dev -- --host --port $DEV_PORT

Then tell the user to open http://localhost:$DEV_PORT in their browser. Other
ports are not reachable from the host.
EOF
fi

# --- Svelte MCP helpers ------------------------------------------------------
has_svelte_mcp() {
  if claude mcp list 2>/dev/null | grep -qi svelte; then
    return 0
  fi
  [ -f "$PROJECT_DIR/.mcp.json" ] && grep -qi svelte "$PROJECT_DIR/.mcp.json"
}

register_mcp_with_claude() {
  if [ "$MCP_MODE" = "remote" ]; then
    claude mcp add -t http -s project svelte https://mcp.svelte.dev/mcp \
      || echo "!! couldn't register remote MCP — is mcp.svelte.dev reachable?"
  else
    claude mcp add svelte -s project -- npx -y @sveltejs/mcp \
      || echo "!! couldn't register local MCP"
  fi
}

# $1: "install" (new projects — the one deferred install, prompting for the
# package manager) or "no-install" (existing projects — config only).
ensure_svelte_mcp() {
  local install_mode="${1:-no-install}"
  if has_svelte_mcp; then
    echo "==> Svelte MCP already configured — nothing to do."
    return 0
  fi
  # ide:claude-code + setup:<mode> pre-answer sv add mcp's own two prompts.
  local spec="mcp=ide:claude-code+setup:${MCP_MODE}"
  echo "==> Adding the Svelte MCP (sv add $spec)"
  if [ "$install_mode" = "install" ]; then
    sv add "$spec" || echo "!! sv add mcp didn't finish cleanly — continuing"
  else
    sv add "$spec" --no-install || echo "!! sv add mcp didn't finish cleanly — continuing"
  fi
  if has_svelte_mcp; then
    echo "==> Svelte MCP registered by sv add mcp."
  else
    echo "==> Registering Svelte MCP with Claude Code (mode: $MCP_MODE)"
    register_mcp_with_claude
  fi
}

# --- New vs existing project -------------------------------------------------
if [ -f "$PROJECT_DIR/package.json" ]; then
  echo "==> Existing project detected in $PROJECT_DIR."
  ensure_svelte_mcp no-install
else
  echo "==> Creating a SvelteKit project. Answer the prompts however you like."
  # The node_modules volume mounts inside the project dir, so sv create would
  # see a non-empty target and prompt "Directory not empty. Continue?".
  # Scaffold into a not-yet-existing temp subdir (sv skips the check entirely
  # when the target doesn't exist), then copy the result in.
  scaffold_root="$(mktemp -d)"
  scaffold="$scaffold_root/app"
  sv create "$scaffold" --no-install
  cp -a "$scaffold"/. "$PROJECT_DIR"/
  rm -rf "$scaffold_root"
  # The one and only dependency install happens here, during sv add mcp, with
  # the package manager chosen at its prompt.
  ensure_svelte_mcp install
  echo "==> Creating an initial git checkpoint"
  if [ ! -d "$PROJECT_DIR/.git" ]; then
    git init -q
    git config user.email "sandbox@local" || true
    git config user.name  "svelte-sandbox" || true
    git add -A
    git commit -qm "chore: scaffold SvelteKit project with Svelte MCP" || true
  fi
fi

if [ -n "${DEV_PORT:-}" ]; then
  echo "==> Dev server: ask Claude to start it (it has been told to use --host)."
  echo "    Then open http://localhost:$DEV_PORT on your host."
fi

echo "==> Launching: $*"
exec "$@"

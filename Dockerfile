# Svelte AI sandbox — Claude Code + SvelteKit, pre-wired with the Svelte MCP.
FROM node:22-bookworm-slim

# Base tooling: git, curl/ca-certificates (installs), gosu (drop root -> node).
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates gosu \
 && rm -rf /var/lib/apt/lists/*

# Headless Chromium for screenshots/browser automation inside the sandbox.
# Debian's package works on amd64 and arm64 (puppeteer's own download is
# x64-only), so puppeteer/co are pointed at it instead of downloading one.
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium fonts-liberation \
 && rm -rf /var/lib/apt/lists/*
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium

# Install Claude Code and the Svelte CLI. CACHEBUST (set per build by the run
# wrapper) forces this layer to re-run, so --build fetches the latest versions.
ARG CACHEBUST=0
RUN echo "build: $CACHEBUST" \
 && npm install -g @anthropic-ai/claude-code sv \
 && corepack enable && corepack prepare pnpm@latest --activate

# Writable Claude config home for the node user (persisted via a volume).
RUN mkdir -p /home/node/.claude && chown node:node /home/node/.claude

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Start as root so the entrypoint can fix volume ownership, then it drops to node.
WORKDIR /
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
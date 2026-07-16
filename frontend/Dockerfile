# Multi-stage Dockerfile — frontend (Nuxt 4 SSR)
#
# Stage 1: Build — Bun 1.3 installs dependencies and runs nuxt build
# Stage 2: Runtime — Node 24 LTS serves the Nitro node-server output
#
# Per D17 (non-root, healthchecked, small final image) and D18 (Bun build → Node SSR).

# ─── Stage 1: Build ──────────────────────────────────────────────────────────
FROM oven/bun:1.3 AS builder

WORKDIR /app

# Copy dependency manifests first for layer caching
COPY package.json bun.lock ./

# Install all dependencies (including devDependencies for build)
RUN bun install --frozen-lockfile

# Copy source
COPY . .

# Build the Nuxt SSR app (Nitro preset: node-server)
RUN bun run build

# ─── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM node:24-slim AS runtime

WORKDIR /app

# Create a non-root user
RUN addgroup --system --gid 1001 nuxtgroup \
  && adduser --system --uid 1001 --ingroup nuxtgroup nuxtuser

# Copy only the Nitro server output from the builder
COPY --from=builder --chown=nuxtuser:nuxtgroup /app/.output ./

# Switch to non-root
USER nuxtuser

EXPOSE 3000

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=3000

# Health check against the Nuxt health page
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD node -e "const h = require('http'); h.get('http://localhost:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "server/index.mjs"]

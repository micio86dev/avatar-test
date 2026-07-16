# Multi-stage Dockerfile — backoffice (Nuxt 4 SPA)
#
# Stage 1: Build — Bun 1.3 installs dependencies and runs nuxt generate (static SPA)
# Stage 2: Runtime — nginx:1.27-alpine serves the static output (non-root)
#
# Per D17 (non-root, healthchecked, small final image) and D18 (Bun build → static serve).

# ─── Stage 1: Build ──────────────────────────────────────────────────────────
FROM oven/bun:1.3 AS builder

WORKDIR /app

# Copy dependency manifests first for layer caching
COPY package.json bun.lock ./

# Install all dependencies (including devDependencies for build)
RUN bun install --frozen-lockfile

# Copy source
COPY . .

# Generate the static SPA output (Nuxt SPA mode: ssr: false → nuxt generate)
RUN bun run generate

# ─── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM nginx:1.27-alpine AS runtime

# Remove default nginx config; replace with SPA-friendly config
RUN rm /etc/nginx/conf.d/default.conf

COPY --from=builder /app/.output/public /usr/share/nginx/html

# SPA routing: serve index.html for all unknown paths (client-side router)
RUN printf 'server {\n\
    listen 3000;\n\
    server_name _;\n\
    root /usr/share/nginx/html;\n\
    index index.html;\n\
\n\
    # Serve the health page as a static file\n\
    location /health {\n\
        try_files $uri $uri/ /health/index.html;\n\
    }\n\
\n\
    # SPA fallback: all routes return index.html for client-side routing\n\
    location / {\n\
        try_files $uri $uri/ /index.html;\n\
    }\n\
\n\
    # Cache static assets\n\
    location ~* \\.(js|css|png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot)$ {\n\
        expires 1y;\n\
        add_header Cache-Control "public, immutable";\n\
    }\n\
}\n' > /etc/nginx/conf.d/default.conf

# Non-root: nginx worker runs as existing nginx user (uid 101 on alpine)
# We adjust permissions so the nginx user can write to required dirs
RUN chown -R nginx:nginx /usr/share/nginx/html \
  && chmod -R 755 /usr/share/nginx/html \
  && chown -R nginx:nginx /var/cache/nginx \
  && chown -R nginx:nginx /var/log/nginx \
  && touch /var/run/nginx.pid \
  && chown nginx:nginx /var/run/nginx.pid

USER nginx

EXPOSE 3000

# Health check against the SPA health page
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health > /dev/null 2>&1 || exit 1

CMD ["nginx", "-g", "daemon off;"]

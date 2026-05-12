# syntax=docker/dockerfile:1.6
FROM node:20-bookworm-slim AS builder

WORKDIR /app

# NEXT_PUBLIC_* values are read at build time and baked into the client bundle.
# They MUST be passed in via docker-compose build.args so the runtime image
# embeds the correct Supabase URL / publishable key / backend base URL.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY
ARG NEXT_PUBLIC_API_BASE_URL

ENV NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL} \
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY=${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY} \
    NEXT_PUBLIC_API_BASE_URL=${NEXT_PUBLIC_API_BASE_URL} \
    NEXT_TELEMETRY_DISABLED=1

COPY package.json package-lock.json ./
RUN npm ci --legacy-peer-deps

COPY . .
RUN npm run build

# Transpile next.config.ts → next.config.js so the runtime stage doesn't
# need TypeScript installed to parse the config at startup.
RUN node -e "\
  const ts = require('typescript'); \
  const fs = require('fs'); \
  const src = fs.readFileSync('next.config.ts', 'utf8'); \
  const result = ts.transpileModule(src, { \
    compilerOptions: { module: ts.ModuleKind.CommonJS, esModuleInterop: true } \
  }); \
  fs.writeFileSync('next.config.js', result.outputText);"

RUN npm prune --omit=dev --legacy-peer-deps


FROM node:20-bookworm-slim AS runtime

ENV NODE_ENV=production \
    PORT=3000 \
    NEXT_TELEMETRY_DISABLED=1

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --system app && useradd --system --gid app --home-dir /home/app --create-home app

WORKDIR /app

COPY --from=builder --chown=app:app /app/package.json /app/package-lock.json /app/next.config.js ./
COPY --from=builder --chown=app:app /app/node_modules ./node_modules
COPY --from=builder --chown=app:app /app/.next ./.next
COPY --from=builder --chown=app:app /app/public ./public

USER app

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -fsS http://localhost:3000/ -o /dev/null || exit 1

CMD ["npx", "next", "start", "-H", "0.0.0.0", "-p", "3000"]

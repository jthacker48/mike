# syntax=docker/dockerfile:1.6
FROM node:20-bookworm-slim AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

RUN npm prune --omit=dev


FROM node:20-bookworm-slim AS runtime

ENV NODE_ENV=production \
    PORT=3001

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       libreoffice \
       ca-certificates \
       curl \
       fonts-dejavu-core \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --system app && useradd --system --gid app --home-dir /home/app --create-home app

WORKDIR /app

COPY --from=builder --chown=app:app /app/package.json /app/package-lock.json ./
COPY --from=builder --chown=app:app /app/node_modules ./node_modules
COPY --from=builder --chown=app:app /app/dist ./dist

USER app

EXPOSE 3001

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -fsS http://localhost:3001/health || exit 1

CMD ["node", "dist/index.js"]

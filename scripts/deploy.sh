#!/usr/bin/env bash
# Deploy mike on ai-server.
# Fetches secrets from Infisical, regenerates .env, rebuilds the frontend and
# backend containers, waits for both health endpoints to come back green.
#
# Prerequisites on host:
#   - infisical CLI installed
#   - ~/.infisical/claude-cli.env contains INFISICAL_UNIVERSAL_AUTH_CLIENT_ID
#     and INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET (chmod 600)
#   - .env.defaults committed in repo (non-secret config)
#   - Infisical project: rule26/mike (UUID set in INFISICAL_PROJECT_ID below;
#     fill in after creating the project at https://infisical.lifethacker.com)

set -euo pipefail

cd "$(dirname "$0")/.."

INFISICAL_DOMAIN="${INFISICAL_DOMAIN:-https://infisical.lifethacker.com}"
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-f4d06fdb-52ff-4bc6-bf6e-20569af0cd72}"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"
INFISICAL_AUTH_FILE="${INFISICAL_AUTH_FILE:-$HOME/.infisical/claude-cli.env}"
BACKEND_PORT="${BACKEND_PORT:-8095}"
FRONTEND_PORT="${FRONTEND_PORT:-8094}"

if [[ "$INFISICAL_PROJECT_ID" == REPLACE_WITH_* ]]; then
  echo "✗ INFISICAL_PROJECT_ID is not set." >&2
  echo "  Create the Infisical project rule26/mike, copy its UUID, and either" >&2
  echo "  edit scripts/deploy.sh or export INFISICAL_PROJECT_ID before running." >&2
  exit 1
fi

if [[ ! -r "$INFISICAL_AUTH_FILE" ]]; then
  echo "✗ Infisical auth file not found: $INFISICAL_AUTH_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a; source "$INFISICAL_AUTH_FILE"; set +a

echo "→ Authenticating to Infisical..."
TOKEN=$(infisical login \
  --method=universal-auth \
  --client-id="$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID" \
  --client-secret="$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" \
  --domain="$INFISICAL_DOMAIN" \
  --plain --silent)

if [[ -z "$TOKEN" ]]; then
  echo "✗ Failed to obtain Infisical access token" >&2
  exit 1
fi

echo "→ Exporting secrets from Infisical (project=$INFISICAL_PROJECT_ID env=$INFISICAL_ENV)..."
infisical export \
  --projectId="$INFISICAL_PROJECT_ID" \
  --env="$INFISICAL_ENV" \
  --domain="$INFISICAL_DOMAIN" \
  --token="$TOKEN" \
  --format=dotenv \
  > .env.tmp

if [[ ! -s .env.tmp ]]; then
  echo "✗ Infisical export returned empty .env" >&2
  rm -f .env.tmp
  exit 1
fi

# Atomic swap; preserve previous .env as .env.bak
[[ -f .env ]] && cp .env .env.bak
mv .env.tmp .env
chmod 600 .env
echo "✓ .env regenerated from Infisical ($(wc -l < .env) keys)"

echo "→ Pulling latest source..."
git pull --ff-only

echo "→ Rebuilding and restarting containers (mike-backend + mike-frontend)..."
docker compose up -d --build

echo "→ Waiting for mike-backend health (up to 180s)..."
for i in {1..90}; do
  if curl -fsS "http://localhost:${BACKEND_PORT}/health" >/dev/null 2>&1; then
    echo "✓ mike-backend healthy after $((i * 2))s"
    BACKEND_OK=1
    break
  fi
  sleep 2
done

if [[ "${BACKEND_OK:-0}" -ne 1 ]]; then
  echo "✗ mike-backend did not become healthy in 180s" >&2
  echo "  Logs: docker compose logs --tail=100 mike-backend" >&2
  exit 1
fi

echo "→ Waiting for mike-frontend (up to 120s)..."
for i in {1..60}; do
  if curl -fsS "http://localhost:${FRONTEND_PORT}/" -o /dev/null 2>&1; then
    echo "✓ mike-frontend responding after $((i * 2))s"
    exit 0
  fi
  sleep 2
done

echo "✗ mike-frontend did not respond in 120s" >&2
echo "  Logs: docker compose logs --tail=100 mike-frontend" >&2
exit 1

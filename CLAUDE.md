# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What This Project Is

Mike is the rule26 legal document workbench: a Next.js frontend + Express backend that lets attorneys (and any rule26 sibling service) upload documents, run AI-assisted review/chat/tabular workflows, and manage per-user model API keys.

This is a **rule26 fork** of [willchen96/mike](https://github.com/willchen96/mike). Upstream tracks `upstream` (`willchen96/mike`); rule26 customizations push to `origin` (`jthacker48/mike`). Pull upstream fixes with `git fetch upstream && git merge upstream/main`.

Mike is the only rule26 project with an end-user UI. Its siblings (folio-enrich, folio-mapper, folio-disco, folio-id, case-brain) are taxonomy/enrichment services that can call into mike via REST.

## Development Commands

```bash
# Backend
cd backend && npm install && npm run dev   # tsx watch on :3001

# Frontend
cd frontend && npm install && npm run dev  # Next.js dev on :3000
```

Local dev assumes a hosted Supabase project + R2 bucket already provisioned and credentials in `backend/.env` and `frontend/.env.local` (see the upstream README for the per-service env file layout when developing locally).

For containerized deploys, the per-service env files are bypassed — `docker-compose.yml` injects env vars from the repo-root `.env.defaults` + `.env` into both containers (matches the rule26 deploy convention).

## Deployed Service (ai-server)

| | |
|---|---|
| **Host** | `10.77.1.181` (ai-server) |
| **Frontend port** | `8094` → container `3000` |
| **Backend port** | `8095` → container `3001` |
| **Public UI URL** | `http://10.77.1.181:8094/` |
| **Backend health** | `http://10.77.1.181:8095/health` |
| **Repo on server** | `~/svc/rule26/mike` |
| **Data backends** | Supabase (hosted, project `mike`) + Cloudflare R2 (bucket `mike`) |
| **Config** | `.env.defaults` (committed, non-secret) |
| **Secrets** | Infisical project `rule26/mike` (UUID set in `scripts/deploy.sh`), env `prod`. Fetched into `.env` at deploy time. |
| **Infisical auth** | Machine identity `claude-cli` (Universal Auth) — same one used by sibling services. |

Deploy / restart:
```bash
ssh ai-server
cd ~/svc/rule26/mike
./scripts/deploy.sh       # pulls latest, regenerates .env, rebuilds, waits for /health
docker compose logs -f    # tail
docker compose logs -f mike-backend
docker compose logs -f mike-frontend
```

The deploy script:
1. Authenticates to Infisical via `~/.infisical/claude-cli.env` (chmod 600).
2. Exports `prod` secrets to `.env` (atomic tmp + mv; previous `.env` kept as `.env.bak`).
3. Runs `git pull --ff-only && docker compose up -d --build`.
4. Polls backend `/health` then frontend `/` for up to 5 minutes total.

Adding a new secret: add it in Infisical under project `rule26/mike` → env `prod`, then re-run `./scripts/deploy.sh`. Adding a non-secret config var: edit `.env.defaults` and `git push`, then `./scripts/deploy.sh`.

**Important:** the frontend bakes `NEXT_PUBLIC_*` env vars into its JavaScript bundle at *build* time. Changing any of `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY`, or `NEXT_PUBLIC_API_BASE_URL` requires a full rebuild (the deploy script already does this — just `./scripts/deploy.sh` again).

## Architecture

```
mike/
├─ backend/                # Express 4 + TypeScript on Node 20
│   ├─ src/
│   │   ├─ index.ts        # entry point, port 3001, mounts routers + rate limiters
│   │   ├─ routes/         # chat, projects, projectChat, documents, tabular,
│   │   │                  # workflows, user, downloads
│   │   ├─ lib/            # supabase client, R2 client, providers
│   │   └─ middleware/     # auth, error handling
│   ├─ schema.sql          # full Supabase schema (use for FRESH databases)
│   ├─ migrations/         # incremental updates (use for EXISTING databases)
│   ├─ nixpacks.toml       # upstream Railway deploy config (unused on ai-server)
│   └─ Dockerfile          # rule26: Node 20 + LibreOffice, multi-stage
├─ frontend/               # Next.js 16 + React 19 + Tailwind v4
│   ├─ src/                # app router pages, components
│   ├─ open-next.config.ts # upstream Cloudflare Workers deploy (unused on ai-server)
│   ├─ next.config.ts
│   └─ Dockerfile          # rule26: Node 20 multi-stage, NEXT_PUBLIC_ baked via build args
├─ docs/
│   ├─ safe-local-testing.md            # upstream local dev guide
│   └─ rule26-integration.md            # rule26: REST endpoints for sibling services
├─ scripts/
│   └─ deploy.sh           # rule26: Infisical → .env → docker compose up
├─ docker-compose.yml      # rule26: two services on :8094 (frontend) + :8095 (backend)
├─ .env.defaults           # rule26: committed, non-secret config
├─ .env.example            # rule26: template for the Infisical-driven .env
└─ README.md               # upstream README + rule26 deployment appendix
```

## How rule26 Siblings Talk to Mike

Mike exposes its REST API at `http://10.77.1.181:8095` (LAN-only — no auth gateway in Phase 1). Endpoints are listed in `docs/rule26-integration.md`. Notable routes:

| Verb | Path | Purpose |
|---|---|---|
| `GET` | `/health` | liveness, used by docker healthcheck and deploy script |
| `POST` | `/projects` | create a project (workspace) |
| `POST` | `/projects/:projectId/documents` | upload a document into a project |
| `POST` | `/projects/:projectId/chat` | start/continue a chat against project docs |
| `POST` | `/single-documents` | upload a one-off document |
| `POST` | `/tabular-review/:reviewId/generate` | run a tabular review pass |
| `POST` | `/chat` | start/continue an ad-hoc chat (no project) |

All routes assume a Supabase user JWT in the `Authorization: Bearer <token>` header. Sibling services that need to push docs into mike on behalf of a user will need that user's session token (or a service account once we add one).

## Rule26 Customization Policy

Keep the fork close to upstream so `git merge upstream/main` stays painless.

- **rule26-only files** (do NOT change for upstream-compatibility reasons):
  - `Dockerfile` (both packages), `docker-compose.yml`, `scripts/deploy.sh`,
    `.env.defaults`, `.env.example`, `CLAUDE.md`, `docs/rule26-integration.md`,
    the rule26 section of `README.md`, the rule26 additions to `.gitignore`.
- **Functional changes inside `backend/src/` or `frontend/src/`** should be small, well-isolated, and ideally fed back upstream as PRs. If a change isn't upstream-able, document why in `docs/rule26-divergence.md` (create when needed).
- **Schema changes** (anything under `backend/schema.sql` or `backend/migrations/`) require a fresh migration file. Never edit `schema.sql` in-place once Supabase is in production.

## Key Choices Worth Knowing

**Supabase API keys: use the NEW Publishable + Secret format, not the legacy anon/service_role JWTs.** Mike's SDK versions support both, but legacy is on Supabase's deprecation roadmap. The upstream README still says "use legacy"; that line is a transition-period leftover (mike's own env var names — `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY`, `SUPABASE_SECRET_KEY` — already point to the new scheme). Don't follow the upstream README on this point.

## Common Pitfalls

- **NEXT_PUBLIC_* drift.** The frontend bundle is built once and shipped to every browser. If you `docker compose restart mike-frontend` without `--build`, env changes won't take effect. Always go through `scripts/deploy.sh` (it does `up -d --build`).
- **LibreOffice missing.** Mike's `libreoffice-convert` dep shells out to the `soffice` binary. The rule26 backend Dockerfile installs LibreOffice; if you change the base image, keep it.
- **Supabase email confirmation.** Supabase's built-in mailer is heavily rate-limited and may be off by default on new projects. For real sign-ups configure Resend SMTP in Supabase; for development disable email confirmation (Auth → Providers → Email).
- **Body size.** Backend's `express.json` cap is 50MB. Large PDFs that exceed this fail at the parser, not multer.

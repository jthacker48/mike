# rule26 Integration Guide

How sibling rule26 services (folio-enrich, folio-mapper, folio-id, case-brain, …) and the eventual chatcya integration talk to mike.

This document is a stable contract for callers. When mike's backend routes change, update this file.

---

## Base URL

| Environment | URL | Auth |
|---|---|---|
| ai-server LAN | `http://10.77.1.181:8095` | Supabase JWT in `Authorization: Bearer <token>` |
| local dev | `http://localhost:3001` | same |

Mike is **LAN-only** in Phase 1. No public reverse proxy, no rate-limiter-friendly key auth, no service account. Every request must carry a real end-user's Supabase JWT.

All endpoints below are mounted on the backend (Express, port 3001 inside the container; published as 8095 on the host).

## Auth model

Mike's middleware (`backend/src/middleware/auth.ts`) requires a valid Supabase user JWT for every route. There is no anonymous access and there is no machine identity yet.

- If a sibling service needs to act *on behalf of an attorney user*, the attorney must sign into mike at least once so a Supabase user row exists; the sibling then forwards the attorney's current Supabase session token.
- If a sibling service needs to act *autonomously* (cron, enrichment pipeline), Phase 1 is **not yet supported**. The follow-on work is to add a service-account JWT issuer + a separate `requireServiceAuth` middleware. Track this in `docs/rule26-divergence.md` when started.

Rate limits (defined in `backend/src/index.ts`): general 300/15min, chat 30/15min, uploads 50/hour. Override via env vars in `.env.defaults`.

## Endpoint groups

Each group below is a separate Express router mounted at the prefix shown. Read the source under `backend/src/routes/<group>.ts` for request/response shapes — they are documented in TypeScript types, not OpenAPI.

### `/health` — liveness
- `GET /health` → `{ ok: true }`. No auth. Used by docker compose healthcheck and `scripts/deploy.sh`.

### `/projects` — workspaces (most common integration surface)
Source: `backend/src/routes/projects.ts`

- `GET /projects` — list user's projects
- `POST /projects` — create
- `GET /projects/:projectId` — fetch one
- `PATCH /projects/:projectId` — rename / update metadata
- `DELETE /projects/:projectId`
- `GET /projects/:projectId/people` — collaborators
- `GET /projects/:projectId/documents` — list docs in project
- `POST /projects/:projectId/documents` — upload doc (multipart). **This is the primary "push a document into mike from a sibling service" entrypoint.**
- `GET /projects/:projectId/chats` — list project chats
- `POST /projects/:projectId/folders` / `PATCH …/:folderId` / `DELETE …/:folderId` — folder CRUD
- `PATCH /projects/:projectId/documents/:documentId/folder` — move a doc

### `/projects/:projectId/chat` — chat against a project's docs
Source: `backend/src/routes/projectChat.ts`

- `POST /projects/:projectId/chat` — start/continue a chat scoped to a project's documents. Streams SSE.

### `/single-documents` — one-off documents (no project)
Source: `backend/src/routes/documents.ts`

- `GET /single-documents` — list user's standalone docs
- `POST /single-documents` — upload (multipart)
- `GET /single-documents/:documentId/display` — render
- `GET /single-documents/:documentId/url` — presigned R2 URL
- `GET /single-documents/:documentId/docx` — DOCX export
- `GET /single-documents/:documentId/versions` — version history
- `POST /single-documents/:documentId/versions` — upload new version
- `PATCH /single-documents/:documentId` — metadata
- `DELETE /single-documents/:documentId`
- `POST /single-documents/download-zip` — bulk export

### `/chat` — ad-hoc chats (not bound to a project)
Source: `backend/src/routes/chat.ts`

- `GET /chat` — list
- `POST /chat/create` — create new chat session
- `POST /chat` — send message (streams SSE)
- `GET /chat/:chatId` — fetch full transcript
- `PATCH /chat/:chatId` — rename / update
- `DELETE /chat/:chatId`
- `POST /chat/:chatId/generate-title` — auto-name a chat

### `/tabular-review` — spreadsheet-style document review
Source: `backend/src/routes/tabular.ts`

- `GET /tabular-review` — list reviews
- `POST /tabular-review` — create
- `GET /tabular-review/:reviewId` — fetch one
- `PATCH /tabular-review/:reviewId`
- `DELETE /tabular-review/:reviewId`
- `POST /tabular-review/prompt` — preview a prompt against sample docs
- `POST /tabular-review/:reviewId/generate` — run the review pass (streams)
- `POST /tabular-review/:reviewId/clear-cells`
- `POST /tabular-review/:reviewId/chat` — chat in the context of a cell/row
- `GET /tabular-review/:reviewId/chats` — list those chats

### `/workflows` — saved prompt workflows
Source: `backend/src/routes/workflows.ts`

- `GET /workflows` / `POST /workflows` / `GET /workflows/:workflowId` /
  `PUT|PATCH /workflows/:workflowId` / `DELETE /workflows/:workflowId`
- Hidden workflows: `GET|POST /workflows/hidden`, `DELETE /workflows/hidden/:workflowId`
- Sharing: `GET /workflows/:workflowId/shares`, `POST /workflows/:workflowId/share`, `DELETE /workflows/:workflowId/shares/:shareId`

### `/user` and `/users` — user profile + API keys
Source: `backend/src/routes/user.ts`

- `GET /user/profile`, `POST /user/profile`, `PATCH /user/profile`
- `GET /user/api-keys` — which providers the user has configured
- `PUT /user/api-keys/:provider` — set a per-user AI provider key (encrypted server-side with `USER_API_KEYS_ENCRYPTION_SECRET`)
- `DELETE /user/account`

`/users` is mounted as an alias for `/user`. Use `/user` in new code.

### `/download` — signed download tokens
Source: `backend/src/routes/downloads.ts`

- `GET /download/:token` — redeem a signed token (server-side issued; not for direct sibling use)

---

## Integration patterns

### Pattern A: Sibling service pushes enriched documents into a user's project

Example: `folio-enrich` finishes tagging a document and wants to put the enriched copy + tags into a project the attorney is reviewing in mike.

```
1. Attorney signs into mike at http://10.77.1.181:8094 (so a Supabase user exists).
2. Sibling service obtains the attorney's Supabase access token. In Phase 1, this
   has to be passed in explicitly — there is no SSO between mike and folio-enrich.
3. POST /projects/:projectId/documents with multipart body containing:
   - file: the enriched document
   - metadata fields (per backend/src/routes/projects.ts)
   - Authorization: Bearer <attorney-jwt>
4. Response includes the document_id. Sibling stores it for later linkbacks.
```

### Pattern B: Chatcya (future) opens a mike project for an attorney

Mirrors chatcya's existing Clio integration shape. Sketch:

```
1. New chatcya router /integrations/mike (modelled on app/api/clio.py)
2. Attorney connects mike from chatcya settings → mike OAuth/login → store JWT
   in public.mike_connections (table parallel to public.clio_connections)
3. Chatcya server proxies to http://10.77.1.181:8095 using the stored JWT
4. UI options: deep-link out to mike, embed mike via iframe (same-origin only —
   requires running mike under a chatcya-controlled subdomain), or surface
   chosen mike artifacts inline.
```

Not in Phase 1 scope. Track in chatcya repo when started.

---

## Open items / known gaps for sibling integration

1. **No service-account auth.** Every call requires a real user JWT today. Adding a `M2M` service token issuer is the most likely first follow-on.
2. **No webhook out from mike.** If a sibling wants to react to "document uploaded" or "chat completed" events, mike doesn't yet emit them. Polling is the only option.
3. **No OpenAPI spec.** This document is the only registry. When mike's routes change, update this file in the same PR.
4. **No idempotency keys** on `POST` routes. A retry will create a duplicate.
5. **`requireAuth` is the only middleware.** No per-route capability checks beyond row-level checks the route handler does itself.

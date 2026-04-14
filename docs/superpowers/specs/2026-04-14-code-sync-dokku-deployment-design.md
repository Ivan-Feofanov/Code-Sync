# Code-Sync Self-Hosted Deployment on Dokku — Design

## Goal

Self-host a collaborative coding room for live technical interviews on an existing
Hetzner VPS running Dokku. Candidates join via a public URL, collaborate in real
time with the interviewer, and execute Python snippets against a privately-hosted
Piston instance so no candidate code leaves the server.

## Non-goals

- Authentication, user accounts, or org/team management (rooms are ephemeral and
  shared via link)
- Persistence of rooms, code, or chat across server restarts
- Multi-language code execution (Python only, by explicit choice)
- Horizontal scaling or high availability
- Interview recording or artifact storage
- CI/CD — deploys are manual `git push dokku-<app> main`

## Source project

Fork of [sahilatahar/Code-Sync](https://github.com/sahilatahar/Code-Sync) to
`github.com/<your-github-user>/Code-Sync`. All changes are commits in the fork; the
VPS deploys from the fork via Dokku git remotes.

## Target environment

- Hetzner VPS: 2 vCPU, 4 GB RAM, 20 GB disk
- Host already runs Dokku with the `letsencrypt` plugin configured
- Domain `example.com` with DNS control
- Existing nginx is managed by Dokku — no manual vhosts

## Architecture

Three Dokku apps on a shared Dokku network. Two are public, one is internal.

```
Internet (443) ─► Dokku nginx ─┬─► interview-client   (<CLIENT_DOMAIN>)
                               └─► interview-server   (<SERVER_DOMAIN>)

Dokku network "interview-net":
    interview-client  ─► interview-server  ─► interview-piston  (no public domain)
```

- `interview-client` — Code-Sync React/Vite SPA built to static files, served by
  `serve`
- `interview-server` — Express + Socket.io, proxies code-execution requests to
  Piston
- `interview-piston` — `ghcr.io/engineer-man/piston` with Python 3.12 pre-installed,
  privileged for sandboxing, persistent package volume

Two public subdomains (rather than one with path routing) because Dokku is
strongly one-app-per-domain. The cost is a tiny CORS allowlist on the server.

## Components

### interview-client

- Based on existing `client/Dockerfile`, upgraded from `node:18-alpine` to
  `node:20-alpine` (Node 18 is EOL)
- `VITE_BACKEND_URL` is a Vite **build-time** variable, so it must be passed as
  a Docker build arg, not a runtime env var. Dokku does not pass `config:set`
  values into builds by default, so we use:
  `dokku docker-options:add interview-client build "--build-arg VITE_BACKEND_URL=https://<SERVER_DOMAIN>"`
  and add `ARG VITE_BACKEND_URL` + `ENV VITE_BACKEND_URL=$VITE_BACKEND_URL` to
  the client Dockerfile before `npm run build`.
- Serves static `dist/` via `serve -s dist -l $PORT`
- Code change: remove direct calls to `emkc.org` Piston; all code execution
  requests go to our server at `${VITE_BACKEND_URL}/api/execute`

### interview-server

- Based on existing `server/Dockerfile`, upgraded to `node:20-alpine`
- Env:
  - `PORT` — injected by Dokku
  - `CORS_ORIGIN=https://<CLIENT_DOMAIN>`
  - `PISTON_URL=http://interview-piston.web:2000/api/v2`
- Code additions:
  - `POST /api/execute` endpoint that forwards `{language, version, code, stdin}`
    to Piston and returns the result
  - CORS middleware honouring `CORS_ORIGIN`
- Socket.io already works over Dokku's default nginx template (websocket upgrade
  headers are set by default)

### interview-piston

- New `piston/Dockerfile` that wraps `ghcr.io/engineer-man/piston:latest`
- Exposes :2000 on the Dokku internal network only (no `domains:set`)
- Runs privileged: `dokku docker-options:add interview-piston deploy,run "--privileged"`
- Package volume mounted at `/piston/packages` via `dokku storage:mount` so the
  Python runtime survives restarts
- Python 3.12 installed via a one-time `POST /api/v2/packages` call after first
  deploy (documented in `deploy/DEPLOY.md`)

## Repository layout (in the fork)

```
/client/                 existing, patched for Node 20 + server-proxied execution
/server/                 existing, patched for Node 20 + /api/execute + CORS
/piston/                 new: Dockerfile and brief README
/deploy/
  DEPLOY.md              Dokku bootstrap commands + one-time Python install step
  dokku-bootstrap.sh     optional idempotent script that runs the commands below
/docs/superpowers/specs/ this spec
```

## Monorepo deploy strategy

Dokku deploys a whole repo per app, but we have three services in subdirectories.
We use the [`dokku-monorepo`](https://github.com/crisward/dokku-monorepo) plugin,
which lets each app declare a source subdirectory via
`dokku config:set <app> MONOREPO_SUBDIR=<path>`. This keeps the fork clean (no
duplicated root-level Dockerfiles) and is a small, well-maintained plugin.

Installed once on the VPS:

```bash
sudo dokku plugin:install https://github.com/crisward/dokku-monorepo
```

## Dokku bootstrap (one-time on VPS)

```bash
# apps
dokku apps:create interview-client
dokku apps:create interview-server
dokku apps:create interview-piston

# monorepo subdirs
dokku config:set interview-client  MONOREPO_SUBDIR=client
dokku config:set interview-server  MONOREPO_SUBDIR=server
dokku config:set interview-piston  MONOREPO_SUBDIR=piston

# shared internal network
dokku network:create interview-net
dokku network:set interview-client  attach-post-deploy interview-net
dokku network:set interview-server  attach-post-deploy interview-net
dokku network:set interview-piston  attach-post-deploy interview-net

# piston needs privileged + persistent package volume
dokku docker-options:add interview-piston deploy,run "--privileged"
mkdir -p /var/lib/dokku/data/storage/piston
dokku storage:mount interview-piston /var/lib/dokku/data/storage/piston:/piston/packages

# public domains + TLS
dokku domains:set interview-client <CLIENT_DOMAIN>
dokku domains:set interview-server <SERVER_DOMAIN>
dokku letsencrypt:enable interview-client
dokku letsencrypt:enable interview-server

# server runtime env
dokku config:set interview-server \
  CORS_ORIGIN=https://<CLIENT_DOMAIN> \
  PISTON_URL=http://interview-piston.web:2000/api/v2

# client build-time arg (Vite bakes this into the bundle)
dokku docker-options:add interview-client build \
  "--build-arg VITE_BACKEND_URL=https://<SERVER_DOMAIN>"
```

First-deploy ordering matters: deploy `interview-piston` first so its service
hostname resolves when `interview-server` starts up, then deploy server, then
client.

DNS: create A records for `<CLIENT_DOMAIN>` and
`<SERVER_DOMAIN>` pointing at the Hetzner IP before enabling
letsencrypt.

## Deploy flow (ongoing)

From a local clone of the fork:

```bash
git remote add dokku-client dokku@<vps>:interview-client
git remote add dokku-server dokku@<vps>:interview-server
git remote add dokku-piston dokku@<vps>:interview-piston

git push dokku-client main
git push dokku-server main
git push dokku-piston main
```

One-time after first piston deploy:

```bash
dokku run interview-server \
  curl -sX POST http://interview-piston.web:2000/api/v2/packages \
  -H 'Content-Type: application/json' \
  -d '{"language":"python","version":"3.12.0"}'
```

## Verification checklist

- `https://<CLIENT_DOMAIN>` serves the Code-Sync UI
- Open a room in two browsers — edits, chat, drawing, multi-cursor all sync
  in real time (confirms Socket.io over Dokku's nginx)
- Run `print(2+2)` in Python — returns `4` (confirms client → server → Piston
  path and Python install)
- `dokku ps:restart interview-piston` — Python runtime persists (confirms
  volume mount)
- Reboot the VPS — all three apps come back up with TLS intact

## Resource footprint

| Service | RAM idle | Image size |
|---|---|---|
| interview-client | ~30 MB | ~100 MB |
| interview-server | ~80 MB | ~200 MB |
| interview-piston | ~200 MB idle, ~500 MB during exec | ~600 MB + ~200 MB Python |
| **Total** | **~310 MB idle** | **~1.1 GB** |

Comfortable headroom on a 4 GB / 20 GB box.

## Risks and mitigations

- **Piston privileged container** — required for code sandboxing; acceptable
  because it only runs candidate Python code that is itself sandboxed by Piston's
  internal `isolate`. Not reachable from the public internet.
- **Dokku-monorepo plugin is third-party** — mitigated by the plugin being
  small, widely used, and easy to replace with root-level `Dockerfile.<app>`
  files if it ever breaks.
- **Ephemeral rooms** — explicit non-goal; interviewer is expected to copy any
  artifacts out before ending the session.
- **No rate limiting on `/api/execute`** — acceptable for invite-link-only use;
  can be added later if the URL leaks.

## Out of scope for this spec

The following are intentionally deferred and would each be a separate spec if
needed later:

- Adding more languages to Piston
- Persistent rooms / database
- Auth in front of rooms
- Interview recording
- Automated deploys from GitHub Actions

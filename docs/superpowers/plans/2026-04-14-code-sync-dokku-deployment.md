# Code-Sync Dokku Deployment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork and deploy [sahilatahar/Code-Sync](https://github.com/sahilatahar/Code-Sync) as a self-hosted interview tool on a Hetzner VPS running Dokku, with a privately-hosted Piston (Python-only) backing code execution.

**Architecture:** Three Dokku apps on a shared Dokku network: `interview-client` (static SPA, public on `interview.feofanov.dev`), `interview-server` (Express + Socket.io + Piston proxy, public on `api.interview.feofanov.dev`), and `interview-piston` (privileged code-execution container, internal only). The monorepo is split per-app via the `dokku-monorepo` plugin.

**Tech Stack:** React/Vite, Express, Socket.io, Node 20, Docker, Dokku, Piston (`ghcr.io/engineer-man/piston`), Vitest + Supertest (new, for the proxy endpoint test).

**Spec:** `docs/superpowers/specs/2026-04-14-code-sync-dokku-deployment-design.md`

---

## File structure

After this plan runs, the fork will contain:

```
/client/
  Dockerfile                    (modified: Node 20, VITE_BACKEND_URL build arg)
  src/api/pistonApi.ts          (modified: base URL now the server proxy)
/server/
  Dockerfile                    (modified: Node 20)
  package.json                  (modified: +axios, +vitest, +supertest, +@types)
  src/
    server.ts                   (modified: strict CORS, mount piston router)
    piston.ts                   (new: /api/piston proxy router)
  test/
    piston.test.ts              (new: supertest coverage of the proxy)
  vitest.config.ts              (new)
/piston/
  Dockerfile                    (new: wraps ghcr.io/engineer-man/piston)
  README.md                     (new: one paragraph on what this is)
/deploy/
  DEPLOY.md                     (new: full Dokku bootstrap walkthrough)
  dokku-bootstrap.sh            (new: idempotent setup script)
  nginx-websocket-note.md       (new: one-liner about Dokku's WS support)
/docs/superpowers/specs/
  2026-04-14-code-sync-dokku-deployment-design.md   (copied from working dir)
```

---

## Task 1: Fork the repo and set up local working clone

**Files:** none yet

- [ ] **Step 1: Fork via GitHub UI**

Go to https://github.com/sahilatahar/Code-Sync, click Fork, target account `Ivan-Feofanov`. Uncheck "Copy the main branch only" only if you want tags. Default settings otherwise.

- [ ] **Step 2: Clone the fork locally**

```bash
cd ~/work
git clone git@github.com:Ivan-Feofanov/Code-Sync.git
cd Code-Sync
```

- [ ] **Step 3: Create a working branch**

```bash
git checkout -b dokku-deployment
```

- [ ] **Step 4: Verify upstream builds clean before any changes**

```bash
docker compose build
```

Expected: both images build successfully. If this fails on upstream code, stop and fix the environment before continuing — don't paper over it with our changes.

- [ ] **Step 5: Copy the spec into the repo**

```bash
mkdir -p docs/superpowers/specs
cp /Users/feofanov/work/pa/docs/superpowers/specs/2026-04-14-code-sync-dokku-deployment-design.md \
   docs/superpowers/specs/
git add docs/
git commit -m "docs: add Dokku deployment design spec"
```

---

## Task 2: Upgrade Node 18 → 20 in both Dockerfiles

**Files:**
- Modify: `client/Dockerfile`
- Modify: `server/Dockerfile`

- [ ] **Step 1: Update `client/Dockerfile`**

Replace both `FROM node:18-alpine` lines with `FROM node:20-alpine`. File becomes:

```dockerfile
# Stage 1: Build the project
FROM node:20-alpine AS builder

WORKDIR /build

COPY package*.json .

RUN npm ci

COPY . .

RUN npm run build
RUN npm prune --omit=dev

# Stage 2: Serve the `dist` folder
FROM node:20-alpine AS runner

WORKDIR /app

COPY --from=builder /build/dist dist/
COPY --from=builder /build/package*.json .
COPY --from=builder /build/node_modules ./node_modules

EXPOSE 5173

CMD ["npx", "serve", "-s", "dist", "-l", "5173"]
```

- [ ] **Step 2: Update `server/Dockerfile`**

Replace both `FROM node:18-alpine` with `FROM node:20-alpine`. Leave the rest of the file alone.

- [ ] **Step 3: Verify both images still build**

```bash
docker compose build
```

Expected: both images build successfully on Node 20.

- [ ] **Step 4: Commit**

```bash
git add client/Dockerfile server/Dockerfile
git commit -m "chore: bump Node 18 → 20 in client and server Dockerfiles"
```

---

## Task 3: Add Vitest + Supertest test infrastructure to server

**Files:**
- Modify: `server/package.json`
- Create: `server/vitest.config.ts`
- Create: `server/test/smoke.test.ts`

We need a minimal test harness so the proxy endpoint in Task 5 can be test-driven. The existing project has none.

- [ ] **Step 1: Add dev deps**

From `server/`:

```bash
npm install --save-dev vitest supertest @types/supertest
```

- [ ] **Step 2: Add test script to `server/package.json`**

Inside `"scripts"`, add `"test": "vitest run"` and `"test:watch": "vitest"`.

- [ ] **Step 3: Create `server/vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
})
```

- [ ] **Step 4: Write a smoke test to verify the harness works**

Create `server/test/smoke.test.ts`:

```ts
import { describe, it, expect } from "vitest"

describe("test harness", () => {
  it("runs", () => {
    expect(1 + 1).toBe(2)
  })
})
```

- [ ] **Step 5: Run it**

From `server/`:

```bash
npm test
```

Expected: 1 test passes.

- [ ] **Step 6: Commit**

```bash
git add server/package.json server/package-lock.json server/vitest.config.ts server/test/
git commit -m "test: add vitest + supertest harness to server"
```

---

## Task 4: Tighten CORS on the server

**Files:**
- Modify: `server/src/server.ts`
- Create: `server/test/cors.test.ts`

The upstream server uses `app.use(cors())` (wide open) and `origin: "*"` in Socket.io. We restrict both to an env-driven allowlist, defaulting to `*` so local development keeps working.

- [ ] **Step 1: Write failing CORS test**

Create `server/test/cors.test.ts`:

```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest"
import request from "supertest"
import type { Server } from "http"

let server: Server

beforeAll(async () => {
  process.env.CORS_ORIGIN = "https://interview.example.com"
  process.env.PORT = "0"
  // Import after env is set so the module reads it.
  const mod = await import("../src/server")
  server = (mod as any).server
})

afterAll((done) => {
  server.close(() => done())
})

describe("CORS", () => {
  it("echoes the configured origin when it matches", async () => {
    const res = await request(server)
      .options("/api/piston/runtimes")
      .set("Origin", "https://interview.example.com")
      .set("Access-Control-Request-Method", "GET")
    expect(res.headers["access-control-allow-origin"]).toBe(
      "https://interview.example.com",
    )
  })

  it("rejects a non-allowed origin", async () => {
    const res = await request(server)
      .options("/api/piston/runtimes")
      .set("Origin", "https://evil.example.com")
      .set("Access-Control-Request-Method", "GET")
    expect(res.headers["access-control-allow-origin"]).toBeUndefined()
  })
})
```

- [ ] **Step 2: Run it — expect failure**

```bash
npm test
```

Expected: failures because (a) `server.ts` doesn't export `server`, (b) CORS is wide open, and (c) `/api/piston/runtimes` doesn't exist yet (the OPTIONS preflight may still 404 but CORS headers are what we assert).

- [ ] **Step 3: Modify `server/src/server.ts` to honor `CORS_ORIGIN` and export `server`**

At the top of the file (after `dotenv.config()`):

```ts
const CORS_ORIGIN = process.env.CORS_ORIGIN || "*"
const corsOrigins = CORS_ORIGIN === "*" ? "*" : CORS_ORIGIN.split(",").map((s) => s.trim())
```

Replace `app.use(cors())` with:

```ts
app.use(cors({ origin: corsOrigins }))
```

Replace the Socket.io server init:

```ts
const io = new Server(server, {
  cors: { origin: corsOrigins },
  maxHttpBufferSize: 1e8,
  pingTimeout: 60000,
})
```

At the bottom of the file, after `server.listen(...)`, add:

```ts
export { app, server, io }
```

- [ ] **Step 4: Run tests — expect pass**

```bash
npm test
```

Expected: both CORS tests pass.

- [ ] **Step 5: Commit**

```bash
git add server/src/server.ts server/test/cors.test.ts
git commit -m "feat(server): honor CORS_ORIGIN env var with strict allowlist"
```

---

## Task 5: Add `/api/piston` proxy router on the server

**Files:**
- Create: `server/src/piston.ts`
- Modify: `server/src/server.ts`
- Create: `server/test/piston.test.ts`
- Modify: `server/package.json` (axios dep)

The client should talk to our server, never to Piston or `emkc.org` directly. We expose a minimal proxy covering `/runtimes` and `/execute`.

- [ ] **Step 1: Add axios to server runtime deps**

From `server/`:

```bash
npm install axios
```

- [ ] **Step 2: Write failing proxy test**

Create `server/test/piston.test.ts`:

```ts
import { describe, it, expect, beforeAll, afterAll, vi } from "vitest"
import request from "supertest"
import type { Server } from "http"

vi.mock("axios", () => {
  const get = vi.fn(async (url: string) => {
    if (url.endsWith("/runtimes")) {
      return { data: [{ language: "python", version: "3.12.0", aliases: ["py"] }] }
    }
    throw new Error("unexpected get: " + url)
  })
  const post = vi.fn(async (url: string, body: any) => {
    if (url.endsWith("/execute")) {
      return { data: { run: { stdout: "hi\n", stderr: "", code: 0 }, language: body.language } }
    }
    throw new Error("unexpected post: " + url)
  })
  return { default: { create: () => ({ get, post }), get, post } }
})

let server: Server

beforeAll(async () => {
  process.env.CORS_ORIGIN = "*"
  process.env.PORT = "0"
  process.env.PISTON_URL = "http://piston-mock/api/v2"
  const mod = await import("../src/server")
  server = (mod as any).server
})

afterAll((done) => {
  server.close(() => done())
})

describe("/api/piston proxy", () => {
  it("GET /api/piston/runtimes returns upstream list", async () => {
    const res = await request(server).get("/api/piston/runtimes")
    expect(res.status).toBe(200)
    expect(res.body).toEqual([
      { language: "python", version: "3.12.0", aliases: ["py"] },
    ])
  })

  it("POST /api/piston/execute forwards body and returns result", async () => {
    const res = await request(server)
      .post("/api/piston/execute")
      .send({
        language: "python",
        version: "3.12.0",
        files: [{ name: "main.py", content: "print('hi')" }],
        stdin: "",
      })
    expect(res.status).toBe(200)
    expect(res.body.run.stdout).toBe("hi\n")
  })

  it("returns 502 when Piston is unreachable", async () => {
    const axios = (await import("axios")).default as any
    axios.get.mockRejectedValueOnce(new Error("ECONNREFUSED"))
    const res = await request(server).get("/api/piston/runtimes")
    expect(res.status).toBe(502)
  })
})
```

- [ ] **Step 3: Run test — expect fail**

```bash
npm test
```

Expected: 404s because `/api/piston/*` doesn't exist yet.

- [ ] **Step 4: Create `server/src/piston.ts`**

```ts
import { Router, Request, Response } from "express"
import axios from "axios"

const PISTON_URL = process.env.PISTON_URL || "http://localhost:2000/api/v2"

const router = Router()

router.get("/runtimes", async (_req: Request, res: Response) => {
  try {
    const r = await axios.get(`${PISTON_URL}/runtimes`)
    res.json(r.data)
  } catch (err) {
    console.error("piston /runtimes failed:", (err as Error).message)
    res.status(502).json({ error: "piston unreachable" })
  }
})

router.post("/execute", async (req: Request, res: Response) => {
  try {
    const r = await axios.post(`${PISTON_URL}/execute`, req.body)
    res.json(r.data)
  } catch (err) {
    console.error("piston /execute failed:", (err as Error).message)
    res.status(502).json({ error: "piston unreachable" })
  }
})

export default router
```

- [ ] **Step 5: Mount the router in `server/src/server.ts`**

After `app.use(cors(...))` and `app.use(express.json())`, add:

```ts
import pistonRouter from "./piston"
// ...
app.use("/api/piston", pistonRouter)
```

(Put the import with the other imports at the top.)

- [ ] **Step 6: Run tests — expect pass**

```bash
npm test
```

Expected: all three proxy tests pass, plus earlier CORS and smoke tests.

- [ ] **Step 7: Commit**

```bash
git add server/src/piston.ts server/src/server.ts server/test/piston.test.ts server/package.json server/package-lock.json
git commit -m "feat(server): add /api/piston proxy (runtimes + execute)"
```

---

## Task 6: Point the client at the server proxy

**Files:**
- Modify: `client/src/api/pistonApi.ts`

Single-line change: the client's base URL moves from a direct Piston URL to our server's proxy path.

- [ ] **Step 1: Modify `client/src/api/pistonApi.ts`**

Replace the existing content with:

```ts
import axios, { AxiosInstance } from "axios"

const backendUrl = import.meta.env.VITE_BACKEND_URL || "http://localhost:3000"
const pistonBaseUrl = `${backendUrl}/api/piston`

const instance: AxiosInstance = axios.create({
    baseURL: pistonBaseUrl,
    headers: {
        "Content-Type": "application/json",
    },
})

export default instance
```

- [ ] **Step 2: Verify dev build still compiles**

From `client/`:

```bash
npm run build
```

Expected: build succeeds. (Runtime behavior is verified end-to-end after deploy.)

- [ ] **Step 3: Commit**

```bash
git add client/src/api/pistonApi.ts
git commit -m "feat(client): route code execution via server proxy, not Piston directly"
```

---

## Task 7: Accept `VITE_BACKEND_URL` as a build arg in the client image

**Files:**
- Modify: `client/Dockerfile`

Vite inlines `import.meta.env.*` at build time, so Dokku runtime env vars don't reach the bundle. We accept it as a build arg.

- [ ] **Step 1: Modify `client/Dockerfile`**

Change the builder stage (between `FROM node:20-alpine AS builder` and `RUN npm run build`) to:

```dockerfile
FROM node:20-alpine AS builder

WORKDIR /build

COPY package*.json .

RUN npm ci

COPY . .

ARG VITE_BACKEND_URL=http://localhost:3000
ENV VITE_BACKEND_URL=$VITE_BACKEND_URL

RUN npm run build
RUN npm prune --omit=dev
```

Leave the runner stage alone.

- [ ] **Step 2: Verify build args flow through**

```bash
docker build \
  --build-arg VITE_BACKEND_URL=https://example.com \
  -t code-sync-client-test ./client
docker run --rm code-sync-client-test sh -c "grep -o 'example.com' dist/assets/*.js | head -1"
```

Expected: prints `example.com` (proof the build arg baked into the bundle).

- [ ] **Step 3: Commit**

```bash
git add client/Dockerfile
git commit -m "feat(client): accept VITE_BACKEND_URL as Docker build arg"
```

---

## Task 8: Create the `piston/` service

**Files:**
- Create: `piston/Dockerfile`
- Create: `piston/README.md`

- [ ] **Step 1: Create `piston/Dockerfile`**

```dockerfile
FROM ghcr.io/engineer-man/piston:latest

# Piston listens on 2000 by default.
EXPOSE 2000
```

(We don't pre-install Python in the image because the Piston package system stores runtimes on a mounted volume. Installing in the image would be shadowed by the volume mount on first boot.)

- [ ] **Step 2: Create `piston/README.md`**

```markdown
# interview-piston

Self-hosted [Piston](https://github.com/engineer-man/piston) code-execution
service, internal-only (no public domain). Runs privileged so it can sandbox
user code with `isolate`.

Python 3.12 is installed once after first deploy by POSTing to
`/api/v2/packages` — see `/deploy/DEPLOY.md` for the exact command.
The Python runtime is persisted via a Dokku storage mount at
`/piston/packages`, so it survives container restarts and rebuilds.
```

- [ ] **Step 3: Commit**

```bash
git add piston/
git commit -m "feat: add interview-piston Dockerfile and README"
```

---

## Task 9: Create the Dokku bootstrap script and DEPLOY.md

**Files:**
- Create: `deploy/dokku-bootstrap.sh`
- Create: `deploy/DEPLOY.md`
- Create: `deploy/nginx-websocket-note.md`

- [ ] **Step 1: Create `deploy/dokku-bootstrap.sh`**

```bash
#!/usr/bin/env bash
# Idempotent Dokku bootstrap for the interview stack.
# Run as the dokku user (or via sudo -u dokku) on the VPS.
# Usage: ./dokku-bootstrap.sh
set -euo pipefail

CLIENT=interview-client
SERVER=interview-server
PISTON=interview-piston
NET=interview-net
CLIENT_DOMAIN=interview.feofanov.dev
SERVER_DOMAIN=api.interview.feofanov.dev

have_app() { dokku apps:exists "$1" >/dev/null 2>&1; }
have_net() { dokku network:exists "$NET" >/dev/null 2>&1; }

# --- plugin ---
if ! dokku plugin:list | grep -q '^  monorepo '; then
  echo "Installing dokku-monorepo plugin (requires root)..."
  sudo dokku plugin:install https://github.com/crisward/dokku-monorepo
fi

# --- network ---
have_net || dokku network:create "$NET"

# --- apps ---
for app in "$CLIENT" "$SERVER" "$PISTON"; do
  have_app "$app" || dokku apps:create "$app"
  dokku network:set "$app" attach-post-deploy "$NET"
done

# --- monorepo subdirs ---
dokku config:set --no-restart "$CLIENT" MONOREPO_SUBDIR=client
dokku config:set --no-restart "$SERVER" MONOREPO_SUBDIR=server
dokku config:set --no-restart "$PISTON" MONOREPO_SUBDIR=piston

# --- piston: privileged + persistent package volume ---
dokku docker-options:add "$PISTON" deploy,run "--privileged"
sudo mkdir -p /var/lib/dokku/data/storage/piston
sudo chown -R dokku:dokku /var/lib/dokku/data/storage/piston
dokku storage:mount "$PISTON" /var/lib/dokku/data/storage/piston:/piston/packages

# --- runtime env ---
dokku config:set --no-restart "$SERVER" \
  CORS_ORIGIN="https://$CLIENT_DOMAIN" \
  PISTON_URL="http://$PISTON.web:2000/api/v2"

# --- client build arg (Vite bakes at build time) ---
dokku docker-options:add "$CLIENT" build \
  "--build-arg VITE_BACKEND_URL=https://$SERVER_DOMAIN"

# --- public domains + TLS ---
dokku domains:set "$CLIENT" "$CLIENT_DOMAIN"
dokku domains:set "$SERVER" "$SERVER_DOMAIN"

# letsencrypt plugin must already be installed on the host
dokku letsencrypt:enable "$CLIENT"  || echo "letsencrypt client: enable later after DNS resolves"
dokku letsencrypt:enable "$SERVER"  || echo "letsencrypt server: enable later after DNS resolves"

echo "Bootstrap complete. Next: push each app's subdir as its own remote."
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x deploy/dokku-bootstrap.sh
```

- [ ] **Step 3: Create `deploy/DEPLOY.md`**

```markdown
# Deploying the Interview Stack on Dokku

## Prerequisites on the VPS

- Dokku installed
- `letsencrypt` plugin installed: `sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git`
- DNS A records for `interview.feofanov.dev` and `api.interview.feofanov.dev`
  pointing at the VPS IP
- Your public SSH key added to the `dokku` user (`ssh-copy-id dokku@<vps>`)

## 1. Bootstrap (one-time, on the VPS)

```bash
git clone https://github.com/Ivan-Feofanov/Code-Sync.git /tmp/code-sync-bootstrap
cd /tmp/code-sync-bootstrap
./deploy/dokku-bootstrap.sh
```

This installs the `dokku-monorepo` plugin, creates the three apps, wires up
the internal network, mounts the Piston package volume, configures env vars
and domains, and attempts to issue Let's Encrypt certs.

If DNS isn't propagated yet, Let's Encrypt will fail — rerun the enable
commands later:

```bash
dokku letsencrypt:enable interview-client
dokku letsencrypt:enable interview-server
```

## 2. Add git remotes (one-time, on your laptop)

From your local clone of the fork:

```bash
git remote add dokku-client dokku@<vps-host>:interview-client
git remote add dokku-server dokku@<vps-host>:interview-server
git remote add dokku-piston dokku@<vps-host>:interview-piston
```

## 3. First deploy

Order matters — Piston first so the server's `PISTON_URL` resolves when the
server boots:

```bash
git push dokku-piston dokku-deployment:main
git push dokku-server dokku-deployment:main
git push dokku-client dokku-deployment:main
```

(If `dokku-deployment` has already been merged to `main`, push `main:main`.)

## 4. One-time: install Python in Piston

After Piston is up and healthy:

```bash
ssh dokku@<vps-host> -- run interview-server \
  sh -c "apk add --no-cache curl >/dev/null 2>&1 || true; \
         curl -sS -X POST http://interview-piston.web:2000/api/v2/packages \
         -H 'Content-Type: application/json' \
         -d '{\"language\":\"python\",\"version\":\"3.12.0\"}'"
```

Expected JSON response with `"language": "python"` and `"version": "3.12.0"`.

Verify:

```bash
curl https://api.interview.feofanov.dev/api/piston/runtimes | jq
```

Should include Python 3.12.0.

## 5. Verification

- Open `https://interview.feofanov.dev` — Code-Sync UI loads
- Create a room; open it in a second browser. Type code in one → appears in
  the other (Socket.io is working through Dokku's default nginx).
- Select Python in the language picker, type `print(2+2)`, click Run —
  output `4` appears.
- `dokku ps:restart interview-piston` — re-run Python and confirm it still
  works (volume mount persisted).

## Ongoing deploys

Any commit to the deployment branch:

```bash
git push dokku-client   dokku-deployment:main
git push dokku-server   dokku-deployment:main
git push dokku-piston   dokku-deployment:main
```

Only push the remotes whose subdirectory actually changed.
```

- [ ] **Step 4: Create `deploy/nginx-websocket-note.md`**

```markdown
# Dokku and Socket.io Websockets

Dokku's default nginx template (`nginx-vhosts` plugin, v0.24+) sets
`proxy_http_version 1.1` and the `Upgrade`/`Connection` headers needed for
websockets. No custom nginx config is required for Socket.io to work.

If you hit "websocket connection failed" in the browser, check:

```bash
dokku nginx:show-config interview-server
```

and look for `Upgrade` handling. If missing, bump the nginx-vhosts plugin.
```

- [ ] **Step 5: Commit**

```bash
git add deploy/
git commit -m "docs: Dokku bootstrap script and deployment walkthrough"
```

---

## Task 10: Push to the fork and open a PR against your own main

**Files:** none

- [ ] **Step 1: Push the branch**

```bash
git push -u origin dokku-deployment
```

- [ ] **Step 2: Open a PR for your own review**

Via `gh`:

```bash
gh pr create --fill --base main --head dokku-deployment
```

Review the diff in the GitHub UI. This is your last chance to spot issues before deploying.

- [ ] **Step 3: Merge when satisfied**

```bash
gh pr merge --squash --delete-branch
git checkout main
git pull
```

---

## Task 11: Bootstrap Dokku on the VPS

**Files:** none (runs `deploy/dokku-bootstrap.sh` on the VPS)

- [ ] **Step 1: Create DNS records**

In your DNS provider: two A records pointing at the Hetzner IP:
- `interview.feofanov.dev`
- `api.interview.feofanov.dev`

Verify: `dig +short interview.feofanov.dev` returns the VPS IP.

- [ ] **Step 2: Ensure `letsencrypt` plugin is installed on the VPS**

```bash
ssh <vps>
sudo dokku plugin:list | grep letsencrypt || \
  sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git
```

- [ ] **Step 3: Run the bootstrap script**

```bash
ssh <vps>
git clone https://github.com/Ivan-Feofanov/Code-Sync.git /tmp/code-sync-bootstrap
cd /tmp/code-sync-bootstrap
./deploy/dokku-bootstrap.sh
```

Expected output: apps created, network attached, storage mounted, env set, LE certs issued (if DNS is already propagated).

- [ ] **Step 4: Confirm state**

```bash
dokku apps:list           # shows interview-client, interview-server, interview-piston
dokku network:list        # shows interview-net
dokku storage:list interview-piston   # shows /piston/packages mount
dokku config:show interview-server    # shows CORS_ORIGIN and PISTON_URL
```

---

## Task 12: First deploy and Python install

**Files:** none

- [ ] **Step 1: Add remotes locally**

```bash
cd ~/work/Code-Sync
git remote add dokku-client dokku@<vps>:interview-client
git remote add dokku-server dokku@<vps>:interview-server
git remote add dokku-piston dokku@<vps>:interview-piston
```

- [ ] **Step 2: Deploy Piston first**

```bash
git push dokku-piston main
```

Expected: image builds from `piston/Dockerfile`, container starts. Tail logs:

```bash
ssh <vps> dokku logs interview-piston --tail
```

Look for "Piston API is now listening on 2000".

- [ ] **Step 3: Deploy server**

```bash
git push dokku-server main
```

Expected: build, start, `Listening on port <PORT>` in logs.

- [ ] **Step 4: Deploy client**

```bash
git push dokku-client main
```

Expected: build completes with `VITE_BACKEND_URL=https://api.interview.feofanov.dev` baked into the bundle.

- [ ] **Step 5: Install Python in Piston**

```bash
ssh <vps>
dokku run interview-server sh -c '\
  apk add --no-cache curl >/dev/null 2>&1 || true; \
  curl -sS -X POST http://interview-piston.web:2000/api/v2/packages \
    -H "Content-Type: application/json" \
    -d "{\"language\":\"python\",\"version\":\"3.12.0\"}"'
```

Expected: `{"language":"python","version":"3.12.0"}` (or similar success JSON).

- [ ] **Step 6: Verify runtimes endpoint**

From your laptop:

```bash
curl -s https://api.interview.feofanov.dev/api/piston/runtimes | jq
```

Expected: array containing `{"language":"python","version":"3.12.0", ...}`.

---

## Task 13: End-to-end verification

**Files:** none

- [ ] **Step 1: Load the UI**

Open `https://interview.feofanov.dev` in a browser. Expected: Code-Sync UI loads with a valid TLS cert.

- [ ] **Step 2: Multi-user collaboration check**

- Create a room with a random room ID + username
- Open the same room URL in a second browser (incognito, different username)
- Type in the editor in browser A → characters appear in browser B within ~100ms
- Send a chat message A → B
- Draw on the whiteboard A → B

Expected: all three realtime channels work.

- [ ] **Step 3: Code execution check**

- Select Python as the language
- Paste `print(sum(range(1, 101)))`
- Click Run

Expected: output pane shows `5050`.

- [ ] **Step 4: Restart resilience check**

```bash
ssh <vps> dokku ps:restart interview-piston
```

Wait ~10 seconds, then re-run the code in the browser. Expected: still works without re-installing Python (proves the storage volume mount persisted the runtime).

- [ ] **Step 5: VPS reboot check (optional but recommended)**

```bash
ssh <vps> sudo reboot
```

Wait for the box to come back (~30s). Hit `https://interview.feofanov.dev` again. Expected: everything works, TLS still valid.

---

## Self-review

1. **Spec coverage:**
   - Fork + monorepo → Task 1, Task 9 (bootstrap installs plugin)
   - Node 20 upgrade → Task 2
   - Server CORS + `/api/piston` proxy → Tasks 4, 5
   - Client build-arg for `VITE_BACKEND_URL` → Tasks 6, 7
   - Piston privileged + volume → Task 9 (bootstrap script)
   - Dokku network linking 3 apps → Task 9 (bootstrap script)
   - Two public subdomains + LE → Task 9 (bootstrap script), Task 11
   - One-time Python install → Task 12 step 5
   - Verification checklist → Task 13

2. **Placeholder scan:** no TBDs, every code block is complete, every shell command has an expected output.

3. **Type consistency:** `PISTON_URL`, `CORS_ORIGIN`, `VITE_BACKEND_URL` used identically across tasks; router path `/api/piston` consistent between server mount (Task 5), client base URL (Task 6), and test assertions (Task 5).

4. **Ordering:** Dokku first-deploy order (piston → server → client) matches the spec's first-deploy note.

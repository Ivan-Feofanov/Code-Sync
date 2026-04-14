# Deploying the Interview Stack on Dokku

## Prerequisites on the VPS

- Dokku installed
- `letsencrypt` plugin installed: `sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git`
- DNS A records for `interview.feofanov.dev` and `api.interview.feofanov.dev`
  pointing at the VPS IP
- Your public SSH key added to the `dokku` user (`ssh-copy-id dokku@<vps>`)

## 1. Bootstrap (one-time)

Run the bootstrap script from your laptop by piping it over SSH — nothing
stays on the VPS afterwards:

```bash
ssh <vps> 'bash -s' < deploy/dokku-bootstrap.sh
```

Alternative: scp the script first, then run it.

```bash
scp deploy/dokku-bootstrap.sh <vps>:/tmp/
ssh <vps> 'bash /tmp/dokku-bootstrap.sh'
```

Either way, the script installs the `dokku-monorepo` plugin, creates the
three apps, wires up the internal network, mounts the Piston package
volume, configures env vars and domains, and attempts to issue Let's
Encrypt certs.

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

# Deploying the Interview Stack on Dokku

## Prerequisites on the VPS

- Dokku installed
- `letsencrypt` plugin installed: `sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git`
- DNS A records for `<CLIENT_DOMAIN>` and `<SERVER_DOMAIN>` pointing at the VPS IP
- Your public SSH key added to the `dokku` user (`ssh-copy-id dokku@<vps>`)
- Global Let's Encrypt email set: `sudo dokku letsencrypt:set --global email you@example.com`

Choose your domains up front. Examples:

```
CLIENT_DOMAIN=interview.example.com
SERVER_DOMAIN=api.interview.example.com
```

## 1. Bootstrap (one-time)

Run the bootstrap script on the VPS with the two domain env vars set. Easiest
path — scp + run:

```bash
scp deploy/dokku-bootstrap.sh <vps>:/tmp/
ssh <vps> "CLIENT_DOMAIN=<your-client-domain> SERVER_DOMAIN=<your-server-domain> sudo -E bash /tmp/dokku-bootstrap.sh"
```

The script creates the three Dokku apps, wires up the internal network,
mounts the Piston package volume, configures env vars and domains, and
attempts to issue Let's Encrypt certs.

If DNS isn't propagated yet, Let's Encrypt will fail — rerun the enable
commands later:

```bash
sudo dokku letsencrypt:enable interview-client
sudo dokku letsencrypt:enable interview-server
```

## 2. Port mappings (one-time, after first deploys)

Dokku defaults to mirroring the container port externally. Fix both public
apps to listen on 443:

```bash
sudo dokku ports:set interview-server https:443:3000
sudo dokku ports:remove interview-server https:3000:3000
sudo dokku ports:set interview-client https:443:5173
sudo dokku ports:remove interview-client https:5173:5173
```

## 3. First deploy

Configure the GitHub repo secrets (see section 5) and push a commit — the
GitHub Action at `.github/workflows/deploy.yml` will deploy whichever app
subdirectories changed. Order matters: the workflow deploys piston, then
server, then client.

To trigger a one-shot full deploy regardless of what changed, use the "Run
workflow" button on the Actions page with `force_all=true`.

## 4. One-time: install Python in Piston

After Piston is up and healthy, on the VPS:

```bash
sudo docker run --rm --network interview-net curlimages/curl:latest \
  -sS -X POST http://interview-piston.web:2000/api/v2/packages \
  -H 'Content-Type: application/json' \
  -d '{"language":"python","version":"3.12.0"}'
```

Expected JSON response with `"language":"python"` and `"version":"3.12.0"`.
First run downloads the runtime (~10–30 s).

Verify:

```bash
curl https://<SERVER_DOMAIN>/api/piston/runtimes | jq
```

Should include Python 3.12.0.

## 5. GitHub Action secrets

The deploy workflow needs two repository secrets:

- `DOKKU_HOST` — the VPS hostname (e.g. `vps.example.com`)
- `DOKKU_SSH_KEY` — a private SSH key whose public half is authorized on the
  `dokku` user of the VPS. Generate a dedicated key pair:

  ```
  ssh-keygen -t ed25519 -f dokku-ci -N ""
  cat dokku-ci.pub | ssh <vps> "sudo dokku ssh-keys:add ci /dev/stdin"
  ```

  Paste the contents of `dokku-ci` (the private key) into the
  `DOKKU_SSH_KEY` secret. Delete both key files locally after adding.

## 6. Verification

- Open `https://<CLIENT_DOMAIN>` — Code-Sync UI loads
- Create a room; open it in a second browser. Type code in one → appears in
  the other (Socket.io works through Dokku's default nginx).
- Select Python in the language picker, type `print(2+2)`, click Run —
  output `4` appears.
- `sudo dokku ps:restart interview-piston` — re-run Python and confirm it
  still works (package volume persisted).

## Ongoing deploys

Merge to `main`. The GitHub Action deploys whichever of `client/`, `server/`,
or `piston/` changed. Manual override: use "Run workflow" with
`force_all=true`.

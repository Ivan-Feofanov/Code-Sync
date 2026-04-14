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

# --- network ---
have_net || dokku network:create "$NET"

# --- apps ---
for app in "$CLIENT" "$SERVER" "$PISTON"; do
  have_app "$app" || dokku apps:create "$app"
  dokku network:set "$app" attach-post-deploy "$NET"
done

# --- monorepo subdirs (Dokku native build-dir, no plugin needed) ---
dokku builder:set "$CLIENT" build-dir client
dokku builder:set "$SERVER" build-dir server
dokku builder:set "$PISTON" build-dir piston

# --- piston: privileged + host cgroup namespace + persistent package volume ---
# --cgroupns=host is required so Piston's entrypoint can enable cgroup v2
# subtree controllers on the host's cgroup tree; otherwise the root cgroup
# inside the container has multiple processes and the setup fails with EBUSY.
dokku docker-options:add "$PISTON" deploy,run "--privileged"
dokku docker-options:add "$PISTON" deploy,run "--cgroupns=host"
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

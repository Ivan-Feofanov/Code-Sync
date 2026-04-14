#!/usr/bin/env bash
# Idempotent Dokku bootstrap for the interview stack.
# Run as root (or via sudo) on the VPS.
#
# Required env vars:
#   CLIENT_DOMAIN  - public domain for the client, e.g. interview.example.com
#   SERVER_DOMAIN  - public domain for the server, e.g. api.interview.example.com
#
# Usage:
#   CLIENT_DOMAIN=... SERVER_DOMAIN=... sudo -E bash dokku-bootstrap.sh
set -euo pipefail

: "${CLIENT_DOMAIN:?Set CLIENT_DOMAIN env var (public domain for the client)}"
: "${SERVER_DOMAIN:?Set SERVER_DOMAIN env var (public domain for the server)}"

CLIENT=interview-client
SERVER=interview-server
PISTON=interview-piston
NET=interview-net

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

# --- piston: privileged + persistent package volume ---
# The patched entrypoint (see piston/entrypoint.sh) handles cgroup v2 setup
# correctly with the default cgroupns=private, so we only need --privileged.
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

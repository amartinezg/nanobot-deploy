#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# nanobot/scripts/setup-host.sh — One-time host bootstrap for the Nanobot service.
#
# Usage: ./nanobot/scripts/setup-host.sh <profile>
#
# <profile>: which nanobot instance to seed secrets.env from (e.g. "personal").
#
# Run this ON THE VPS, ONCE per host. Idempotent — safe to re-run.
#
# What it does:
#   1. Ensure /opt/nanobot/ directory tree exists
#   2. Clone the Nanobot upstream source if missing
#   3. Download the gog binary if missing
#   4. Verify the OAuth client_secret JSON is in place (errors with instructions
#      if missing — operator must scp it in)
#   5. Seed secrets.env from nanobot/instances/<profile>/.env.example if missing
#      (exits so user can fill it in)
#   6. Build the nanobot docker image
#
# Prerequisites:
#   - Docker installed
#   - agents-deploy repo cloned on the VPS (you're running this script from there)
#   - OAuth client_secret_*.json scp'd to /opt/nanobot[-<profile>]/client_secret.json
#
# After this script: edit /opt/nanobot/secrets.env (see nanobot/instances/<profile>/.env.example
# for keys), then run the gog OAuth dance:
#   docker exec -it nanobot gog auth credentials /home/nanobot/client_secret.json
#   docker exec -it nanobot gog auth add <email> --services gmail,drive,sheets,calendar --manual --gmail-no-send
# then run ./nanobot/scripts/deploy.sh <profile> from your laptop.
# =============================================================================

GOG_VERSION="${GOG_VERSION:-v0.14.0}"
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTANCE="${1:-}"
case "$INSTANCE" in
  -h|--help) sed -n '4,30p' "$0"; exit 0 ;;
  "") echo "Usage: $0 <profile>"; echo "Available profiles: $(ls "$VENDOR_DIR/instances" 2>/dev/null | tr '\n' ' ')"; exit 2 ;;
esac

if [ ! -d "$VENDOR_DIR/instances/$INSTANCE" ]; then
  echo "ERROR: no such profile '$INSTANCE' under $VENDOR_DIR/instances/"
  exit 1
fi
INSTANCE_DIR="$VENDOR_DIR/instances/$INSTANCE"

# Derive VPS directory per profile.
if [ "$INSTANCE" = "personal" ]; then
  NANOBOT_DIR="/opt/nanobot"
else
  NANOBOT_DIR="/opt/nanobot-$INSTANCE"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (the VPS account that owns /opt/...)"
  exit 1
fi

# --- 1. Directory tree ---
echo "==> Ensuring directory tree at $NANOBOT_DIR"
mkdir -p "$NANOBOT_DIR"/{nanobot-data,gogcli-config,playwright-cache}
chown -R 1000:1000 "$NANOBOT_DIR/nanobot-data" "$NANOBOT_DIR/gogcli-config" "$NANOBOT_DIR/playwright-cache"

# --- 2. Clone upstream Nanobot source if missing (only needed when we'll build the image) ---
if docker image inspect nanobot:local >/dev/null 2>&1; then
  echo "==> nanobot:local image already exists — skipping source clone (boost / non-builder profile)"
elif [ -d "$NANOBOT_DIR/nanobot/.git" ]; then
  echo "==> Nanobot source already cloned at $NANOBOT_DIR/nanobot/"
else
  echo "==> Cloning HKUDS/nanobot.git → $NANOBOT_DIR/nanobot/"
  git clone https://github.com/HKUDS/nanobot.git "$NANOBOT_DIR/nanobot"
fi

# --- 3. gog binary ---
GOG_BINARY="$NANOBOT_DIR/gog"
if [ -x "$GOG_BINARY" ]; then
  echo "==> gog binary already present: $(${GOG_BINARY} --version 2>&1 | head -1)"
else
  echo "==> Downloading gogcli ${GOG_VERSION}..."
  TARBALL="/tmp/gogcli.tar.gz"
  wget -qO "$TARBALL" \
    "https://github.com/steipete/gogcli/releases/download/${GOG_VERSION}/gogcli_${GOG_VERSION#v}_linux_amd64.tar.gz"
  tar -xzf "$TARBALL" -C /tmp gog
  mv /tmp/gog "$GOG_BINARY"
  rm -f "$TARBALL"
  chmod +x "$GOG_BINARY"
  chown 1000:1000 "$GOG_BINARY"
fi

# --- 4. OAuth client_secret JSON ---
CLIENT_SECRET="$NANOBOT_DIR/client_secret.json"
if [ -f "$CLIENT_SECRET" ]; then
  echo "==> OAuth client_secret already in place"
else
  echo "ERROR: no client_secret.json found at $CLIENT_SECRET"
  echo "  scp the Google OAuth client_secret_*.json from your secrets store to"
  echo "  $CLIENT_SECRET, then re-run. Required perms: chmod 600, chown 1000:1000."
  exit 1
fi

# --- 5. secrets.env seed from .env.example ---
SECRETS_ENV="$NANOBOT_DIR/secrets.env"
if [ -f "$SECRETS_ENV" ]; then
  echo "==> secrets.env already present (keys: $(grep -c '^[A-Z]' "$SECRETS_ENV"))"
else
  echo "==> Seeding $SECRETS_ENV from $INSTANCE_DIR/.env.example"
  cp "$INSTANCE_DIR/.env.example" "$SECRETS_ENV"
  chmod 600 "$SECRETS_ENV"
  echo
  echo "  Now edit $SECRETS_ENV — fill in real values for all keys."
  echo "  After that, re-run this script to continue."
  exit 0
fi

# --- 6. Deploy compose file (so we can build the image) ---
if [ ! -f "$NANOBOT_DIR/docker-compose.yml" ]; then
  echo "==> Installing initial docker-compose.yml from repo"
  cp "$INSTANCE_DIR/docker-compose.yml" "$NANOBOT_DIR/docker-compose.yml"
fi

# --- 7. Build the image (only if not already present — boost reuses personal's build) ---
if docker image inspect nanobot:local >/dev/null 2>&1; then
  echo "==> nanobot:local image already exists — skipping build"
else
  echo "==> Building nanobot image (may take ~2 min if first time)"
  (cd "$NANOBOT_DIR" && docker compose build nanobot)
fi

echo
echo "===================================================================="
echo "Setup complete. Next steps:"
echo
echo "1. If you haven't already, do the gog OAuth dance:"
echo "     docker exec -it nanobot gog auth credentials /home/nanobot/client_secret.json"
echo "     docker exec -it nanobot gog auth add \"\$(grep '^GOG_ACCOUNT=' $SECRETS_ENV | cut -d= -f2-)\" \\"
echo "       --services gmail,drive,sheets,calendar --manual --gmail-no-send"
echo
echo "2. From your laptop, run a deploy to push the latest skills/config:"
echo "     ./nanobot/scripts/deploy.sh $INSTANCE"
echo "===================================================================="

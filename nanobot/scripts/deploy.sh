#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# nanobot/scripts/deploy.sh — Push nanobot config + skills + compose to the VPS.
#
# Usage:
#   ./nanobot/scripts/deploy.sh <profile>                    # restart container
#   ./nanobot/scripts/deploy.sh <profile> --force-recreate   # recreate (needed
#                                                              after env_file or
#                                                              compose changes)
#
# <profile>: which nanobot instance to deploy (e.g. "personal", "boost").
#            Each profile maps to nanobot/instances/<profile>/.
#
# What it does:
#   1. Pre-flight: confirm /opt/nanobot/secrets.env has all required keys.
#   2. Pre-flight: run sync-skills.sh check — block if VPS has skills not in
#      the repo (the agent-skill safety net).
#   3. Hydrate config.json.template on the VPS using its local secrets.env.
#   4. rsync workspace/ (skills + any SOUL/USER/etc overrides) — NO --delete.
#      Honours an optional instances/<profile>/.deployignore (rsync exclude
#      syntax) for workspace files the agent owns on the VPS and that the
#      repo copy must never overwrite.
#   5. scp the docker-compose.yml.
#   6. chown 1000:1000 on the workspace.
#   7. Bring up nanobot + playwright. Uses --profile browser so playwright is
#      always managed alongside nanobot (it's a hard dependency for the
#      browser MCP). Default: ensure playwright is up (idempotent) then
#      `docker restart nanobot`. --force-recreate: recreate BOTH from the
#      current image + env_file + compose.
#   8. Tail logs to confirm clean boot.
# =============================================================================

VPS="${NANOBOT_VPS:?set NANOBOT_VPS, e.g. root@203.0.113.10}"
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTANCE="${1:-}"
case "$INSTANCE" in
  -h|--help) sed -n '4,24p' "$0"; exit 0 ;;
  "") echo "Usage: $0 <profile> [--force-recreate]"; echo "Available profiles: $(ls "$VENDOR_DIR/instances" 2>/dev/null | tr '\n' ' ')"; exit 2 ;;
esac
shift

if [ ! -d "$VENDOR_DIR/instances/$INSTANCE" ]; then
  echo "ERROR: no such profile '$INSTANCE' under $VENDOR_DIR/instances/"
  echo "Available: $(ls "$VENDOR_DIR/instances" 2>/dev/null | tr '\n' ' ')"
  exit 1
fi

INSTANCE_DIR="$VENDOR_DIR/instances/$INSTANCE"

# Derive VPS directory per profile: personal → /opt/nanobot (legacy), else → /opt/nanobot-<profile>.
if [ "$INSTANCE" = "personal" ]; then
  NANOBOT_DIR="${NANOBOT_DIR:-/opt/nanobot}"
else
  NANOBOT_DIR="${NANOBOT_DIR:-/opt/nanobot-$INSTANCE}"
fi

# Optional args after profile
RESTART_MODE="restart"
for arg in "$@"; do
  case "$arg" in
    --force-recreate) RESTART_MODE="recreate" ;;
    -h|--help) sed -n '4,24p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 2 ;;
  esac
done

# Required secrets.env keys read from nanobot/instances/<profile>/required-keys.txt
# (one key per line). Note: TELEGRAM_GROUP_ID is intentionally NOT required —
# it's documentation-only.
if [ ! -f "$INSTANCE_DIR/required-keys.txt" ]; then
  echo "ERROR: missing $INSTANCE_DIR/required-keys.txt"
  exit 1
fi
REQUIRED_KEYS=()
while IFS= read -r _line; do
  REQUIRED_KEYS+=("$_line")
done < <(grep -v '^[[:space:]]*$\|^[[:space:]]*#' "$INSTANCE_DIR/required-keys.txt")

echo "=== Pre-flight 1/2: check secrets.env on VPS ==="
ssh -o BatchMode=yes "$VPS" "set -a; . $NANOBOT_DIR/secrets.env; set +a; missing=(); for k in ${REQUIRED_KEYS[*]}; do v=\$(eval echo \\\$\$k); [ -z \"\$v\" ] && missing+=(\$k); done; if [ \${#missing[@]} -gt 0 ]; then echo MISSING_KEYS: \${missing[@]}; exit 1; fi; echo OK"

echo
echo "=== Pre-flight 2/2: check for unreconciled VPS-only skills ==="
"$VENDOR_DIR/scripts/sync-skills.sh" "$INSTANCE" check

echo
echo "=== 1/5: hydrate config.json.template on VPS ==="
# scp template up, then envsubst on the VPS with /opt/nanobot/secrets.env
scp -q "$INSTANCE_DIR/config.json.template" "$VPS:/tmp/nanobot-config.json.template"
ssh "$VPS" "set -a; . $NANOBOT_DIR/secrets.env; set +a; envsubst < /tmp/nanobot-config.json.template > $NANOBOT_DIR/nanobot-data/config.json && rm /tmp/nanobot-config.json.template"

echo
echo "=== 2/5: rsync workspace/ (skills + overrides, no deletes) ==="
# Files the agent maintains on the VPS live in the repo as redacted reference
# copies only. Pushing them would revert agent-learned state, so a per-instance
# .deployignore holds them back. Optional — absent for most profiles.
RSYNC_EXCLUDES=()
if [ -f "$INSTANCE_DIR/.deployignore" ]; then
  echo "    (honouring $INSTANCE/.deployignore)"
  sed 's/^/      hold back: /' <(grep -v '^[[:space:]]*$\|^[[:space:]]*#' "$INSTANCE_DIR/.deployignore")
  RSYNC_EXCLUDES+=(--exclude-from="$INSTANCE_DIR/.deployignore")
fi
rsync -av --no-perms --no-owner --no-group "${RSYNC_EXCLUDES[@]+"${RSYNC_EXCLUDES[@]}"}" \
  "$INSTANCE_DIR/workspace/" "$VPS:$NANOBOT_DIR/nanobot-data/workspace/"

echo
echo "=== 3/5: scp docker-compose.yml ==="
scp -q "$INSTANCE_DIR/docker-compose.yml" "$VPS:$NANOBOT_DIR/docker-compose.yml"

echo
echo "=== 4/5: chown 1000:1000 nanobot-data on VPS ==="
ssh "$VPS" "chown -R 1000:1000 $NANOBOT_DIR/nanobot-data"

echo
if [ "$RESTART_MODE" = "recreate" ]; then
  echo "=== 5/5: docker compose --profile browser up -d --force-recreate (nanobot + playwright) ==="
  ssh "$VPS" "cd $NANOBOT_DIR && docker compose --profile browser up -d --force-recreate"
else
  echo "=== 5/5: ensure playwright up, then restart nanobot ==="
  ssh "$VPS" "cd $NANOBOT_DIR && docker compose --profile browser up -d playwright && docker compose restart nanobot"
fi

echo
echo "=== Boot verification (10s wait, then log grep) ==="
sleep 10
ssh "$VPS" "cd $NANOBOT_DIR && docker compose logs nanobot --since 15s 2>&1 | grep -E 'MCP server|bot @|Telegram channel enabled' | tail -5"

echo
echo "Deploy complete."

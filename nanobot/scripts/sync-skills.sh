#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# nanobot/scripts/sync-skills.sh — Reconcile VPS workspace state with the repo.
#
# The Nanobot agent can create new SKILL.md files on its own in the deployed
# workspace at /opt/nanobot/nanobot-data/workspace/skills/<name>/. A naive
# rsync-with-delete deploy would silently destroy those. This script lets you
# (1) capture them to nanobot/debug/.nanobot/ for review, (2) see what's drifted
# from the repo, and (3) hard-block deploys when there's unreconciled drift.
#
# `pull` excludes agent runtime artifacts that are regenerable on the VPS and
# should never land on a laptop: .pylibs/ (pip packages, ~160 MB), the
# .agendapro-* session credentials, and generated *.png charts.
#
# Usage:
#   ./nanobot/scripts/sync-skills.sh <profile> pull    # rsync VPS → debug/.nanobot/
#   ./nanobot/scripts/sync-skills.sh <profile> diff    # list VPS-only skill names
#   ./nanobot/scripts/sync-skills.sh <profile> check   # exit nonzero if drift
#                                                        # (deploy.sh runs this)
#
# <profile>: which nanobot instance to reconcile against (e.g. "personal").
# =============================================================================

VPS="${NANOBOT_VPS:?set NANOBOT_VPS, e.g. root@203.0.113.10}"
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTANCE="${1:-}"
CMD="${2:-}"

case "$INSTANCE" in
  -h|--help) sed -n '4,20p' "$0"; exit 0 ;;
  "") echo "Usage: $0 <profile> <pull|diff|check>"; echo "Available profiles: $(ls "$VENDOR_DIR/instances" 2>/dev/null | tr '\n' ' ')"; exit 2 ;;
esac

if [ ! -d "$VENDOR_DIR/instances/$INSTANCE" ]; then
  echo "ERROR: no such profile '$INSTANCE' under $VENDOR_DIR/instances/"
  exit 1
fi

if [ -z "$CMD" ]; then
  echo "Usage: $0 $INSTANCE <pull|diff|check>"
  exit 2
fi

# Derive VPS directory + debug mirror per profile.
if [ "$INSTANCE" = "personal" ]; then
  NANOBOT_DIR="${NANOBOT_DIR:-/opt/nanobot}"
  DEBUG_DIR="$VENDOR_DIR/debug/.nanobot"
else
  NANOBOT_DIR="${NANOBOT_DIR:-/opt/nanobot-$INSTANCE}"
  DEBUG_DIR="$VENDOR_DIR/debug/.nanobot-$INSTANCE"
fi

REPO_SKILLS_DIR="$VENDOR_DIR/instances/$INSTANCE/workspace/skills"

# ---- diff: list skill dirs that are on VPS but not in repo ----
_diff_skills() {
  local vps_skills repo_skills
  vps_skills="$(ssh -o BatchMode=yes "$VPS" "ls $NANOBOT_DIR/nanobot-data/workspace/skills/ 2>/dev/null" | sort)"
  if [ -d "$REPO_SKILLS_DIR" ]; then
    repo_skills="$(ls "$REPO_SKILLS_DIR" 2>/dev/null | sort)"
  else
    repo_skills=""
  fi
  comm -23 <(echo "$vps_skills") <(echo "$repo_skills")
}

case "$CMD" in
  pull)
    echo "==> Pulling VPS workspace → $DEBUG_DIR/workspace/"
    mkdir -p "$DEBUG_DIR/workspace"
    rsync -av \
      --exclude='sessions/' \
      --exclude='memory/' \
      --exclude='cron/' \
      --exclude='.nanobot/' \
      --exclude='.git/' \
      --exclude='.pylibs/' \
      --exclude='.agendapro-token' \
      --exclude='.agendapro-cookies.txt' \
      --exclude='*.png' \
      "$VPS:$NANOBOT_DIR/nanobot-data/workspace/" "$DEBUG_DIR/workspace/"
    echo "==> Done. Review with: ls $DEBUG_DIR/workspace/skills/"
    ;;

  diff)
    drift="$(_diff_skills)"
    if [ -z "$drift" ]; then
      echo "Clean — no VPS-only skills."
    else
      echo "VPS has skills not in repo (nanobot/instances/$INSTANCE/workspace/skills/):"
      echo "$drift" | sed 's/^/  - /'
    fi
    ;;

  check)
    drift="$(_diff_skills)"
    if [ -n "$drift" ]; then
      echo "ERROR: VPS has unreconciled skills:" >&2
      echo "$drift" | sed 's/^/  - /' >&2
      echo "" >&2
      echo "To resolve:" >&2
      echo "  1. ./nanobot/scripts/sync-skills.sh $INSTANCE pull" >&2
      echo "  2. Review ${DEBUG_DIR#$VENDOR_DIR/}/workspace/skills/<name>/" >&2
      echo "  3. Promote anything worth keeping to nanobot/instances/$INSTANCE/workspace/skills/," >&2
      echo "     OR ssh in and delete it from $NANOBOT_DIR/nanobot-data/workspace/skills/" >&2
      echo "  4. Re-run the deploy." >&2
      exit 1
    fi
    echo "OK — no drift between VPS and repo."
    ;;

  *)
    echo "Unknown command: $CMD"
    echo "Usage: $0 $INSTANCE <pull|diff|check>"
    exit 2
    ;;
esac

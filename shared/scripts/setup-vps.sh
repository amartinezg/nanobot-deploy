#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-vps.sh — System setup for a fresh Hetzner VPS (Ubuntu 24.04)
# =============================================================================

SWAP_SIZE="${SWAP_SIZE:-1G}"

echo "==> Updating system packages..."
apt update && apt upgrade -y
apt install -y ufw curl git wget jq

echo "==> Configuring UFW..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

if [ ! -f /swapfile ]; then
  echo "==> Creating ${SWAP_SIZE} swap..."
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "==> Swap already exists, skipping"
fi

if command -v docker &>/dev/null; then
  echo "==> Docker already installed: $(docker --version)"
else
  echo "==> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
fi

echo ""
echo "==> VPS setup complete. Next: ./scripts/setup-openclaw.sh"

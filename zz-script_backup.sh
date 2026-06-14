#!/bin/bash
set -euo pipefail

# --- config ---
USER_NAME="adler"
USER_HOME="/home/$USER_NAME"
ROOT_DIR="$USER_HOME/homelab/containers"
TEMP_BASE="$USER_HOME/homelab/backup/containers"

# Creates a folder like "2026-03-21"
BACKUP_DATE="$(date +%F)"
TEMP_DIR="$TEMP_BASE/$BACKUP_DATE"

# Windows target (Unused in this snippet, but kept for your config)
# WINDOWS_HOST="100.101.64.105"
# WINDOWS_USER="crackano"
# WINDOWS_PATH="D:/homelab/backup"
# --------------

# Ensure root execution
if [ "$(id -u)" -ne 0 ]; then
	echo "❌ This script must be run as root (use sudo)."
	exit 1
fi

echo "📁 Creating backup directory:"
echo "   $TEMP_DIR"
mkdir -p "$TEMP_DIR"

echo "🔍 Searching for docker-compose files..."
# Find all compose files and get their unique parent directories
mapfile -t COMPOSE_DIRS < <(
	find "$ROOT_DIR" -type f \( -name docker-compose.yml -o -name compose.yml \) \
		-exec dirname {} \; | sort -u
)

if [ ${#COMPOSE_DIRS[@]} -eq 0 ]; then
	echo "❌ No docker-compose files found. Exiting."
	exit 1
fi

echo "🛑 Stopping containers..."
for dir in "${COMPOSE_DIRS[@]}"; do
	echo "   ⏹ Stopping: $dir"
	(cd "$dir" && docker compose down)
done

echo "📦 Backing up data (preserving exact permissions)..."
# The -a flag preserves permissions, ownership, and timestamps natively
rsync -a "$ROOT_DIR/" "$TEMP_DIR/"

echo "🚀 Restarting containers..."
for dir in "${COMPOSE_DIRS[@]}"; do
	echo "   ▶ Starting: $dir"
	(cd "$dir" && docker compose up -d)
done

echo "✅ Backup complete!"
echo "📍 Location: $TEMP_DIR"

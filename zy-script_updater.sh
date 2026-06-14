#!/bin/bash
set -u

# --- config ---
# The root folder where all your container folders live
ROOT_DIR="$HOME/homelab/containers"

# Folders to explicitly skip (separated by |)
EXCLUDE_PATTERN= #"pihole|nginx|ollama|jdownloader"
# --------------

echo "🚀 Starting Homelab Update (Skipping: $EXCLUDE_PATTERN)"
echo "---------------------------------------------------"

# 1. Find all compose files
# 2. Filter out paths containing our excluded names
# 3. Limit to 3 levels deep (~/homelab/containers/category/app/compose.yml)
mapfile -t COMPOSE_FILES < <(
	find "$ROOT_DIR" -maxdepth 3 -type f \( -name "docker-compose.yml" -o -name "compose.yml" \) |
		grep -vE "$EXCLUDE_PATTERN"
)

if [ ${#COMPOSE_FILES[@]} -eq 0 ]; then
	echo "❌ No eligible compose files found. Check your paths!"
	exit 1
fi

for file in "${COMPOSE_FILES[@]}"; do
	dir=$(dirname "$file")
	app_name=$(basename "$dir")

	echo "📦 Processing: $app_name ($dir)"

	# Move into the directory to run commands
	cd "$dir" || continue

	echo "  ⬇️ Pulling latest images..."
	docker compose pull >/dev/null 2>&1

	echo "  ⏹ Stopping old version..."
	docker compose down >/dev/null 2>&1

	echo "  ▶ Starting new version..."
	docker compose up -d >/dev/null 2>&1

	echo "  ✅ Done with $app_name"
	echo "---------------------------------------------------"
done

echo "🧹 Cleaning up old, unused images..."
docker image prune -af

echo "✨ All eligible containers are now up to date!"

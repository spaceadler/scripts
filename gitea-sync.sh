#!/usr/bin/env bash

# ==============================================================================
# Gitea Mass Sync Script
# Fetches and clones/pulls all repositories for a user from a Gitea instance.
# ==============================================================================

GITEA_URL="https://git.spaceadler.com"
USERNAME="spaceadler"
TARGET_DIR="${1:-.}" # Defaults to current directory if no argument is given
CLONE_METHOD="https"   # Set to "https" if you prefer HTTPS cloning

echo "==> Fetching repositories for user: $USERNAME from $GITEA_URL"

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it (e.g., sudo pacman -S jq)."
    exit 1
fi

# Fetch repository list via Gitea's public API
# (Note: If your repos are private, you will need to add a token header: -H "Authorization: token YOUR_TOKEN")
API_RESPONSE=$(curl -s -f "$GITEA_URL/api/v1/users/$USERNAME/repos")

if [ $? -ne 0 ]; then
    echo "Error: Failed to reach Gitea API or user not found."
    exit 1
fi

# Parse the URLs based on preference
if [ "$CLONE_METHOD" = "ssh" ]; then
    URLS=$(echo "$API_RESPONSE" | jq -r '.[].ssh_url')
else
    URLS=$(echo "$API_RESPONSE" | jq -r '.[].clone_url')
fi

# Check if we got any valid URLs
if [ -z "$URLS" ] || [ "$URLS" = "null" ]; then
    echo "No repositories found for user $USERNAME."
    exit 0
fi

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR" || exit 1

for url in $URLS; do
    # Extract the repository name from the URL (e.g., git@git.../repo.git -> repo)
    repo_name=$(basename "$url" .git)
    
    if [ -d "$repo_name/.git" ]; then
        echo "--------------------------------------------------"
        echo "[*] $repo_name already exists. Pulling latest changes..."
        git -C "$repo_name" pull
    else
        echo "--------------------------------------------------"
        echo "[*] Cloning $repo_name..."
        git clone "$url"
    fi
done

echo "=================================================="
echo "==> Sync complete!"

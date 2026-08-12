#!/usr/bin/env bash

# ==============================================================================
# Fix Git Remotes Script
# Scans all subdirectories and updates any git remote URLs pointing to 
# git.spaceadler.local to point to git.spaceadler.com.
# ==============================================================================

TARGET_DIR="${1:-.}"

echo "Scanning $TARGET_DIR for outdated git remotes..."

cd "$TARGET_DIR" || exit 1

count=0

# Loop through all directories
for dir in */; do
    # Check if it's a git repository
    if [ -d "${dir}.git" ]; then
        # Get the current remote URL
        current_url=$(git -C "$dir" remote get-url origin 2>/dev/null)
        
        # If the URL contains .local, fix it
        if [[ "$current_url" == *".local"* ]]; then
            new_url="${current_url/.local/.com}"
            echo "[*] Fixing ${dir%/}:"
            echo "    Old: $current_url"
            echo "    New: $new_url"
            
            git -C "$dir" remote set-url origin "$new_url"
            ((count++))
        fi
    fi
done

echo "--------------------------------------------------"
if [ $count -eq 0 ]; then
    echo "No outdated .local remotes found!"
else
    echo "Fixed $count repositories."
fi

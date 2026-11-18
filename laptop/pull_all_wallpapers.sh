#!/bin/bash

# --- CONFIG ---
# Wallpaper Engine Steam ID is 431960
SOURCE_DIR="$HOME/.local/share/Steam/steamapps/workshop/content/431960"
TARGET_DIR="$HOME/Pictures/Wallpapers/Steam"
# --------------

# 1. Create target directory if it doesn't exist
mkdir -p "$TARGET_DIR"

echo "🔄 Syncing Steam Wallpapers..."

# 2. The Harvester: Link new video/image files
# We use 'ln -sf' to force overwrite links in case of updates
find "$SOURCE_DIR" -type f \
        \( -name "*.mp4" -o -name "*.webm" -o -name "*.gif" -o -name "*.jpg" -o -name "*.png" \) \
        -exec ln -sf {} "$TARGET_DIR/" \;

# 3. The Garbage Collector: Remove broken links
# (Links that point to files you deleted/unsubscribed from)
echo "🧹 Cleaning up broken links..."
find "$TARGET_DIR" -xtype l -delete

echo "✨ Wallpapers synced: $(ls "$TARGET_DIR" | wc -l) files ready."

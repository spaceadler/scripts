#!/bin/bash

# Define the exact source and destination paths
SOURCE_DIR="$HOME/homelab/storage/Media/Music"
DEST_DIR="$HOME/.kodi/userdata/playlists/music"

# 1. Ensure the destination folder actually exists (creates it if it doesn't)
mkdir -p "$DEST_DIR"

echo "Hunting down .m3u8 files in $SOURCE_DIR..."

# 2. Find all .m3u8 files (even hidden in subfolders) and copy them to the destination
find "$SOURCE_DIR" -type f -name "*.m3u8" -exec cp "{}" "$DEST_DIR/" \;

# Count how many files were copied to verify
FILE_COUNT=$(ls -1q "$DEST_DIR"/*.m3u8 2>/dev/null | wc -l)

echo "Success! Copied $FILE_COUNT playlist(s) to Kodi."

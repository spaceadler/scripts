#!/bin/bash
set -euo pipefail

# --- Configuration ---
# The parent folder containing all snapshots
SNAPSHOT_ROOT="/timeshift/snapshots"

# Remote Raspberry Pi Details
REMOTE_USER="adler"
REMOTE_IP="100.124.254.50"
REMOTE_DIR="~/homelab/backup/spacedeck/snapshots"
# ---------------------

if [ "$(id -u)" -ne 0 ]; then
        echo "❌ This script must be run as root (sudo)."
        exit 1
fi

echo "📡 Pinging Raspberry Pi ($REMOTE_IP)..."
if ! ping -c 1 -W 2 "$REMOTE_IP" &>/dev/null; then
        echo "❌ Error: Raspberry Pi is unreachable. Aborting."
        exit 1
fi

# Loop through every directory inside the snapshots folder
for SNAPSHOT in "$SNAPSHOT_ROOT"/*; do

        # Check if it is actually a directory (skip random files)
        if [ -d "$SNAPSHOT" ]; then
                FOLDER_NAME=$(basename "$SNAPSHOT")

                echo "---------------------------------------------------"
                echo "🚀 Processing: $FOLDER_NAME"

                # 1. The Beam
                if rsync -avz --progress "$SNAPSHOT" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"; then
                        echo "✅ Transfer Verified: $FOLDER_NAME"

                        # 2. The Delete (Only runs if rsync succeeded)
                        echo "🗑️  Deleting local copy..."
                        rm -rf "$SNAPSHOT"
                        echo "✨ Space reclaimed."
                else
                        echo "❌ FAILED to transfer $FOLDER_NAME"
                        echo "⚠️  Skipping delete for safety."
                        # Optional: exit 1 # Uncomment to stop the whole script on first error
                fi
        fi
done

echo "---------------------------------------------------"
echo "🎉 All snapshots processed."

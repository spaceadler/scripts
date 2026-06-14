#!/bin/bash

# --- CONFIGURATION ---
TARGET_USER="adler"
# ---------------------

# Get the User's ID (usually 1000)
USER_ID=$(id -u $TARGET_USER)

# Define the Runtime Directory (Standard Wayland Location)
# This is where Hyprland hides its socket
RUNTIME_DIR="/run/user/$USER_ID"

# Helper: Find the Hyprland Instance Signature (HIS)
# It's a random string directory inside $XDG_RUNTIME_DIR/hypr/
get_signature() {
        # Check the standard location (/run/user/1000/hypr/)
        if [ -d "$RUNTIME_DIR/hypr" ]; then
                # List the directory, ignore .lock files, pick the first one
                ls -1 "$RUNTIME_DIR/hypr/" | grep -v "\.lock" | head -n 1
                return
        fi

        # Fallback to legacy location (/tmp/hypr/) just in case
        if [ -d "/tmp/hypr" ]; then
                ls -1 /tmp/hypr/ | grep -v "\.lock" | head -n 1
                return
        fi
}

# Store the signature in a variable
HIS=$(get_signature)

# Helper function to send commands
hypr_cmd() {
        # If no signature found, exit to prevent errors
        if [ -z "$HIS" ]; then
                echo "Error: Could not find Hyprland Signature."
                return
        fi

        # Run hyprctl as the user, pointing to the specific instance
        sudo -u $TARGET_USER \
                HYPRLAND_INSTANCE_SIGNATURE="$HIS" \
                XDG_RUNTIME_DIR="$RUNTIME_DIR" \
                /usr/bin/hyprctl keyword "$1" "$2"
}

# --- LOGIC ---

if [ "$1" == "battery" ]; then
        # --- POWER SAVING MODE ---

        # 1. Kill Vampires
        sudo -u $TARGET_USER XDG_RUNTIME_DIR=$RUNTIME_DIR systemctl --user stop syncthing

        # 2. Kill Eyecandy
        hypr_cmd decoration:blur:enabled false
        hypr_cmd animations:enabled false

elif [ "$1" == "ac" ]; then
        # --- PERFORMANCE MODE ---

        # 1. Restore Vampires
        sudo -u $TARGET_USER XDG_RUNTIME_DIR=$RUNTIME_DIR systemctl --user start syncthing

        # 2. Enable Eyecandy
        hypr_cmd decoration:blur:enabled true
        hypr_cmd animations:enabled true

fi

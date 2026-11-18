#!/bin/bash

# --- CONFIG ---
# The folder where your branding text files live

DIR="$HOME/.config/omarchy/branding/"
# --------------

cd "$DIR" || exit 1

# Logic:
# Checks the 'screensaver' state to determine the current cycle.
# Applies the switch to BOTH the screensaver and the about text.

if [ -f "screensaver.eagle" ]; then
        # State: SPACE is currently active (since Eagle is waiting).
        # Action: Switch EVERYTHING to EAGLE.

        # 1. Flip Screensaver
        mv "screensaver.txt" "screensaver.space"
        mv "screensaver.eagle" "screensaver.txt"

        # 2. Flip About Text
        mv "about.txt" "about.space"
        mv "about.eagle" "about.txt"

        echo "Switched SYSTEM to EAGLE identity."

elif [ -f "screensaver.space" ]; then
        # State: EAGLE is currently active (since Space is waiting).
        # Action: Switch EVERYTHING to SPACE.

        # 1. Flip Screensaver
        mv "screensaver.txt" "screensaver.eagle"
        mv "screensaver.space" "screensaver.txt"

        # 2. Flip About Text
        mv "about.txt" "about.eagle"
        mv "about.space" "about.txt"

        echo "Switched SYSTEM to SPACE identity."

else
        # Failsafe
        echo "Error: Could not determine state. Check if files are missing."
fi

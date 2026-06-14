#!/bin/bash

# === REPLACE THIS WITH YOUR BLACKBERRY MAC ADDRESS ===
BB_MAC="68:ED:43:13:7E:A1"
# =====================================================

CHANNEL=1

echo "🚀 Initializing spaceberry Link..."

# 1. Kill Interference
echo "🛡️  Stopping interfering services..."
sudo systemctl stop ModemManager # Arch enemy of manual ppp
sudo killall pppd 2>/dev/null
sudo rfcomm release 0 2>/dev/null
sudo rfcomm release all

echo "🔔 Waking up the BlackBerry Radio..."
sudo l2ping -c 1 -t 2 $BB_MAC >/dev/null 2>&1

if [ $? -eq 0 ]; then
        echo "✅ Target Acquired."
else
        echo "⚠️ Target Sleeping... Retrying Wake-Up."
        sudo l2ping -c 3 -f $BB_MAC >/dev/null 2>&1
fi

# 2. Bind Bluetooth
echo "🔗 Binding to BlackBerry ($BB_MAC)..."
sudo rfcomm bind 0 $BB_MAC $CHANNEL

# Wait for binding
sleep 5

# -----------------------------------------------------------
# STABILIZED CONNECTION LOGIC
# -----------------------------------------------------------

# 1. THE SETTLE: Wait for the kernel <-> bluetooth handshake
if [ -e "/dev/rfcomm0" ]; then
        echo "✅ Modem found at /dev/rfcomm0"

        echo "⏳ Letting the BlackBerry breathe (Sleeping 3s)..."
        sleep 3
else
        echo "❌ Error: Could not bind /dev/rfcomm0. Check Bluetooth."
        exit 1
fi

# 2. THE RETRY LOOP: Try 3 times to hold the connection
MAX_RETRIES=3
COUNT=1

while [ $COUNT -le $MAX_RETRIES ]; do
        echo "🌍 Dialing... (Attempt $COUNT of $MAX_RETRIES)"

        # We add 'connect-delay 2000' (2 seconds) to let the serial port flush
        sudo pppd /dev/rfcomm0 115200 \
                call spaceberry \
                nodetach \
                connect-delay 2000 \
                lcp-echo-interval 10 \
                lcp-echo-failure 3

        # Check if pppd exited with success (0) or if we killed it
        if [ $? -eq 0 ]; then
                echo "🎉 Connection closed cleanly."
                break
        else
                echo "⚠️ Connection dropped or failed."

                if [ $COUNT -lt $MAX_RETRIES ]; then
                        echo "💤 Cooling down radio for 5 seconds..."
                        sleep 5
                        ((COUNT++))
                else
                        echo "⚠️Maximum retries reached. Check your antenna."
                        break
                fi
        fi
done

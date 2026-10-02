#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/build"
APP_PATH="$BUILD_DIR/MeloNX.app"

DO_SIGN=false
NO_BUILD=false

for arg in "$@"; do
    if [ "$arg" == "--sign" ]; then
        DO_SIGN=true
    elif [ "$arg" == "--no-build" ]; then
        NO_BUILD=true
    fi
done

# Step 1: Ensure app is built and installed
if [ "$NO_BUILD" = false ] || [ ! -d "$APP_PATH" ]; then
    if [ "$DO_SIGN" = true ]; then
        "$SCRIPT_DIR/install.sh" --sign
    else
        "$SCRIPT_DIR/install.sh"
    fi
fi

echo "=== Identifying Connected iOS Device (USB & Remote Wi-Fi) ==="
TMP_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$TMP_JSON" >/dev/null 2>&1 || true

DEVICE_ID="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
devices = data.get("result",{}).get("devices",[])

def rank(d):
    hw = d.get("hardwareProperties",{})
    conn = d.get("connectionProperties",{})
    dev = d.get("deviceProperties",{})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical":
        return -1
    if conn.get("pairingState") != "paired":
        return -1
    score = 10
    if conn.get("tunnelState") == "connected":
        score += 50
    if conn.get("transportType") in ["wired", "usb"]:
        score += 30
    elif conn.get("transportType") in ["localNetwork", "net", "network"]:
        score += 20
    if dev.get("developerModeStatus") == "enabled":
        score += 5
    return score

valid = [(rank(d), d) for d in devices if rank(d) > 0]
valid.sort(key=lambda x: x[0], reverse=True)
if valid:
    print(valid[0][1].get("identifier", ""))
' "$TMP_JSON" 2>/dev/null || true)"

DEVICE_NAME="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
devices = data.get("result",{}).get("devices",[])

def rank(d):
    hw = d.get("hardwareProperties",{})
    conn = d.get("connectionProperties",{})
    dev = d.get("deviceProperties",{})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical":
        return -1
    if conn.get("pairingState") != "paired":
        return -1
    score = 10
    if conn.get("tunnelState") == "connected":
        score += 50
    if conn.get("transportType") in ["wired", "usb"]:
        score += 30
    elif conn.get("transportType") in ["localNetwork", "net", "network"]:
        score += 20
    if dev.get("developerModeStatus") == "enabled":
        score += 5
    return score

valid = [(rank(d), d) for d in devices if rank(d) > 0]
valid.sort(key=lambda x: x[0], reverse=True)
if valid:
    print(valid[0][1].get("deviceProperties",{}).get("name", "iOS Device"))
' "$TMP_JSON" 2>/dev/null || true)"
rm -f "$TMP_JSON"

if [ -z "$DEVICE_ID" ]; then
    echo "No connected iOS device found via devicectl."
    if command -v ios-deploy >/dev/null 2>&1; then
        echo "Attempting launch via ios-deploy..."
        exec ios-deploy --debug --bundle "$APP_PATH"
    fi
    exit 1
fi

# Step 3: Extract Bundle ID from Info.plist
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist" 2>/dev/null || echo "games.jvrcruz.MeloNX")"

echo "=========================================================="
echo " Launching MeloNX ($BUNDLE_ID)"
echo " Device: $DEVICE_NAME ($DEVICE_ID)"
echo " Streaming debug console logs..."
echo "=========================================================="

xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    --console \
    "$BUNDLE_ID"

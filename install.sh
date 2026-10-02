#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/build"
APP_PATH="$BUILD_DIR/MeloNX.app"
IPA_PATH="$BUILD_DIR/MeloNX.ipa"

CONFIG="Release"
NO_BUILD=false
for arg in "$@"; do
    if [ "$arg" == "--no-build" ]; then
        NO_BUILD=true
    elif [ "$arg" == "--debug" ]; then
        CONFIG="Debug"
    elif [ "$arg" == "--release" ]; then
        CONFIG="Release"
    fi
done

if [ "$NO_BUILD" = false ]; then
    echo "=== Building MeloNX App (Signed, $CONFIG Configuration, Development Signing) ==="
    "$SCRIPT_DIR/build.sh" --sign --configuration "$CONFIG"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: MeloNX.app not found at $APP_PATH"
    exit 1
fi

echo "=== Resolving Development Signing Identity & Provisioning Profile ==="
INFO_ENV="$(python3 -c '
import os, glob, plistlib, subprocess, re, sys

team_pattern = "joão cruz"
team_pattern_alt = "joao cruz"
bundle_id = "games.jvrcruz.MeloNX"
app_path = sys.argv[1]
build_dir = sys.argv[2]

# 1. Find Development Certificate
cert_out = subprocess.check_output(["security", "find-identity", "-p", "codesigning", "-v"]).decode("utf-8")
matches = re.findall(r"([0-9A-F]{40})\s+\"Apple Development:\s*([^\"]+)\"", cert_out)
selected_cert = None
for sha, name in matches:
    if team_pattern in name.lower() or team_pattern_alt in name.lower():
        selected_cert = (sha, name)
        break
if not selected_cert and matches:
    selected_cert = matches[0]

if not selected_cert:
    print("ERROR: No valid Apple Development certificate found.", file=sys.stderr)
    sys.exit(1)

# 2. Find Provisioning Profile for Team and Bundle ID
profile_dirs = [
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
]

selected_profile = None
for pdir in profile_dirs:
    for f in glob.glob(os.path.join(pdir, "*.mobileprovision")):
        try:
            out = subprocess.check_output(["security", "cms", "-D", "-i", f], stderr=subprocess.DEVNULL)
            plist = plistlib.loads(out)
            team_name = plist.get("TeamName", "").lower()
            ent = plist.get("Entitlements", {})
            app_id = ent.get("application-identifier", "")
            if (team_pattern in team_name or team_pattern_alt in team_name) and (bundle_id in app_id):
                selected_profile = (f, plist)
                break
        except Exception:
            pass
    if selected_profile:
        break

if not selected_profile:
    print("ERROR: No matching provisioning profile found for MeloNX and Team João Cruz.", file=sys.stderr)
    sys.exit(1)

prof_path, plist = selected_profile
entitlements = plist.get("Entitlements", {})
ent_path = os.path.join(build_dir, "entitlements.plist")
with open(ent_path, "wb") as f:
    plistlib.dump(entitlements, f)

# Copy profile into app bundle
emb_path = os.path.join(app_path, "embedded.mobileprovision")
with open(prof_path, "rb") as src_f, open(emb_path, "wb") as dst_f:
    dst_f.write(src_f.read())

print(f"export CERT_SHA=\"{selected_cert[0]}\"")
print(f"export CERT_NAME=\"{selected_cert[1]}\"")
print(f"export PROFILE_PATH=\"{prof_path}\"")
print(f"export ENTITLEMENTS_PATH=\"{ent_path}\"")
' "$APP_PATH" "$BUILD_DIR")"

eval "$INFO_ENV"

echo "Signing Certificate: Apple Development: $CERT_NAME ($CERT_SHA)"
echo "Provisioning Profile: $PROFILE_PATH"

echo "=== Signing Embedded Frameworks & Dylibs ==="
if [ -d "$APP_PATH/Frameworks" ]; then
    for item in "$APP_PATH/Frameworks/"*; do
        if [ -d "$item" ] || [[ "$item" == *.dylib ]]; then
            codesign --force --sign "$CERT_SHA" --timestamp=none "$item"
        fi
    done
fi

for item in "$APP_PATH/"*.dylib; do
    if [ -f "$item" ]; then
        codesign --force --sign "$CERT_SHA" --timestamp=none "$item"
    fi
done

echo "=== Signing MeloNX App Bundle ==="
codesign --force --sign "$CERT_SHA" --timestamp=none --entitlements "$ENTITLEMENTS_PATH" --generate-entitlement-der "$APP_PATH"

echo "=== Verifying Code Signature ==="
codesign --verify --deep --strict --verbose=1 "$APP_PATH"

echo "=== Packaging Signed IPA ==="
TMP_DIR="$(mktemp -d)"
PAYLOAD_DIR="$TMP_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"
rm -f "$IPA_PATH"
(cd "$TMP_DIR" && zip -qr "$IPA_PATH" Payload)
rm -rf "$TMP_DIR"

echo "Signed IPA Created: $IPA_PATH"

echo "=== Searching for Connected iOS Devices (USB & Remote Wi-Fi) ==="
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
    echo "No connected iOS device detected via devicectl."
    echo "The signed IPA is available at: $IPA_PATH"
    echo "You can install it manually using devicectl or your preferred installer."
    exit 0
fi

echo "Connected Device: $DEVICE_NAME ($DEVICE_ID)"
echo "=== Installing Signed IPA to Device ==="

xcrun devicectl device install app --device "$DEVICE_ID" "$IPA_PATH"

echo "=== Installation Complete! ==="
echo "MeloNX has been successfully installed on $DEVICE_NAME from $IPA_PATH."

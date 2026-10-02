#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/build"
APP_PATH="$BUILD_DIR/MeloNX.app"

DO_SIGN=false
for arg in "$@"; do
    if [ "$arg" == "--sign" ]; then
        DO_SIGN=true
    fi
done

if [ "$DO_SIGN" = true ]; then
    IPA_PATH="$BUILD_DIR/MeloNX.ipa"
    echo "=== Packaging Signed IPA for Team João Cruz (Apple Development) ==="
    "$SCRIPT_DIR/install.sh" --no-build
    echo "=== Signed IPA Ready! ==="
    echo "IPA Location: $IPA_PATH"
else
    IPA_PATH="$BUILD_DIR/MeloNX-unsigned.ipa"
    echo "=== Ensuring MeloNX App is Built ==="
    "$SCRIPT_DIR/build.sh"

    echo "=== Preparing Unsigned IPA for Sideloading ==="
    TMP_DIR="$(mktemp -d)"
    PAYLOAD_DIR="$TMP_DIR/Payload"
    mkdir -p "$PAYLOAD_DIR"

    # Copy built MeloNX.app to Payload
    cp -R "$BUILD_DIR/MeloNX.app" "$PAYLOAD_DIR/MeloNX.app"

    # Clean any existing signature metadata to ensure clean sideloading
    rm -rf "$PAYLOAD_DIR/MeloNX.app/_CodeSignature"
    rm -f "$PAYLOAD_DIR/MeloNX.app/embedded.mobileprovision"

    # Package into unsigned .ipa
    (cd "$TMP_DIR" && zip -qr "$IPA_PATH" Payload)
    rm -rf "$TMP_DIR"

    echo "=== Unsigned IPA Ready! ==="
    echo "IPA Location: $IPA_PATH"
    echo "You can now install this file using AltStore, SideStore, Sideloadly, LiveContainer, or TrollStore."
fi

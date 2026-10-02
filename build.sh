#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"

echo "=== Building Real C# Ryujinx Core Library ==="
export DOTNET_ROOT="/usr/local/share/dotnet"
export PATH="/usr/local/share/dotnet:/opt/homebrew/bin:$PATH"

DOTNET_CMD="$(command -v dotnet || true)"
if [ -z "$DOTNET_CMD" ]; then
    for candidate in "/opt/homebrew/bin/dotnet" "/usr/local/share/dotnet/dotnet" "/usr/local/bin/dotnet" "$HOME/.dotnet/dotnet"; do
        if [ -x "$candidate" ]; then
            DOTNET_CMD="$candidate"
            break
        fi
    done
fi

REAL_LIB=""
find_real_lib() {
    for candidate in \
        "src/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/publish/Ryujinx.Library.dylib" \
        "src/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native/Ryujinx.Library.dylib" \
        "src/src/Ryujinx.Library/bin/Release/net8.0/ios-arm64/publish/Ryujinx.Library.dylib" \
        "src/src/Ryujinx.Library/bin/Release/net8.0/ios-arm64/native/Ryujinx.Library.dylib"; do
        if [ -f "$candidate" ]; then
            REAL_LIB="$candidate"
            return 0
        fi
    done
    return 1
}

if ! find_real_lib; then
    echo "Compiling C# NativeAOT emulator backend with .NET SDK..."
    if [ -n "$DOTNET_CMD" ]; then
        (cd src && "$DOTNET_CMD" publish -c Release -r ios-arm64 -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true)
    else
        echo "ERROR: .NET SDK (dotnet) not found in PATH or standard directories."
        exit 1
    fi
    find_real_lib || true
fi

if [ -z "$REAL_LIB" ] || [ ! -f "$REAL_LIB" ]; then
    echo "ERROR: Real Ryujinx.Library.dylib was not found and could not be built."
    echo "Please ensure the .NET SDK is installed and run 'cd src && dotnet publish -c Release -r ios-arm64 -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true'."
    exit 1
fi

echo "Using Real Ryujinx Core Library: $REAL_LIB"
LIB_DIR="src/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native"
mkdir -p "$LIB_DIR"
cp "$REAL_LIB" "$LIB_DIR/Ryujinx.Library.dylib"
install_name_tool -id "@rpath/Ryujinx.Library.dylib" "$LIB_DIR/Ryujinx.Library.dylib" 2>/dev/null || true

DO_SIGN=false
CONFIGURATION="Debug"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)
            DO_SIGN=true
            shift
            ;;
        --release)
            CONFIGURATION="Release"
            shift
            ;;
        --debug)
            CONFIGURATION="Debug"
            shift
            ;;
        --configuration|-c)
            CONFIGURATION="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

DEV_TEAM="${DEVELOPMENT_TEAM:-8Y564F7WGM}"

if [ "$DO_SIGN" = true ]; then
    echo "=== Building MeloNX App (Signed, Config: $CONFIGURATION, Development Identity) ==="
    xcodebuild -project src/src/MeloNX/MeloNX.xcodeproj \
               -scheme MeloNX \
               -configuration "$CONFIGURATION" \
               -destination 'generic/platform=iOS' \
               -allowProvisioningUpdates \
               CODE_SIGNING_ALLOWED=YES \
               CODE_SIGN_IDENTITY="Apple Development" \
               DEVELOPMENT_TEAM="$DEV_TEAM"
else
    echo "=== Building MeloNX App (Unsigned, Config: $CONFIGURATION) ==="
    xcodebuild -project src/src/MeloNX/MeloNX.xcodeproj \
               -scheme MeloNX \
               -configuration "$CONFIGURATION" \
               -destination 'generic/platform=iOS' \
               CODE_SIGNING_ALLOWED=NO \
               CODE_SIGN_IDENTITY="" \
               CODE_SIGNING_REQUIRED=NO
fi

DERIVED_DATA_DIR="$(xcodebuild -project src/src/MeloNX/MeloNX.xcodeproj -scheme MeloNX -showBuildSettings | grep -m1 BUILD_DIR | awk '{print $3}' | sed 's|/Build/Products||')"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/${CONFIGURATION}-iphoneos/MeloNX.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH="$(find "$DERIVED_DATA_DIR" -name "MeloNX.app" -type d | head -n 1)"
fi

if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    if [ "$DO_SIGN" = true ]; then
        DEV_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | grep "Apple Development" | head -n 1 | awk '{print $2}')"
        if [ -n "$DEV_IDENTITY" ]; then
            SIGN_ID="$DEV_IDENTITY"
        else
            SIGN_ID="$(codesign -dvv "$APP_PATH" 2>&1 | grep "Authority=" | head -n 1 | sed 's/Authority=//' || true)"
            if [ -z "$SIGN_ID" ]; then
                SIGN_ID="-"
            fi
        fi
    else
        SIGN_ID="-"
    fi

    rm -rf "$BUILD_DIR/MeloNX.app"
    cp -R "$APP_PATH" "$BUILD_DIR/MeloNX.app"
    
    echo "=== Embedding Ryujinx.Library.dylib in App Frameworks ==="
    mkdir -p "$BUILD_DIR/MeloNX.app/Frameworks"
    cp "$LIB_DIR/Ryujinx.Library.dylib" "$BUILD_DIR/MeloNX.app/Frameworks/Ryujinx.Library.dylib"
    install_name_tool -id @rpath/Ryujinx.Library.dylib "$BUILD_DIR/MeloNX.app/Frameworks/Ryujinx.Library.dylib" 2>/dev/null || true

    REAL_DIR="$(dirname "$REAL_LIB")"
    if [ -f "$REAL_DIR/libarmeilleure-jitsupport.dylib" ]; then
        cp "$REAL_DIR/libarmeilleure-jitsupport.dylib" "$BUILD_DIR/MeloNX.app/Frameworks/libarmeilleure-jitsupport.dylib"
        install_name_tool -id @rpath/libarmeilleure-jitsupport.dylib "$BUILD_DIR/MeloNX.app/Frameworks/libarmeilleure-jitsupport.dylib" 2>/dev/null || true
    fi

    install_name_tool -change "src/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native/Ryujinx.Library.dylib" "@rpath/Ryujinx.Library.dylib" "$BUILD_DIR/MeloNX.app/MeloNX" 2>/dev/null || true
    install_name_tool -change "src/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/publish/Ryujinx.Library.dylib" "@rpath/Ryujinx.Library.dylib" "$BUILD_DIR/MeloNX.app/MeloNX" 2>/dev/null || true
    if [ -f "$BUILD_DIR/MeloNX.app/MeloNX.debug.dylib" ]; then
        install_name_tool -change "src/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native/Ryujinx.Library.dylib" "@rpath/Ryujinx.Library.dylib" "$BUILD_DIR/MeloNX.app/MeloNX.debug.dylib" 2>/dev/null || true
        install_name_tool -change "src/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/publish/Ryujinx.Library.dylib" "@rpath/Ryujinx.Library.dylib" "$BUILD_DIR/MeloNX.app/MeloNX.debug.dylib" 2>/dev/null || true
    fi

    echo "=== Signing embedded frameworks with identity: $SIGN_ID ==="
    for item in "$BUILD_DIR/MeloNX.app/Frameworks/"*; do
        if [ -d "$item" ] || [[ "$item" == *.dylib ]]; then
            codesign --force --sign "$SIGN_ID" --timestamp=none "$item" 2>/dev/null || true
        fi
    done
    if [ -f "$BUILD_DIR/MeloNX.app/MeloNX.debug.dylib" ]; then
        codesign --force --sign "$SIGN_ID" --timestamp=none "$BUILD_DIR/MeloNX.app/MeloNX.debug.dylib" 2>/dev/null || true
    fi
    
    XCENT_PATH="$(find "$DERIVED_DATA_DIR/Build/Intermediates.noindex" -name "MeloNX.app.xcent" -type f | head -n 1)"
    if [ "$DO_SIGN" = true ] && [ -n "$XCENT_PATH" ] && [ -f "$XCENT_PATH" ]; then
        codesign --force --sign "$SIGN_ID" --timestamp=none --entitlements "$XCENT_PATH" "$BUILD_DIR/MeloNX.app" 2>/dev/null || true
    else
        codesign --force --sign "$SIGN_ID" --timestamp=none "$BUILD_DIR/MeloNX.app" 2>/dev/null || true
    fi

    echo "=== Build Succeeded! ==="
    echo "App Bundle: $BUILD_DIR/MeloNX.app"
else
    echo "Build completed, but MeloNX.app was not found in DerivedData."
fi

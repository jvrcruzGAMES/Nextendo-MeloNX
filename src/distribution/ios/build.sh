#!/usr/bin/env bash
set +e
[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
set -e

export PATH="/opt/homebrew/bin:/usr/local/share/dotnet:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DOTNET=$(command -v dotnet || true)

if [ -z "$DOTNET" ]; then
  for candidate in \
    "/opt/homebrew/bin/dotnet" \
    "/usr/local/share/dotnet/dotnet" \
    "/usr/local/bin/dotnet" \
    "$HOME/.dotnet/dotnet"
  do
    if [ -x "$candidate" ]; then
      DOTNET="$candidate"
      break
    fi
  done
fi

if [ -n "$DOTNET" ]; then
  "$DOTNET" publish -c Release -r ios-arm64 -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true || true
fi

if [ -f "src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native/Ryujinx.Library.dylib" ] || [ -f "src/Ryujinx.Library/bin/Release/net8.0/ios-arm64/native/Ryujinx.Library.dylib" ]; then
  echo "Ryujinx.Library.dylib present."
  exit 0
fi

echo "Note: If Ryujinx.Library.dylib is missing, run 'cd src && dotnet publish -c Release -r ios-arm64 -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true' in Terminal."
exit 0

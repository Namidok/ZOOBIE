#!/bin/zsh
# Builds build/ZOOBIE.app from the SwiftPM package (no Xcode needed).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to /Applications (keeps a stable path for permissions)
#   scripts/build-app.sh --open     also (re)launch it
# Signs with "Companion Local Signing" when present (create it once with scripts/make-signing-identity.sh)
# so privacy permissions survive rebuilds; CODESIGN_IDENTITY overrides.
set -euo pipefail
cd "${0:A:h}/.."

install=false
launch=false
for arg in "$@"; do
  case $arg in
    --install) install=true ;;
    --open) launch=true ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/Companion"

app=build/ZOOBIE.app
rm -rf "$app" build/Companion.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ZOOBIE"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/kokoro_server.py "$app/Contents/Resources/"
cp -R Resources/avatars "$app/Contents/Resources/"  # the specialists' faces (cropped from img/)
cp -R Resources/fonts "$app/Contents/Resources/"     # Jersey 10 (SIL OFL) for titles
# A stable identity keeps macOS permissions across rebuilds (see scripts/make-signing-identity.sh);
# without one, fall back to ad-hoc signing, which macOS treats as a new app every build.
identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]] && security find-certificate -c "Companion Local Signing" >/dev/null 2>&1; then
  identity="Companion Local Signing"
  echo "Signing with \"$identity\" — if macOS asks for your login password, choose Always Allow."
fi
codesign --force --sign "${identity:--}" --identifier local.companion.agent "$app"
echo "Built $app"

if $install; then
  pkill -x ZOOBIE 2>/dev/null || true
  pkill -x Companion 2>/dev/null || true
  rm -rf /Applications/Companion.app /Applications/ZOOBIE.app  # the app was called Companion before
  cp -R "$app" /Applications/
  app=/Applications/ZOOBIE.app
  echo "Installed $app"
fi

if $launch; then
  pkill -x ZOOBIE 2>/dev/null || true
  sleep 0.3
  open "$app"
fi

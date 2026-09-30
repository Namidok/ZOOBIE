#!/bin/zsh
# Runs the unit tests. With only the Command Line Tools (no Xcode), SwiftPM can't find Swift Testing,
# so pass its framework and runtime paths explicitly. Extra args go to `swift test` (e.g. --filter AgentTests).
set -euo pipefail
cd "${0:A:h}/.."

DEV=/Library/Developer/CommandLineTools/Library/Developer
if [[ -d "$DEV/Frameworks/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
    -Xlinker -F -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
    "$@"
fi
exec swift test "$@"

#!/bin/zsh
# Builds Mini Flow with the plain Swift compiler (no package manager needed).
set -e
cd "$(dirname "$0")"
OUT=.build; mkdir -p $OUT
FLAGS=(-O -swift-version 5 -target arm64-apple-macosx26.0)
echo "• core engine";  swiftc $FLAGS -parse-as-library -emit-library -static -module-name FlowCore \
    -emit-module -emit-module-path $OUT/FlowCore.swiftmodule -o $OUT/libFlowCore.a Sources/FlowCore/*.swift
for tool in flowtest flowcli; do
  echo "• $tool"; swiftc $FLAGS -I $OUT -L $OUT -lFlowCore Sources/$tool/main.swift -o $OUT/$tool
done
if [[ -f Sources/MiniFlow/main.swift && "$1" != "--no-app" ]]; then
  echo "• MiniFlow.app"
  swiftc $FLAGS -I $OUT -L $OUT -lFlowCore Sources/MiniFlow/*.swift -o $OUT/MiniFlow
  APP="Mini Flow.app"; rm -rf "$APP" MiniFlow.app; 
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"; cp $OUT/MiniFlow "$APP/Contents/MacOS/MiniFlow"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  # Sign with the local "Mini Flow Local Signing" certificate if present, so macOS keeps Mini Flow's permissions
  # (Microphone, Accessibility, Input Monitoring) across rebuilds. Falls back to ad-hoc signing.
  IDENTITY=$(security find-certificate -c "Mini Flow Local Signing" -Z 2>/dev/null | awk '/SHA-1/{print $3; exit}')
  codesign --force --sign "${IDENTITY:--}" --entitlements Resources/MiniFlow.entitlements "$APP" >/dev/null 2>&1
  codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf' && echo "  signed with Mini Flow Local Signing (permissions persist)" || echo "  ad-hoc signed — permissions reset on each rebuild (optional fix: scripts/create-signing-cert.sh)"
fi
echo "done"

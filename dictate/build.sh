#!/bin/zsh
# Builds Mini Dictate with the plain Swift compiler (no package manager needed).
set -e
cd "$(dirname "$0")"
OUT=.build; mkdir -p $OUT
FLAGS=(-O -swift-version 5 -target arm64-apple-macosx26.0)
echo "• core engine";  swiftc $FLAGS -parse-as-library -emit-library -static -module-name DictateCore \
    -emit-module -emit-module-path $OUT/DictateCore.swiftmodule -o $OUT/libDictateCore.a Sources/DictateCore/*.swift
for tool in dictatetest dictatecli; do
  echo "• $tool"; swiftc $FLAGS -I $OUT -L $OUT -lDictateCore Sources/$tool/main.swift -o $OUT/$tool
done
if [[ -f Sources/MiniDictate/main.swift && "$1" != "--no-app" ]]; then
  echo "• MiniDictate.app"
  swiftc $FLAGS -I $OUT -L $OUT -lDictateCore Sources/MiniDictate/*.swift -o $OUT/MiniDictate
  APP="Mini Dictate.app"; rm -rf "$APP" "Mini Flow.app"   # also remove the app under its old name
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"; cp $OUT/MiniDictate "$APP/Contents/MacOS/MiniDictate"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  # Sign with the local "Mini Dictate Local Signing" certificate if present, so macOS keeps Mini Dictate's permissions
  # (Microphone, Accessibility, Input Monitoring) across rebuilds. Falls back to ad-hoc signing.
  for cert in "Mini Dictate Local Signing" "Mini Flow Local Signing"; do   # second = old name, still accepted
    IDENTITY=$(security find-certificate -c "$cert" -Z 2>/dev/null | awk '/SHA-1/{print $3; exit}'); [[ -n $IDENTITY ]] && break
  done
  codesign --force --sign "${IDENTITY:--}" --entitlements Resources/MiniDictate.entitlements "$APP" >/dev/null 2>&1
  codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf' && echo "  signed with $cert (permissions persist)" || echo "  ad-hoc signed — permissions reset on each rebuild (optional fix: scripts/create-signing-cert.sh)"
fi
echo "done"

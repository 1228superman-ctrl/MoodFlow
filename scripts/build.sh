#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flavor="${1:?Use health or sim}"
case "$flavor" in
  health) conditions="" ;;
  sim) conditions="MOODFLOW_SIM" ;;
  *) exit 2 ;;
esac
root="$PWD/build/$flavor"
mkdir -p "$root"
swiftc Native/Journal.swift Native/MoodEstimate.swift Native/PhoneVariationNotice.swift Shared/MoodFaceSnapshot.swift \
  scripts/check_mood_estimate.swift -o "$root/check-mood-estimate"
"$root/check-mood-estimate" | tee "$root/mood-estimate.log"
xcodegen generate
for target in MoodFlow MoodFlowWatch; do
  if [[ "$target" == MoodFlow ]]; then
    sdk=iphoneos
    platform=iOS
  else
    sdk=watchos
    platform=watchOS
  fi
  xcodebuild -project MoodFlow.xcodeproj -scheme "$target" -configuration Release \
    -sdk "$sdk" -destination "generic/platform=$platform" \
    -derivedDataPath "$root/$target" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions" build | tee "$root/$target.log"
done

# Build both bundles with their native SDK, then assemble WatchBridge's expected IPA layout.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/Payload"
app="$staging/Payload/MoodFlow.app"
watch="$app/Watch/MoodFlowWatch.app"
ditto "$root/MoodFlow/Build/Products/Release-iphoneos/MoodFlow.app" "$app"
ditto "$root/MoodFlowWatch/Build/Products/Release-watchos/MoodFlowWatch.app" "$watch"
# Record requested capabilities before signing the enclosing app.
widget="$watch/PlugIns/MoodFlowWatchFace.appex"
test -d "$widget"
codesign --force --sign - --entitlements Config/MoodFace.entitlements "$widget"
watch_entitlements=Config/MoodFace.entitlements
if [[ "$flavor" == health ]]; then
  # Ad hoc signature records the requested capabilities. WatchBridge must re-sign
  # with Apple-issued profiles. This signature gives the app no device privileges.
  watch_entitlements=Config/WatchHealth.entitlements
fi
codesign --force --sign - --entitlements "$watch_entitlements" "$watch"
if [[ "$flavor" == health ]]; then
  codesign --force --sign - --entitlements Config/Health.entitlements "$app"
fi
ipa="$root/MoodFlow-$flavor.ipa"
ditto -c -k "$staging/Payload" "$ipa.tmp" --keepParent
mv "$ipa.tmp" "$ipa"
python3 scripts/check_ipa.py "$ipa" --require-complication | tee "$root/package.log"
(cd "$root" && shasum -a 256 "MoodFlow-$flavor.ipa" > SHA256SUMS.txt)

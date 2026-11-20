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
if [[ "$flavor" == health ]]; then
  # Ad hoc signature records the requested capabilities. WatchBridge must re-sign
  # with Apple-issued profiles. This signature gives the app no device privileges.
  codesign --force --sign - --entitlements Config/Health.entitlements "$watch"
  codesign --force --sign - --entitlements Config/Health.entitlements "$app"
fi
ipa="$root/MoodFlow-$flavor.ipa"
ditto -c -k "$staging/Payload" "$ipa.tmp" --keepParent
mv "$ipa.tmp" "$ipa"
python3 scripts/check_ipa.py "$ipa" | tee "$root/package.log"
(cd "$root" && shasum -a 256 "MoodFlow-$flavor.ipa" > SHA256SUMS.txt)

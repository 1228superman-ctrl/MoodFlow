#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:?Use ios or watchos}" in
  ios)
    platform=iOS
    sdk=iphonesimulator
    scheme=MoodFlow
    bundle=org.moodflow.validation
    ;;
  watchos)
    platform=watchOS
    sdk=watchsimulator
    scheme=MoodFlowWatch
    bundle=org.moodflow.validation.watchkitapp
    ;;
  *) exit 2 ;;
esac

root="$PWD/build/simulator-$1"
mkdir -p "$root"
exec > >(tee "$root/test.log") 2>&1
xcodebuild -version
xcrun simctl list -j > "$root/simulators.json"
device_info() {
  python3 - "$root/simulators.json" "$platform" <<'PY'
import json
import sys

with open(sys.argv[1]) as file:
    listing = json.load(file)
platform = sys.argv[2]
runtimes = sorted(
    (runtime for runtime in listing["runtimes"]
     if runtime["name"].startswith(platform + " ") and runtime["isAvailable"]
     and int(runtime["version"].split(".")[0]) >= 26),
    key=lambda runtime: tuple(map(int, runtime["version"].split("."))),
    reverse=True,
)
for runtime in runtimes:
    devices = listing["devices"].get(runtime["identifier"], [])
    options = [device for device in devices if device["isAvailable"]
               and device["name"].startswith("iPhone" if platform == "iOS" else "Apple Watch")]
    if options:
        chosen = options[0]
        print(chosen["udid"], runtime["name"], chosen["name"], sep="|")
        break
else:
    sys.exit("No eligible " + platform + " simulator with a configured device")
PY
}
if ! selection=$(device_info); then
  xcodebuild -downloadPlatform "$platform" -architectureVariant arm64
  xcrun simctl list -j > "$root/simulators.json"
  selection=$(device_info)
fi
IFS='|' read -r udid runtime model <<< "$selection"
printf 'Simulator: %s · %s\n' "$runtime" "$model"

xcodegen generate
xcodebuild -project MoodFlow.xcodeproj -scheme "$scheme" -configuration Release \
  -sdk "$sdk" -destination "generic/platform=$platform Simulator" \
  -derivedDataPath "$root/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=MOODFLOW_SIM build | tee "$root/build.log"

app="$root/DerivedData/Build/Products/Release-$sdk/$scheme.app"
if [[ "$platform" == "watchOS" ]]; then
  # Give the simulator its own standalone bundle. The built device IPA keeps
  # the companion declaration and remains the artifact for WatchBridge testing.
  /usr/libexec/PlistBuddy -c 'Delete :WKCompanionAppBundleIdentifier' "$app/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :WKWatchOnly bool true' "$app/Info.plist"
fi
codesign --force --sign - "$app"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
container=$(xcrun simctl get_app_container "$udid" "$bundle" data)
journal="$container/Library/Application Support/MoodFlowValidation"

xcrun simctl launch "$udid" "$bundle"
sleep 3
xcrun simctl io "$udid" screenshot "$root/01-launch.png"
xcrun simctl terminate "$udid" "$bundle"
xcrun simctl launch "$udid" "$bundle" --moodflow-ci-confirm

wait_for_entries() {
  local minimum="$1"
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if [[ -d "$journal" ]] && [[ $(find "$journal" -name '*.json' -type f | wc -l) -ge "$minimum" ]]; then
      return
    fi
    sleep 1
  done
  printf 'Expected %s journal entries within 30 seconds\n' "$minimum" >&2
  return 1
}

wait_for_entries 2
xcrun simctl terminate "$udid" "$bundle"
xcrun simctl launch "$udid" "$bundle" --moodflow-ci-correct
wait_for_entries 4
xcrun simctl terminate "$udid" "$bundle"
xcrun simctl launch "$udid" "$bundle"
sleep 2
xcrun simctl io "$udid" screenshot "$root/02-after-relaunch.png"

python3 - "$journal" "$root" <<'PY'
import json
import sys
from pathlib import Path

journal, destination = map(Path, sys.argv[1:])
entries = [json.loads(path.read_bytes()) for path in journal.glob("*.json")]
events = {entry["id"]: entry for entry in entries if entry["kind"] == "波动事件"}
feedback = [entry for entry in entries if entry["kind"] == "情绪反馈"]
assert len(entries) == 4 and len(events) == 2 and len(feedback) == 2, entries
assert {entry["detail"] for entry in feedback} == {"愉快", "紧张"}, feedback
assert {entry["eventID"] for entry in feedback} == set(events), feedback
assert all(entry["detail"] == "模拟 · 68 → 95 bpm" for entry in events.values()), events
(destination / "synthetic-journal.json").write_text(
    json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
)
print("PASS: both synthetic variations and their confirm/correct feedback persisted across relaunch")
print("SCOPE: simulator only; launch arguments invoked handlers, and haptics were not measured")
PY

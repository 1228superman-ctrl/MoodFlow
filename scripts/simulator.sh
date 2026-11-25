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

with_timeout() {
  python3 -c '
import subprocess, sys
try:
    result = subprocess.run(sys.argv[2:], timeout=int(sys.argv[1]))
except subprocess.TimeoutExpired:
    print("Timed out: " + " ".join(sys.argv[2:]), file=sys.stderr)
    sys.exit(124)
sys.exit(result.returncode)
' "$@"
}

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
        preferred = {"iPhone 16e", "iPhone 17e"}
        chosen = next((device for device in options if device["name"] in preferred), options[0])
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
  codesign --force --sign - --entitlements Config/MoodFace.entitlements "$app/PlugIns/MoodFlowWatchFace.appex"
fi
codesign --force --sign - "$app"
echo "Booting simulator"
with_timeout 170 xcrun simctl bootstatus "$udid" -b
echo "Installing simulator build"
with_timeout 120 xcrun simctl install "$udid" "$app"

take_screenshot() {
  if ! with_timeout 25 xcrun simctl io "$udid" screenshot "$root/$1"; then
    echo "Screenshot unavailable: $1"
  fi
}

echo "Launching the app"
with_timeout 45 xcrun simctl launch "$udid" "$bundle"
if ! container=$(with_timeout 15 xcrun simctl get_app_container "$udid" "$bundle" data); then
  # CoreSimulator can time out on a data lookup after a successful installation.
  container=$(python3 - "$udid" "$bundle" <<'PY'
import plistlib
import sys
from pathlib import Path

device, bundle = sys.argv[1:]
root = Path.home() / "Library/Developer/CoreSimulator/Devices" / device / "data/Containers/Data/Application"
matches = []
for metadata in root.glob("*/.com.apple.mobile_container_manager.metadata.plist"):
    try:
        with metadata.open("rb") as stream:
            if plistlib.load(stream).get("MCMMetadataIdentifier") == bundle:
                matches.append(metadata.parent)
    except (OSError, plistlib.InvalidFileException):
        continue
if len(matches) != 1:
    sys.exit("Could not identify a unique simulator app data container")
print(matches[0])
PY
  )
fi
journal="$container/Library/Application Support/MoodFlowValidation"
sleep 3
take_screenshot 01-launch.png
with_timeout 30 xcrun simctl terminate "$udid" "$bundle"
with_timeout 45 xcrun simctl launch "$udid" "$bundle" --moodflow-ci-confirm

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
with_timeout 30 xcrun simctl terminate "$udid" "$bundle"
with_timeout 45 xcrun simctl launch "$udid" "$bundle" --moodflow-ci-correct
wait_for_entries 4
with_timeout 30 xcrun simctl terminate "$udid" "$bundle"
with_timeout 45 xcrun simctl launch "$udid" "$bundle"
sleep 2
take_screenshot 02-after-relaunch.png

python3 - "$journal" "$root" "$platform" <<'PY'
import json
import sys
from pathlib import Path

journal, destination = map(Path, sys.argv[1:3])
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
if sys.argv[3] == "iOS":
    jobs = [json.loads(path.read_bytes()) for path in (journal / "Summaries").glob("*.json")]
    assert len(jobs) == 2 and len({job["input"]["id"] for job in jobs}) == 2, jobs
    assert {job["input"]["eventCount"] for job in jobs} == {1, 2}, jobs
    assert all(not job.get("result") and "averageBpm" not in job["input"] for job in jobs), jobs
    print("PASS: catch-up and regeneration created separate pending jobs, without simulated physiology or summaries")
print("SCOPE: simulator only; launch arguments invoked handlers, and haptics were not measured")
PY
if [[ "$platform" == "watchOS" ]]; then
  for pass in 1 2; do
    with_timeout 30 xcrun simctl terminate "$udid" "$bundle"
    with_timeout 45 xcrun simctl launch "$udid" "$bundle" --moodflow-ci-analyze
    wait_for_entries 5
    sleep 2
  done
  python3 - "$journal" <<'PY'
import json, sys
from pathlib import Path
rows = [json.loads(f.read_bytes()) for f in Path(sys.argv[1]).glob("*.json")]
autos = [row for row in rows if row.get("analysis")]
assert len(autos) == 1 and autos[0]["analysis"]["label"] == "可能紧张"
assert autos[0]["evaluatedAt"] - autos[0]["time"] >= 3500
assert not any(row["kind"] == "主动提醒" for row in rows)
print("PASS: delayed synthetic analysis persisted once across watch app relaunch")
PY
fi

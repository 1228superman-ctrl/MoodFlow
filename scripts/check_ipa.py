"""Inspect an IPA without unpacking it or trusting paths in the archive."""
import plistlib
import sys
from pathlib import PurePosixPath
from zipfile import ZipFile


def inspect(path):
    with ZipFile(path) as archive:
        names = set(archive.namelist())
        phone_paths = [name for name in names if PurePosixPath(name).match("Payload/*.app/Info.plist")]
        if len(phone_paths) != 1:
            raise ValueError("Expected exactly one iPhone application")
        phone_path = PurePosixPath(phone_paths[0]).parent
        watch_paths = [name for name in names if name.startswith(f"{phone_path}/Watch/")
                       and PurePosixPath(name).match("Watch/*.app/Info.plist")]
        if len(watch_paths) != 1:
            raise ValueError("Expected exactly one companion at Watch/*.app")
        phone, watch = [plistlib.loads(archive.read(name)) for name in (phone_paths[0], watch_paths[0])]
        phone_id = phone["CFBundleIdentifier"]
        if watch["WKCompanionAppBundleIdentifier"] != phone_id:
            raise ValueError("Companion refers to a different iPhone application")
        if not watch["CFBundleIdentifier"].startswith(phone_id + "."):
            raise ValueError("Watch bundle ID must extend the host bundle ID")
        for name, info, platform in [(phone_paths[0], phone, "iPhoneOS"), (watch_paths[0], watch, "WatchOS")]:
            executable = PurePosixPath(name).parent / info["CFBundleExecutable"]
            if platform not in info["CFBundleSupportedPlatforms"]:
                raise ValueError(f"Expected a physical {platform} build")
            with archive.open(str(executable)) as binary:
                if binary.read(4) not in [b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"]:
                    raise ValueError(f"Invalid executable header in {executable}")
            print(f"{platform}: {info['CFBundleIdentifier']} · minimum {info['MinimumOSVersion']}")
    print("PASS: companion layout, plist linkage and device executable headers")


if __name__ == "__main__":
    inspect(sys.argv[1])

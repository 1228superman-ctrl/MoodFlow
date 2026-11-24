"""Inspect an IPA without unpacking it or trusting paths in the archive."""
import plistlib
import sys
from pathlib import PurePosixPath
from zipfile import ZipFile


def inspect(path, require_complication=False):
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
        bundles = [(phone_paths[0], phone, "iPhoneOS"), (watch_paths[0], watch, "WatchOS")]
        watch_path = PurePosixPath(watch_paths[0]).parent
        widgets = [name for name in names if name.startswith(f"{watch_path}/PlugIns/")
                   and PurePosixPath(name).match("PlugIns/*.appex/Info.plist")]
        if require_complication or widgets:
            if len(widgets) != 1:
                raise ValueError("Expected exactly one embedded WidgetKit complication")
            widget = plistlib.loads(archive.read(widgets[0]))
            if not widget["CFBundleIdentifier"].startswith(watch["CFBundleIdentifier"] + "."):
                raise ValueError("Complication bundle ID must extend the Watch bundle ID")
            if widget["NSExtension"]["NSExtensionPointIdentifier"] != "com.apple.widgetkit-extension":
                raise ValueError("Watch extension isn't a WidgetKit complication")
            bundles.append((widgets[0], widget, "WatchOS"))
        for name, info, platform in bundles:
            executable = PurePosixPath(name).parent / info["CFBundleExecutable"]
            if platform not in info["CFBundleSupportedPlatforms"]:
                raise ValueError(f"Expected a physical {platform} build")
            with archive.open(str(executable)) as binary:
                if binary.read(4) not in [b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"]:
                    raise ValueError(f"Invalid executable header in {executable}")
            print(f"{platform}: {info['CFBundleIdentifier']} · minimum {info['MinimumOSVersion']}")
    print("PASS: companion layout, plist linkage and device executable headers")


if __name__ == "__main__":
    inspect(sys.argv[1], require_complication="--require-complication" in sys.argv[2:])

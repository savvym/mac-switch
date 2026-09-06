#!/usr/bin/env python3
"""Build and verify a universal drag-to-Applications DMG without automating Finder."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

import dmgbuild
from ds_store import DSStore

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "MAC Switch.app"
ICON_LOCATIONS = {APP_NAME: (170, 200), "Applications": (470, 200)}


def read_version(info_path=ROOT / "Info.plist", tag=None):
    with info_path.open("rb") as handle:
        version = plistlib.load(handle)["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("CFBundleShortVersionString must use MAJOR.MINOR.PATCH")
    if tag and tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} does not match Info.plist version v{version}")
    return version


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def verify_app(app, version):
    if read_version(app / "Contents/Info.plist") != version:
        raise ValueError("Packaged application version does not match the release")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    for binary in ("MacOS/MACSwitch", "Helpers/MACSwitchHelper"):
        run("/usr/bin/lipo", app / "Contents" / binary, "-verify_arch", "arm64", "x86_64")


def verify_dmg(path, version):
    run("/usr/bin/hdiutil", "verify", path)
    attached = run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-plist", path, capture_output=True)
    entities = plistlib.loads(attached.stdout)["system-entities"]
    mounted = [entry for entry in entities if "mount-point" in entry]
    devices = [entry["dev-entry"] for entry in entities if "dev-entry" in entry]
    if not mounted:
        if devices:
            run("/usr/bin/hdiutil", "detach", devices[0])
        raise RuntimeError("DMG did not mount a filesystem")
    mount = Path(mounted[0]["mount-point"])
    try:
        verify_app(mount / APP_NAME, version)
        shortcut = mount / "Applications"
        if not shortcut.is_symlink() or os.readlink(shortcut) != "/Applications":
            raise ValueError("DMG is missing the /Applications installation shortcut")
        if not (mount / ".background.tiff").is_file():
            raise ValueError("DMG is missing its installer background")
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            for name, position in ICON_LOCATIONS.items():
                if tuple(store[name]["Iloc"]) != position:
                    raise ValueError(f"Incorrect installer icon position: {name}")
            if store["."]["icvp"]["backgroundType"] != 2:
                raise ValueError("Finder background has not been configured")
            if store["."]["bwsp"]["ShowToolbar"]:
                raise ValueError("Installer toolbar must be hidden")
    finally:
        run("/usr/bin/hdiutil", "detach", mount)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--tag", default="", help="Optional release tag, e.g. v1.2.0")
    parser.add_argument("--skip-build", action="store_true", help="Repackage an existing universal build")
    args = parser.parse_args()
    version = read_version(tag=args.tag)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = output / APP_NAME
    if not args.skip_build:
        env = dict(os.environ, ARCHS="arm64 x86_64", APP_OUTPUT=str(app))
        run("/bin/bash", ROOT / "build.sh", env=env, cwd=ROOT)
    verify_app(app, version)
    destination = output / f"MAC-Switch-{version}-universal.dmg"
    with tempfile.TemporaryDirectory(prefix="mac-switch-dmg-") as temporary:
        temp = Path(temporary)
        background = temp / "background.png"
        run("/usr/bin/xcrun", "swift", ROOT / "scripts/DMGBackground.swift", background)
        image = temp / destination.name
        dmgbuild.build_dmg(str(image), "MAC Switch", settings={
            "files": [str(app)],
            "symlinks": {"Applications": "/Applications"},
            "icon": str(ROOT / "AppIcon.icns"),
            "background": str(background),
            "format": "UDZO",
            "filesystem": "HFS+",
            "window_rect": ((120, 120), (640, 400)),
            "icon_locations": ICON_LOCATIONS,
            "icon_size": 96,
            "text_size": 14,
            "default_view": "icon-view",
            "show_toolbar": False,
            "show_status_bar": False,
            "show_sidebar": False,
            "show_tab_view": False,
            "show_pathbar": False,
        }, lookForHiDPI=True)
        verify_dmg(image, version)
        # Publish local outputs only after the mounted image has passed validation.
        with image.open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        shutil.copyfile(image, destination)
        destination.with_suffix(".dmg.sha256").write_text(f"{digest}  {destination.name}\n", encoding="utf-8")
    print(f"Verified DMG: {destination}", flush=True)


if __name__ == "__main__":
    main()

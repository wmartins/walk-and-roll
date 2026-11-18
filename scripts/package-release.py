#!/usr/bin/env python3
"""Build and verify a universal, unnotarized DMG for a GitHub release."""

import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
APP_NAME = "Walk & Roll.app"
INSTALLATION = """Requires macOS 15 or later. Supports Apple silicon and Intel Macs.

Open the DMG, drag Walk & Roll to Applications, then open it from Applications.

This release is ad-hoc signed, has no verified Developer ID, and is not notarized
by Apple. macOS will normally block the first launch. If you trust this download,
try opening the app, then go to System Settings > Privacy & Security > Open Anyway
and confirm. See Apple's instructions:
https://support.apple.com/en-us/102445

Optional features request Microphone, Camera, and Input Monitoring permissions.
Updates may require granting permissions again because these releases do not
have a persistent Developer ID signing identity.
"""


def run(arguments):
    subprocess.run([str(argument) for argument in arguments], check=True)


def validate_app(app, version):
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info["CFBundleIdentifier"] != "com.wmartins.walkandroll"
            or info["CFBundleShortVersionString"] != version):
        raise RuntimeError("The packaged app has an unexpected identifier or version.")
    for architecture in ["arm64", "x86_64"]:
        run(["/usr/bin/lipo", app / "Contents" / "MacOS" / "WalkAndRoll",
             "-verify_arch", architecture])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    if not (app / "Contents" / "Resources" / "LICENSE").is_file():
        raise RuntimeError("The packaged app is missing its license.")


def package(version, build_number, sdk):
    command = [sys.executable, ROOT / "scripts" / "build-local.py", "--release", "--universal"]
    if sdk:
        command.extend(["--sdk", sdk])
    # Local builds always keep their persistent certificate-bound identity.
    run(command)
    output = BUILD / "release"
    output.mkdir(exist_ok=True)
    basename = f"Walk-and-Roll-{version}-universal-unnotarized"
    with tempfile.TemporaryDirectory(prefix=".release-", dir=BUILD) as temporary:
        temporary = Path(temporary)
        staging = temporary / "staging"
        staging.mkdir()
        app = staging / APP_NAME
        shutil.copytree(BUILD / APP_NAME, app, symlinks=True)
        # Modify only the release copy; never replace the local signing identity.
        run(["/usr/bin/codesign", "--remove-signature", app])
        info_path = app / "Contents" / "Info.plist"
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        info["CFBundleVersion"] = build_number
        with info_path.open("wb") as stream:
            plistlib.dump(info, stream)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app])
        validate_app(app, version)
        (staging / "Applications").symlink_to("/Applications", target_is_directory=True)
        (staging / "Read Me.txt").write_text(INSTALLATION, encoding="utf-8")
        shutil.copy2(ROOT / "LICENSE", staging / "LICENSE")

        dmg = temporary / f"{basename}.dmg"
        run(["/usr/bin/hdiutil", "create", "-volname", f"Walk & Roll {version}",
             "-srcfolder", staging, "-format", "UDZO", "-fs", "HFS+", dmg])
        run(["/usr/bin/hdiutil", "verify", dmg])
        mount = temporary / "mounted"
        mount.mkdir()
        run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg])
        try:
            validate_app(mount / APP_NAME, version)
            if (mount / "Applications").readlink() != Path("/Applications"):
                raise RuntimeError("The DMG is missing its Applications shortcut.")
        finally:
            run(["/usr/bin/hdiutil", "detach", mount])

        # Publish only after validating the app inside the finished disk image.
        destination = output / dmg.name
        shutil.copy2(dmg, destination)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        (output / "SHA256SUMS").write_text(f"{digest}  {dmg.name}\n", encoding="utf-8")
        (output / "release-notes.md").write_text(
            f"## Installation\n\n{INSTALLATION}\n"
            "Download the `.dmg` asset below. `SHA256SUMS` contains its SHA-256 checksum.\n",
            encoding="utf-8",
        )
    print(f"Ready: {destination}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Require this version to match Info.plist (for example 0.1.0)")
    parser.add_argument("--build-number", default="1", help="Positive integer bundle build number")
    parser.add_argument("--sdk", help="Override the SDK used by build-local.py")
    options = parser.parse_args()
    with (ROOT / "WalkAndRoll" / "Info.plist").open("rb") as stream:
        version = plistlib.load(stream).get("CFBundleShortVersionString")
    if not isinstance(version, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        parser.error("Info.plist CFBundleShortVersionString must have the form MAJOR.MINOR.PATCH")
    if options.version is not None and options.version != version:
        parser.error(f"--version {options.version!r} does not match Info.plist version {version!r}")
    if not re.fullmatch(r"[1-9][0-9]*", options.build_number):
        parser.error("--build-number must be a positive integer")
    package(version, options.build_number, options.sdk)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Packaging failed: {error}", file=sys.stderr)
        sys.exit(1)

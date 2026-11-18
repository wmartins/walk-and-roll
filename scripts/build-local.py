#!/usr/bin/env python3
"""Build Walk & Roll with a persistent, certificate-bound local signing identity."""

import argparse
import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SIGNING = ROOT / ".local-signing"
BUILD = ROOT / "build"
IDENTIFIER = "com.wmartins.walkandroll"


def run(arguments):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True)
    if result.returncode:
        # Do not include command arguments, which can contain the local keychain password.
        raise RuntimeError(f"{Path(arguments[0]).name} failed. {result.stderr.strip()}")
    return result.stdout.strip()


def signing_identity():
    certificate = SIGNING / "certificate.pem"
    private_key = SIGNING / "private-key.pem"
    password_file = SIGNING / "keychain-password"
    keychain = SIGNING / "identity.keychain-db"

    if certificate.exists() != private_key.exists():
        raise RuntimeError("Local signing identity is incomplete. Restore its original certificate and key in .local-signing.")
    if not certificate.exists():
        configuration = SIGNING / "certificate.cnf"
        configuration.write_text(
            "[req]\nprompt = no\ndistinguished_name = subject\nx509_extensions = signing\n"
            "[subject]\nCN = Walk & Roll Local Development\n"
            "[signing]\nbasicConstraints = critical,CA:FALSE\n"
            "keyUsage = critical,digitalSignature\nextendedKeyUsage = codeSigning\n"
            "subjectKeyIdentifier = hash\n"
        )
        run([
            "/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "3650", "-config", configuration, "-keyout", private_key, "-out", certificate,
        ])

    if not password_file.exists():
        if keychain.exists():
            raise RuntimeError("Restore .local-signing/keychain-password to unlock the existing signing keychain.")
        password_file.write_text(secrets.token_urlsafe(32))
    password = password_file.read_text()

    original_search_list = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
    try:
        if not keychain.exists():
            run(["/usr/bin/security", "create-keychain", "-p", password, keychain])
            run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", keychain])
        run(["/usr/bin/security", "unlock-keychain", "-p", password, keychain])

        certificate_der = subprocess.run(
            ["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
        fingerprint = hashlib.sha1(certificate_der).hexdigest().upper()
        identities = run(["/usr/bin/security", "find-identity", "-p", "codesigning", keychain])
        if fingerprint not in identities:
            with tempfile.TemporaryDirectory(dir=SIGNING) as temporary:
                archive = Path(temporary) / "identity.p12"
                run([
                    "/usr/bin/openssl", "pkcs12", "-export", "-inkey", private_key,
                    "-in", certificate, "-out", archive, "-passout", f"file:{password_file}",
                ])
                run([
                    "/usr/bin/security", "import", archive, "-k", keychain, "-P", password,
                    "-x", "-T", "/usr/bin/codesign",
                ])
        run([
            "/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:",
            "-s", "-k", password, keychain,
        ])
    finally:
        current = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
        if current != original_search_list:
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_search_list])

    requirement = f'designated => identifier "{IDENTIFIER}" and certificate leaf = H"{fingerprint}"'
    return keychain, fingerprint, requirement


def build_app(app, temporary, release, sdk_name):
    executable = app / "Contents" / "MacOS"
    resources = app / "Contents" / "Resources"
    for directory in [app, app / "Contents", executable, resources]:
        directory.mkdir(exist_ok=True)
        directory.chmod(0o755)
    shutil.copy2(ROOT / "WalkAndRoll" / "Info.plist", app / "Contents" / "Info.plist")
    iconset = temporary / "AppIcon.iconset"
    iconset.mkdir()
    for artwork in (ROOT / "WalkAndRoll" / "Assets.xcassets" / "AppIcon.appiconset").glob("icon_*.png"):
        shutil.copy2(artwork, iconset / artwork.name)
    run(["/usr/bin/iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns"])
    sdk = run(["/usr/bin/xcrun", "--sdk", sdk_name, "--show-sdk-path"])
    print("Compiling Walk & Roll...", flush=True)
    run([
        "/usr/bin/xcrun", "--sdk", sdk_name, "swiftc", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macosx15.0", "-sdk", sdk,
        "-module-cache-path", BUILD / "ModuleCache", "-module-name", "WalkAndRoll",
        "-O" if release else "-Onone", *sorted((ROOT / "WalkAndRoll").glob("*.swift")),
        "-o", executable / "WalkAndRoll",
    ])
    (executable / "WalkAndRoll").chmod(0o755)


def publish(app, destination):
    if destination.exists():
        # Swap complete bundles on the same volume so a failed build leaves the installed app intact.
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        swap = library.renamex_np
        swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        swap.restype = ctypes.c_int
        if swap(os.fsencode(app), os.fsencode(destination), 2):  # RENAME_SWAP
            raise OSError(ctypes.get_errno(), "Could not publish the signed app")
    else:
        os.replace(app, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true", help="Compile with optimization")
    parser.add_argument("--sdk", help="Override the macOS SDK selected for compilation")
    parser.add_argument("--sign-existing", type=Path, metavar="APP", help="Sign an existing Xcode build")
    options = parser.parse_args()
    sdk_name = options.sdk
    if sdk_name is None:
        # Prefer the compatible 26.5 SDK when installed; newer SDKs can require additional SwiftUI compiler plugins.
        compatible = subprocess.run(
            ["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], capture_output=True,
        )
        sdk_name = "macosx26.5" if compatible.returncode == 0 else "macosx"
    os.umask(0o077)
    SIGNING.mkdir(exist_ok=True, mode=0o700)
    SIGNING.chmod(0o700)
    BUILD.mkdir(exist_ok=True)
    destination = options.sign_existing.resolve() if options.sign_existing else BUILD / "Walk & Roll.app"
    with (SIGNING / "build.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        keychain, fingerprint, requirement = signing_identity()
        with tempfile.TemporaryDirectory(prefix=".walk-and-roll-", dir=destination.parent) as temporary:
            app = Path(temporary) / destination.name
            if options.sign_existing:
                shutil.copytree(destination, app, symlinks=True)
            else:
                build_app(app, Path(temporary), options.release, sdk_name)
            with (app / "Contents" / "Info.plist").open("rb") as info:
                if plistlib.load(info).get("CFBundleIdentifier") != IDENTIFIER:
                    raise RuntimeError("The selected app is not the Walk & Roll main target.")
            resources = app / "Contents" / "Resources"
            resources.mkdir(exist_ok=True)
            shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
            run([
                "/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", keychain,
                "--timestamp=none", "--requirements", "=" + requirement, app,
            ])
            run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement.removeprefix("designated => "), app])
            publish(app, destination)
        print(f"Ready: {destination}")
        print(f"Local certificate: {fingerprint}")
        print("This signing identity is reused on subsequent builds.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        sys.exit(1)

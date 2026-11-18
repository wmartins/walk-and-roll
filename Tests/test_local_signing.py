"""Exercise local signing with an isolated identity, without using .local-signing/."""

from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import platform
import shlex
import shutil
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(platform.system() == "Darwin", "Requires the macOS signing tools")
class LocalSigningTests(unittest.TestCase):
    def test_fresh_identity_reuse_and_failure_cleanup(self):
        spec = importlib.util.spec_from_file_location("build_local", ROOT / "scripts/build-local.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        run = builder.run
        original_search_list = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
        original_umask = os.umask(0o077)
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        try:
            with tempfile.TemporaryDirectory(prefix="signing-test-", dir=build) as temporary:
                builder.SIGNING = Path(temporary) / "signing"
                keychain = builder.SIGNING / "identity.keychain-db"
                app = Path(temporary) / "Fixture.app"
                executable = app / "Contents/MacOS"
                executable.mkdir(parents=True)
                shutil.copy2(ROOT / "WalkAndRoll/Info.plist", app / "Contents/Info.plist")
                # Do not copy SIP-protected system file flags into the fixture.
                shutil.copyfile("/usr/bin/true", executable / "WalkAndRoll")
                (executable / "WalkAndRoll").chmod(0o755)

                def checked_run(arguments, fail_signing=False):
                    if str(arguments[0]) == "/usr/bin/codesign" and "--sign" in arguments:
                        active = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
                        self.assertIn(str(keychain), active, "The identity must remain searchable while signing")
                        if fail_signing:
                            raise RuntimeError("Simulated signing failure")
                    return run(arguments)

                def sign(fail=False):
                    with patch.object(builder, "run", side_effect=lambda args: checked_run(args, fail)), \
                            patch("sys.argv", ["build-local.py", "--sign-existing", str(app)]), \
                            redirect_stdout(io.StringIO()):
                        builder.main()

                def assert_search_list_restored():
                    current = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
                    self.assertEqual(current, original_search_list)

                try:
                    sign()
                    assert_search_list_restored()
                    certificate = (builder.SIGNING / "certificate.pem").read_bytes()
                    sign()
                    assert_search_list_restored()
                    self.assertEqual((builder.SIGNING / "certificate.pem").read_bytes(), certificate)
                    with self.assertRaisesRegex(RuntimeError, "Simulated signing failure"):
                        sign(fail=True)
                    assert_search_list_restored()
                    # A failed signing attempt must leave the last published bundle valid.
                    run(["/usr/bin/codesign", "--verify", "--strict", app])
                finally:
                    # Only the disposable test identity is deleted. Always undo any
                    # search-list changes even if an assertion or signing fails.
                    run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_search_list])
                    if keychain.exists():
                        run(["/usr/bin/security", "delete-keychain", keychain])
        finally:
            os.umask(original_umask)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise first-run code in disposable XCTest hosts with host tools and network denied."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import threading
from urllib.request import urlopen
import uuid

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]


def run(arguments, *, env=None, cwd=None, timeout=180, merge_stderr=True):
    """Bound the whole subprocess group, including shell/CLI grandchildren."""
    child = subprocess.Popen(
        [str(item) for item in arguments], cwd=ROOT if cwd is None else cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE,
        text=True, start_new_session=True,
    )
    try:
        output, diagnostics = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise RuntimeError("Fresh-install subprocess exceeded its deadline") from None
    if child.returncode:
        raise RuntimeError("Subprocess failed (%s):\n%s%s" % (child.returncode, output, diagnostics or ""))
    if diagnostics:
        log.info("%s", diagnostics.rstrip())
    return output


def assemble_host(base, identifier, developer, identity):
    bundle = base / "Fresh Install Tests.app"
    executable = bundle / "Contents/MacOS/xctest"
    executable.parent.mkdir(parents=True)
    original = developer / "usr/bin/xctest"
    shutil.copy2(original, executable)
    # Short local aliases avoid exceeding the Apple runner's Mach-O header space.
    (executable.parent / "F").symlink_to(
        developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks")
    (executable.parent / "L").symlink_to(developer / "Platforms/MacOSX.platform/Developer/usr/lib")
    load_commands = run(["xcrun", "otool", "-l", original])
    rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset", load_commands)
    replacements = iter(("@loader_path/F", "@loader_path/L"))
    for old in dict.fromkeys(rpaths):
        if old.startswith("@executable_path/"):
            replacement = next(replacements, None)
            if replacement:
                run(["xcrun", "install_name_tool", "-rpath", old, replacement, executable])
            else:
                run(["xcrun", "install_name_tool", "-delete_rpath", old, executable])
    with (bundle / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "xctest",
                      "CFBundlePackageType": "APPL"}, stream)
    entitlements = base / "host-entitlements.plist"
    with entitlements.open("wb") as stream:
        # XCTest loads the locally built test module, which has a different signer.
        plistlib.dump({"com.apple.security.cs.disable-library-validation": True}, stream)
    run(["codesign", "--force", "--options", "runtime", "--timestamp=none",
         "--entitlements", entitlements, "--sign", identity, bundle])
    return executable


def check(test, *, developer, test_bundle, identity, endpoint):
    identifier = "com.wiltodelta.tlm-fresh-install." + uuid.uuid4().hex
    # Only this synthetic canary is ever read in the real home; the sandbox must refuse it.
    canary = Path.home() / (".tlm-fresh-install-canary-" + uuid.uuid4().hex)
    canary.write_text("synthetic isolation sentinel\n")
    try:
        with tempfile.TemporaryDirectory(prefix="tlm-fresh-install-") as temporary:
            base = Path(temporary).resolve()
            home = base / "home"
            (home / "Library/Preferences").mkdir(parents=True)
            (base / "tmp").mkdir()
            executable = assemble_host(base, identifier, developer, identity)
            profile = base / "isolation.sb"
            # The sole host-home exception is the compiled code and its dependencies.
            profile.write_text("\n".join([
                "(version 1)", "(allow default)", "(deny network*)",
                '(deny file-read* file-write* (subpath %s))' % json.dumps(str(Path.home())),
                '(deny file-read* process-exec (subpath "/opt/homebrew") (subpath "/usr/local"))',
                '(allow file-read* (subpath %s))' % json.dumps(str((ROOT / ".build").resolve())),
                '(allow file-read* file-write* (subpath %s))' % json.dumps(str(base)),
            ]))
            # Do not inherit tokens, harness wrappers, login-shell config or CLI homes.
            environment = {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                "TMPDIR": str(base / "tmp") + "/",
                "CLAUDE_CONFIG_DIR": str(home / ".claude"),
                "CODEX_HOME": str(home / ".codex"), "GROK_HOME": str(home / ".grok"),
                "TLM_FRESH_INSTALL_HOME": str(home), "TLM_FRESH_INSTALL_CANARY": str(canary),
                "TLM_FRESH_INSTALL_ENDPOINT": endpoint,
            }
            output = run([
                "/usr/bin/sandbox-exec", "-f", profile, executable,
                "-XCTest", "TranslateLikeMeTests.FreshInstallTests/" + test, test_bundle,
            ], env=environment, cwd=base, timeout=90)
            if not re.search(r"Executed 1 test, with 0 failures", output) or " skipped" in output:
                raise RuntimeError("Expected one executed, unskipped test:\n" + output)
            log.info("PASS %s", test)
    finally:
        canary.unlink(missing_ok=True)
        # cfprefsd can write outside CFFIXED_USER_HOME: remove only our unique domain.
        subprocess.run(["/usr/bin/defaults", "delete", identifier],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        preferences = Path.home() / "Library/Preferences" / (identifier + ".plist")
        if preferences.exists():
            if plistlib.loads(preferences.read_bytes()):
                raise RuntimeError("Disposable preferences could not be cleared: " + identifier)
            # defaults delete can retain an empty plist after the host has exited.
            preferences.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Use the already compiled test bundle")
    args = parser.parse_args()
    developer = Path(run(["xcode-select", "-p"]).strip())
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"])
    match = re.search(r'"(Developer ID Application:[^"]+\(K2GT9Q4S6U\))"', identities)
    if not match:
        raise RuntimeError("The isolated XCTest host needs the team Developer ID Application identity")
    if not args.skip_build:
        run(["swift", "build", "--build-tests"], timeout=300)
    bin_directory = Path(run(["swift", "build", "--show-bin-path"], merge_stderr=False).strip())
    test_bundle = bin_directory / "TranslateLikeMeTests.xctest"
    if not test_bundle.is_dir():
        raise RuntimeError("Test bundle is absent; rerun without --skip-build")
    prefix = "TranslateLikeMeTests.FreshInstallTests/"
    tests = [item.removeprefix(prefix) for item in run(
        ["swift", "test", "list", "--skip-build"], merge_stderr=False).splitlines()
             if item.startswith(prefix)]
    if not tests:
        raise RuntimeError("No fresh-install tests were discovered")
    with ThreadingHTTPServer(("127.0.0.1", 0), CanaryHandler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        endpoint = "http://127.0.0.1:%s/" % server.server_port
        try:
            with urlopen(endpoint, timeout=3) as response:
                if response.read() != b"synthetic network sentinel":
                    raise RuntimeError("The parent network fixture is not reachable")
            for test in tests:
                check(test, developer=developer, test_bundle=test_bundle, identity=match.group(1), endpoint=endpoint)
        finally:
            server.shutdown()
            thread.join()
    log.info("All %s isolated first-run scenarios passed", len(tests))


class CanaryHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"synthetic network sentinel")

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    main()

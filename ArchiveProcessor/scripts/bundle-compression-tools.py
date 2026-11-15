#!/usr/bin/env python3
"""Release build phase: ship VisionOCRKit's compression tools, signed inside out.

Requires jbig2enc and qpdf on the build Mac. Nothing is downloaded. Debug builds
keep using locally installed tools; a Release build fails rather than silently
shipping without compression. Xcode signs the enclosing app after this phase.
"""
import os
from pathlib import Path
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def bundle():
    if os.environ.get("CONFIGURATION") != "Release":
        return
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or os.environ.get("CODE_SIGN_IDENTITY")
    if os.environ.get("CODE_SIGNING_ALLOWED") == "NO" or not identity:
        raise RuntimeError("Release compression tools require the app's signing identity")
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    resources = app / "Contents/Resources"
    bundler = Path(__file__).resolve().parents[2] / "packages/VisionOCRKit/Tools/bundle-libs.py"
    # Unlike Vision OCR's optional build path, even 'not installed' is fatal here.
    subprocess.run([sys.executable, str(bundler), str(app), "jbig2", "qpdf"], check=True)
    libraries = sorted((resources / "lib").glob("*.dylib"))
    helpers = [resources / name for name in ("jbig2", "qpdf")]
    for binary in libraries + helpers:
        # The kit audits Homebrew/@rpath references. Also refuse any other external
        # dependency or missing relocated neighbour before signing the product.
        for line in run("otool", "-L", str(binary)).splitlines()[1:]:
            dependency = line.strip().split(" (")[0]
            if dependency.startswith(("/usr/lib/", "/System/")):
                continue
            if binary in libraries and dependency == binary.name:  # dylib's own install ID
                continue
            prefix = "@loader_path/"
            if not dependency.startswith(prefix):
                raise RuntimeError(f"external dependency: {binary.name} -> {dependency}")
            target = (binary.parent / dependency[len(prefix):]).resolve()
            if not target.is_relative_to(resources.resolve()) or not target.is_file():
                raise RuntimeError(f"missing bundled dependency: {binary.name} -> {dependency}")
        # The self-signed suite certificate has no Team ID. Helpers are separate
        # processes without hardened runtime, so they can load their signed dylibs.
        # The outer Processor retains hardened runtime and strict library validation.
        print(run("codesign", "--force", "--sign", identity, "--options", "0",
                  "--timestamp=none", str(binary)), end="")
        run("codesign", "--verify", "--strict", str(binary))
    patents = resources / "third-party-licences/jbig2enc-PATENTS"
    if not patents.is_file() or not patents.stat().st_size:
        raise RuntimeError("jbig2enc's PATENTS notice is missing")
    print("Bundled and signed jbig2, qpdf and their libraries (native Homebrew architectures).")


if __name__ == "__main__":
    try:
        bundle()
    except (KeyError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: compression tools: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, file=sys.stderr)
        sys.exit(1)

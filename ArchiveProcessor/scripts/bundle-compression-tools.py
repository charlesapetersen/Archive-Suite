#!/usr/bin/env python3
"""Bundle the Processor PDF helpers before Xcode signs the app.

Release bundles jbig2 and qpdf. A Debug build can copy the portable qpdf prepared
by the off-screen test runner, which uses the same dependency closure.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

BUNDLER = Path(__file__).resolve().parents[2] / "packages/VisionOCRKit/Tools/bundle-libs.py"
DEBUG_QPDF = "catalogue-debug-tools"


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def prepare_debug_qpdf(destination):
    executable = destination / "Contents/Resources/qpdf"
    if executable.is_file() and subprocess.run([executable, "--version"], capture_output=True).returncode == 0:
        return
    if destination.exists():
        raise RuntimeError(f"the cached Debug qpdf could not run: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as scratch:
        candidate = Path(scratch) / "processor-tools.app"
        subprocess.run([sys.executable, str(BUNDLER), str(candidate), "qpdf"], check=True)
        resources = candidate / "Contents/Resources"
        helper = resources / "qpdf"
        for binary in sorted((resources / "lib").glob("*.dylib")) + [helper]:
            run("codesign", "--force", "--sign", "-", "--timestamp=none", str(binary))
            run("codesign", "--verify", "--strict", str(binary))
        print(run(str(helper), "--version").splitlines()[0])
        candidate.rename(destination)


def bundle():
    configuration = os.environ.get("CONFIGURATION")
    if configuration == "Debug":
        source = Path(os.environ["PROJECT_DIR"]) / "Vendor" / DEBUG_QPDF / "Contents/Resources"
        if (source / "qpdf").is_file():
            resources = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"] / "Contents/Resources"
            shutil.copytree(source, resources, dirs_exist_ok=True)
        return
    if configuration != "Release":
        return
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or os.environ.get("CODE_SIGN_IDENTITY")
    if os.environ.get("CODE_SIGNING_ALLOWED") == "NO" or not identity:
        raise RuntimeError("Release compression tools require the app's signing identity")
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    resources = app / "Contents/Resources"
    # Unlike Vision OCR's optional build path, even 'not installed' is fatal here.
    subprocess.run([sys.executable, str(BUNDLER), str(app), "jbig2", "qpdf"], check=True)
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
        if len(sys.argv) == 3 and sys.argv[1] == "--prepare-debug-qpdf":
            prepare_debug_qpdf(Path(sys.argv[2]))
        elif len(sys.argv) == 1:
            bundle()
        else:
            raise RuntimeError("expected --prepare-debug-qpdf <directory> or a build-phase invocation")
    except (KeyError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: compression tools: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, file=sys.stderr)
        sys.exit(1)

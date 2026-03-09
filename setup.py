"""
py2app build configuration for OCR to PDF.

Usage
-----
1.  pip install py2app
2.  python setup.py py2app
3.  bash build_dmg.sh          # wraps the .app in a distributable .dmg

The finished disk image will be at:  dist/OCR_to_PDF.dmg
"""

from setuptools import setup

APP = ["archive_processor.py"]

OPTIONS = {
    # argv_emulation opens a terminal-like stdin on macOS — not needed here.
    "argv_emulation": False,

    # Bundle all site-packages so namespace packages (e.g. google-genai) are found.
    "site_packages": True,

    # Pull in every top-level package the script imports.
    "packages": [
        "anthropic",
        # "google" omitted — namespace package; site_packages=True handles it
        "reportlab",
        "PIL",
        "bs4",
        "tkinterdnd2",
        "httpx",
    ],

    # Explicit module includes (tkinter sub-modules are sometimes missed).
    "includes": [
        "tkinter",
        "tkinter.ttk",
        "tkinter.filedialog",
        "tkinter.messagebox",
    ],

    # macOS Info.plist entries.
    "plist": {
        "CFBundleName":             "Archive Processor",
        "CFBundleDisplayName":      "Archive Processor",
        "CFBundleIdentifier":       "com.user.archiveprocessor",
        "CFBundleVersion":          "1.0.0",
        "CFBundleShortVersionString": "1.0.0",
        "NSHighResolutionCapable":  True,
        # Allow both light and dark mode.
        "NSRequiresAquaSystemAppearance": False,
        # Force UTF-8 mode so the bundled locale ('C'/POSIX → ASCII) doesn't
        # cause UnicodeEncodeErrors when processing non-ASCII characters.
        "LSEnvironment": {"PYTHONUTF8": "1"},
        # TCC usage descriptions (macOS 10.15+): shown in the system permission dialog
        # when the app first accesses these locations.
        "NSDesktopFolderUsageDescription":
            "Archive Processor reads images from your Desktop and saves PDFs there.",
        "NSDocumentsFolderUsageDescription":
            "Archive Processor reads images from your Documents folder and saves PDFs there.",
        "NSDownloadsFolderUsageDescription":
            "Archive Processor reads images from your Downloads folder and saves PDFs there.",
    },
}

setup(
    name="Archive Processor",
    app=APP,
    data_files=[],
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)

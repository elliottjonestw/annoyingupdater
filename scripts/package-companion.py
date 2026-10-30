#!/usr/bin/env python3
"""Assemble browser-specific manifests with shared, dependency-free scripts."""
import pathlib
import shutil
import sys
root = pathlib.Path(__file__).resolve().parent.parent / "BrowserCompanion"
destination = pathlib.Path(sys.argv[1])
for browser in ("chromium", "firefox"):
    target = destination / browser
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / browser / "manifest.json", target / "manifest.json")
    for source in (root / "shared").iterdir():
        if source.is_file():
            shutil.copy2(source, target / source.name)

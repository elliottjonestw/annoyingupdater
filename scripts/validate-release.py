#!/usr/bin/env python3
"""Validate a stable tag against the version stamped into every release artifact."""
import argparse
import base64
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parent.parent
FEED = "https://github.com/elliottjonestw/annoyingupdater/releases/latest/download/appcast.xml"


def validate(version, tag, info):
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version):
        raise ValueError("VERSION must be a stable numeric version, e.g. 1.0 or 1.0.1")
    if tag != "v" + version:
        raise ValueError(f"Tag {tag!r} does not match VERSION (expected v{version})")
    if info.get("SUFeedURL") != FEED:
        raise ValueError("Unexpected self-update feed URL")
    if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
        raise ValueError("The app needs a valid Ed25519 public update-signing key")
    if not all(info.get(key) is True for key in (
        "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate"
    )):
        raise ValueError("Required secure self-update defaults are missing")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag")
    args = parser.parse_args()
    version = (ROOT / "VERSION").read_text().strip()
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    try:
        validate(version, args.tag or f"v{version}", info)
    except (ValueError, TypeError) as error:
        parser.error(str(error))
    print(f"Validated release v{version}")


if __name__ == "__main__":
    main()

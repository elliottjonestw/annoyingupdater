import copy
import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/validate-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())

    def test_valid_two_and_three_component_releases(self):
        for version in ("1.0", "1.0.1", "2.10.0"):
            release.validate(version, "v" + version, self.info)

    def test_tag_mismatch_and_prerelease_rejected(self):
        for version, tag in (("1.0", "v1.1"), ("1.0", "1.0"), ("1.1-beta", "v1.1-beta")):
            with self.assertRaises(ValueError):
                release.validate(version, tag, self.info)

    def test_invalid_key_and_wrong_feed_rejected(self):
        for key, value in (("SUPublicEDKey", ""), ("SUPublicEDKey", "invalid"), ("SUFeedURL", "https://example.com/appcast.xml")):
            info = copy.deepcopy(self.info)
            info[key] = value
            with self.assertRaises(ValueError):
                release.validate("1.0", "v1.0", info)

    def test_missing_signature_requirements_rejected(self):
        for key in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
            info = copy.deepcopy(self.info)
            info[key] = False
            with self.assertRaises(ValueError):
                release.validate("1.0", "v1.0", info)


if __name__ == "__main__":
    unittest.main()

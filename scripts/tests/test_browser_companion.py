import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class BrowserCompanionPackagingTests(unittest.TestCase):
    def test_both_companions_have_complete_minimal_permission_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([sys.executable, str(ROOT / "scripts/package-companion.py"), directory], check=True)
            for browser in ("chromium", "firefox"):
                folder = Path(directory) / browser
                manifest = json.loads((folder / "manifest.json").read_text())
                self.assertEqual(set(manifest["permissions"]), {"management", "nativeMessaging", "storage", "alarms"})
                self.assertNotIn("host_permissions", manifest)
                self.assertNotIn("content_scripts", manifest)
                for name in ("bridge.js", "background.js", "popup.html", "popup.js"):
                    self.assertTrue((folder / name).is_file(), name)
                if browser == "chromium":
                    key = base64.b64decode(manifest["key"])
                    identity = "".join(chr(97 + int(n, 16)) for n in hashlib.sha256(key).hexdigest()[:32])
                    core = (ROOT / "Sources/UpdaterCore/BrowserInventory.swift").read_text()
                    self.assertIn(f'chromiumID = "{identity}"', core)
                    self.assertTrue((folder / manifest["background"]["service_worker"]).is_file())
                else:
                    self.assertEqual(manifest["browser_specific_settings"]["gecko"]["id"], "browser-companion@annoyingupdater.app")
                    for script in manifest["background"]["scripts"]:
                        self.assertTrue((folder / script).is_file())

if __name__ == "__main__":
    unittest.main()

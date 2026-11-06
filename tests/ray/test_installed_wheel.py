"""Check that the Ray image runs the patched wheel and its two patched binaries.

Runs inside a Ray image with `python -m unittest`. RAY_EXPECTED_VERSION is the wheel's local version, such as
2.60.0+p0.4.0; without it (an image that only overlays Python files) every test is skipped.
"""

import base64
import hashlib
import importlib.metadata
import os
import pathlib
import unittest

import ray

EXPECTED_VERSION = os.environ.get("RAY_EXPECTED_VERSION", "")
PATCHED_BINARIES = (
    "ray/core/src/ray/gcs/gcs_server",
    "ray/core/src/ray/raylet/raylet",
)


@unittest.skipUnless(EXPECTED_VERSION, "RAY_EXPECTED_VERSION is not set")
class InstalledWheelTest(unittest.TestCase):
    def test_installed_version_is_the_patched_local_version(self):
        self.assertEqual(importlib.metadata.version("ray"), EXPECTED_VERSION)
        self.assertEqual(ray.__version__, EXPECTED_VERSION)

    def test_binaries_match_the_wheel_record(self):
        record = {
            str(file): file.hash
            for file in importlib.metadata.distribution("ray").files
            if str(file) in PATCHED_BINARIES
        }
        self.assertEqual(sorted(record), sorted(PATCHED_BINARIES))
        site_packages = pathlib.Path(ray.__file__).parent.parent
        for name, recorded in record.items():
            with self.subTest(binary=name):
                digest = hashlib.sha256((site_packages / name).read_bytes()).digest()
                actual = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
                self.assertEqual(recorded.mode, "sha256")
                self.assertEqual(recorded.value, actual)


if __name__ == "__main__":
    unittest.main()

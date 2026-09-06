import plistlib
from pathlib import Path
import tempfile
import unittest

from package_dmg import read_version


class ReleaseVersionTests(unittest.TestCase):
    def test_project_version(self):
        self.assertRegex(read_version(), r"^\d+\.\d+\.\d+$")

    def test_matching_tag(self):
        version = read_version()
        self.assertEqual(read_version(tag=f"v{version}"), version)

    def test_mismatched_tag_is_rejected(self):
        with self.assertRaises(ValueError):
            read_version(tag="v99.99.99")

    def test_missing_prefix_is_rejected(self):
        with self.assertRaises(ValueError):
            read_version(tag=read_version())

    def test_unsafe_version_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            for value in ("../../escape", "1.2", "1.2.0\n", "1.2.0;id"):
                path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": value}))
                with self.subTest(value=value), self.assertRaises(ValueError):
                    read_version(path)


if __name__ == "__main__":
    unittest.main()

"""Standard-library packaging checks; no plugin or network runtime is loaded."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build_package.py"
spec = importlib.util.spec_from_file_location("build_package", SCRIPT)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in package.RUNTIME_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("public fixture: " + name).encode())
        (self.root / "_meta.lua").write_text('return { version = "0.8.84" }', encoding="utf-8")
        self.output = self.root / "dist/mangaweb-0.8.84.zip"

    def test_explicit_inventory_excludes_private_and_development_files(self):
        for name in ("spec/private.lua", "docs/draft.md", "cache/image.jpg", "keys/private.pem", "account.lua"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"must not be packaged")
        package.build_package(self.root, self.output)
        manifest = package.verify_package(self.root, self.output)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.namelist(), ["mangaweb.koplugin/" + name for name in package.RUNTIME_FILES])
            self.assertIsNone(archive.testzip())
        self.assertEqual(len(manifest), len(package.RUNTIME_FILES))
        self.assertEqual(manifest[0]["file"], package.RUNTIME_FILES[0])

    def test_build_is_deterministic(self):
        package.build_package(self.root, self.output)
        before = self.output.read_bytes()
        package.build_package(self.root, self.output)
        self.assertEqual(before, self.output.read_bytes())

    def test_missing_runtime_file_fails_before_output(self):
        (self.root / "mangaweb/graydither_bridge.lua").unlink()
        with self.assertRaises(FileNotFoundError):
            package.build_package(self.root, self.output)
        self.assertFalse(self.output.exists())

    def test_archive_drift_is_rejected(self):
        package.build_package(self.root, self.output)
        (self.root / "main.lua").write_bytes(b"changed after build")
        with self.assertRaises(ValueError):
            package.verify_package(self.root, self.output)
        with zipfile.ZipFile(self.output, "a") as archive:
            archive.writestr("mangaweb.koplugin/keys/private.pem", b"unexpected")
        with self.assertRaises(ValueError):
            package.verify_package(self.root, self.output)


if __name__ == "__main__":
    unittest.main()

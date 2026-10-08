"""Check that package verification cannot silently load working-tree modules."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

from lupa.lua51 import LuaError


SCRIPT = Path(__file__).with_name("run_lua_specs.py")
spec = importlib.util.spec_from_file_location("run_lua_specs", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_selected_product_root_supplies_modules(self):
        path = self.root / "mangaweb/probe.lua"
        path.parent.mkdir()
        path.write_text("return 'selected installed product'", encoding="utf-8")
        self.assertEqual(runner.runtime(self.root).eval("require('mangaweb.probe')"), "selected installed product")

    def test_missing_installed_module_cannot_fall_back_to_working_tree(self):
        with self.assertRaises(LuaError):
            runner.runtime(self.root).eval("require('mangaweb.settings')")

    def test_helpers_stay_in_spec_tree(self):
        path = self.root / "mangaweb/ui/koreader.lua"
        path.parent.mkdir(parents=True)
        path.write_text("return {}", encoding="utf-8")
        self.assertEqual(runner.runtime(self.root).eval("type(require('spec.helpers.reader_ui'))"), "function")


if __name__ == "__main__":
    unittest.main()

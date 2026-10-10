"""Run the plugin's Lua 5.1 specs with the optional desktop Lupa runtime."""

from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import re

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def configure_source(lua: LuaRuntime, plugin_root: Path) -> LuaRuntime:
    lua.execute("""
        local root, helper = ...
        package.path = root..'/?.lua;'..root..'/?/init.lua;'..package.path
        package.preload['spec.helpers.reader_ui'] = function()
            return assert(loadfile(helper))()
        end
        -- Keep explicit test preloads, then force product modules to the
        -- selected installed tree. A missing file cannot fall back to cwd.
        table.insert(package.loaders, 2, function(name)
            if name:match('^mangaweb%.') then
                return assert(loadfile(root..'/'..name:gsub('%.','/')..'.lua'))
            end
        end)
    """, plugin_root.resolve().as_posix(), (ROOT / "spec/helpers/reader_ui.lua").as_posix())
    return lua


def runtime(plugin_root: Path = ROOT) -> LuaRuntime:
    return configure_source(LuaRuntime(unpack_returned_tuples=True), plugin_root)


def shared_runtime(gray_root: Path, plugin_root: Path = ROOT, gray_plugin_root: Path | None = None) -> LuaRuntime:
    gray_root = gray_root.resolve()
    runner_path = gray_root / "scripts/run_tests.py"
    if not runner_path.is_file():
        raise SystemExit("Missing GrayDither test runtime: " + str(runner_path))
    fixtures = gray_root / "tests/fixtures"
    for item in json.loads((fixtures / "provenance.json").read_text(encoding="utf-8")):
        path = gray_root / item["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise SystemExit("GrayDither fixture hash mismatch: " + str(path))
    spec = importlib.util.spec_from_file_location("graydither_test_runtime", runner_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    lua = module.runtime(plugin_root=gray_plugin_root or gray_root / "graydither.koplugin")
    return configure_source(lua, plugin_root)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("specs", nargs="*", type=Path)
    parser.add_argument("--graydither-root", type=Path, default=os.environ.get("GRAYDITHER_ROOT"))
    parser.add_argument("--graydither-plugin-root", type=Path,
                        help="Use an unpacked GrayDither release with the hash-pinned test fixtures.")
    parser.add_argument("--plugin-root", type=Path, default=ROOT,
                        help="Read product modules and syntax from an unpacked plugin; specs stay here.")
    args = parser.parse_args()
    plugin_root = args.plugin_root.resolve()
    if not (plugin_root / "main.lua").is_file() or not (plugin_root / "_meta.lua").is_file():
        raise SystemExit("Missing MangaWeb plugin main.lua or _meta.lua: " + str(plugin_root))
    metadata = (plugin_root / "_meta.lua").read_text(encoding="utf-8")
    version = re.search(r'version\s*=\s*"([^\"]+)"', metadata)
    if version is None:
        raise SystemExit("Missing MangaWeb version in selected plugin _meta.lua")
    print("Product: MangaWeb " + version[1] + " from " + str(plugin_root))
    paths = args.specs
    if not paths:
        paths = sorted((ROOT / "spec").glob("*_spec.lua"))
        if args.graydither_root is None:
            paths = [path for path in paths if path.name != "graydither_contract_spec.lua"]
            print("Optional shared-core contract: pass --graydither-root to run it.")
    for path in paths:
        path = path if path.is_absolute() else ROOT / path
        if path.name == "graydither_contract_spec.lua":
            if args.graydither_root is None:
                raise SystemExit("graydither_contract_spec.lua requires --graydither-root or GRAYDITHER_ROOT.")
            lua = shared_runtime(args.graydither_root, plugin_root, args.graydither_plugin_root)
        else:
            lua = runtime(plugin_root)
        lua.execute(path.read_text(encoding="utf-8"), name=f"@{path.as_posix()}")
        print(f"PASS {path.name}")
    # Only product Lua participates in the syntax gate. Scratch readbacks and
    # spec fixtures can contain other versions and must not inflate this count.
    syntax = sorted([plugin_root / "main.lua", plugin_root / "_meta.lua"]
                    + list((plugin_root / "mangaweb").rglob("*.lua")))
    for path in syntax:
        runtime(plugin_root).execute(f"assert(loadfile({str(path.as_posix())!r}))")
    print(f"Lua syntax: {len(syntax)} files passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

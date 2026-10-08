"""Run the plugin's Lua 5.1 specs with the optional desktop Lupa runtime."""

from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import sys

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def runtime() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    module_root = ROOT.as_posix()
    lua.execute(
        "package.path = %r .. package.path"
        % (f"{module_root}/?.lua;{module_root}/?/init.lua;")
    )
    return lua


def shared_runtime(gray_root: Path) -> LuaRuntime:
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
    lua = module.runtime(plugin_root=gray_root / "graydither.koplugin")
    lua.execute("package.path = ... .. package.path", f"{ROOT.as_posix()}/?.lua;")
    return lua


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("specs", nargs="*", type=Path)
    parser.add_argument("--graydither-root", type=Path, default=os.environ.get("GRAYDITHER_ROOT"))
    args = parser.parse_args()
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
            lua = shared_runtime(args.graydither_root)
        else:
            lua = runtime()
        lua.execute(path.read_text(encoding="utf-8"), name=f"@{path.as_posix()}")
        print(f"PASS {path.name}")
    syntax = sorted(ROOT.rglob("*.lua"))
    for path in syntax:
        runtime().execute(f"assert(loadfile({str(path.as_posix())!r}))")
    print(f"Lua syntax: {len(syntax)} files passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

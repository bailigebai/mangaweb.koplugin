"""Build a checked, deterministic public runtime ZIP using only the stdlib."""

import hashlib
import json
from pathlib import Path
import re
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
# Reviewed public 0.8.83 runtime inventory plus the optional integration bridge.
# Keep this explicit: recursive collection could include user settings or keys.
RUNTIME_FILES = (
    "INSTALL.md",
    "NOTICE",
    "README.md",
    "_meta.lua",
    "main.lua",
    "mangaweb/app.lua",
    "mangaweb/async.lua",
    "mangaweb/auth.lua",
    "mangaweb/catalogue_cache.lua",
    "mangaweb/cover_loader.lua",
    "mangaweb/cover_prefetch.lua",
    "mangaweb/cover_thumbnail.lua",
    "mangaweb/detail_cache.lua",
    "mangaweb/dialog_keyboard.lua",
    "mangaweb/file_sink.lua",
    "mangaweb/file_transport.lua",
    "mangaweb/filter_presets.lua",
    "mangaweb/gray_enhance.lua",
    "mangaweb/graydither_bridge.lua",
    "mangaweb/http.lua",
    "mangaweb/image_dimensions.lua",
    "mangaweb/image_identity.lua",
    "mangaweb/image_loader.lua",
    "mangaweb/license.lua",
    "mangaweb/license_crypto.lua",
    "mangaweb/license_device.lua",
    "mangaweb/license_dialog.lua",
    "mangaweb/license_json.lua",
    "mangaweb/license_protocol.lua",
    "mangaweb/license_store.lua",
    "mangaweb/license_transport.lua",
    "mangaweb/models.lua",
    "mangaweb/page_cache.lua",
    "mangaweb/page_processor.lua",
    "mangaweb/page_sequence.lua",
    "mangaweb/panel_analysis.lua",
    "mangaweb/panel_arrays.lua",
    "mangaweb/panel_components.lua",
    "mangaweb/panel_detector.lua",
    "mangaweb/panel_geometry.lua",
    "mangaweb/panel_rendering.lua",
    "mangaweb/panel_session.lua",
    "mangaweb/panel_settings.lua",
    "mangaweb/panel_source.lua",
    "mangaweb/panel_view.lua",
    "mangaweb/reader.lua",
    "mangaweb/reader_panels.lua",
    "mangaweb/remote_chapter_index.lua",
    # Existing public signature verification resource; never a private key.
    "mangaweb/resources/mangaweb_license_public_key.pem",
    "mangaweb/settings.lua",
    "mangaweb/site_definitions.lua",
    "mangaweb/site_manager.lua",
    "mangaweb/source_registry.lua",
    "mangaweb/sources/base.lua",
    "mangaweb/sources/custom.lua",
    "mangaweb/sources/zero.lua",
    "mangaweb/sources/zero_favorites.lua",
    "mangaweb/store.lua",
    "mangaweb/temp_files.lua",
    "mangaweb/tone_adjust.lua",
    "mangaweb/transport.lua",
    "mangaweb/turbo_client.lua",
    "mangaweb/ui/browse.lua",
    "mangaweb/ui/button_style.lua",
    "mangaweb/ui/category_shelf.lua",
    "mangaweb/ui/cover_grid.lua",
    "mangaweb/ui/detail.lua",
    "mangaweb/ui/filter_preview.lua",
    "mangaweb/ui/history.lua",
    "mangaweb/ui/koreader.lua",
    "mangaweb/ui/library.lua",
    "mangaweb/ui/native_detail.lua",
    "mangaweb/ui/native_grid.lua",
    "mangaweb/ui/native_panel.lua",
    "mangaweb/ui/native_root.lua",
    "mangaweb/ui/reader_filters.lua",
    "mangaweb/ui/reader_panels.lua",
    "mangaweb/ui/reader_refresh.lua",
    "mangaweb/ui/settings.lua",
    "mangaweb/ui/shell.lua",
    "mangaweb/ui/site_center.lua",
    "mangaweb/ui/site_rule_editor.lua",
    "mangaweb/ui/source_picker.lua",
    "mangaweb/ui/webdav_reader_shell.lua",
)
ZIP_PREFIX = "mangaweb.koplugin/"
ZIP_TIME = (2026, 10, 8, 0, 0, 0)


def _read_runtime(root: Path) -> dict[str, bytes]:
    root = root.resolve()
    files = {}
    for name in RUNTIME_FILES:
        path = root / name
        if not path.resolve().is_relative_to(root):
            raise ValueError("Runtime path escapes source root: " + name)
        if any(part.is_symlink() for part in (path, *path.parents) if part != root and part.is_relative_to(root)):
            raise ValueError("Runtime symlink is not permitted: " + name)
        files[name] = path.read_bytes()
    return files


def build_package(root: Path, output: Path) -> None:
    root = root.resolve()
    output = output.resolve()
    if output.parent != root / "dist" or output.suffix != ".zip":
        raise ValueError("Package output must be a ZIP directly inside source dist/")
    files = _read_runtime(root)
    output.parent.mkdir(exist_ok=True)
    temporary = output.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in files.items():
            info = zipfile.ZipInfo(ZIP_PREFIX + name, date_time=ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data, compresslevel=9)
    temporary.replace(output)


def verify_package(root: Path, output: Path) -> list[dict]:
    files = _read_runtime(root)
    manifest = []
    with zipfile.ZipFile(output) as archive:
        expected = [ZIP_PREFIX + name for name in RUNTIME_FILES]
        if archive.namelist() != expected or archive.testzip() is not None:
            raise ValueError("ZIP inventory or integrity mismatch")
        for name, data in files.items():
            entry = archive.getinfo(ZIP_PREFIX + name)
            if archive.read(entry) != data or entry.CRC != zlib.crc32(data):
                raise ValueError("ZIP content differs from source: " + name)
            manifest.append({"file": name, "bytes": len(data), "crc32": f"{entry.CRC:08x}",
                             "sha256": hashlib.sha256(data).hexdigest()})
    return manifest


def main() -> None:
    metadata = (ROOT / "_meta.lua").read_text(encoding="utf-8")
    match = re.search(r'version\s*=\s*"(\d+\.\d+\.\d+)"', metadata)
    if match is None:
        raise SystemExit("Cannot read plugin version from _meta.lua")
    output = ROOT / f"dist/mangaweb-{match[1]}.zip"
    build_package(ROOT, output)
    manifest = verify_package(ROOT, output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".zip.sha256").write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    output.with_suffix(".manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Verified {len(manifest)} public files: {output.name}")
    print("SHA-256: " + digest)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build and package the Windows portable release for Clankpad.

Creates a clean staged directory under dist/ and zips only the files required
for Flutter's Windows desktop runtime bundle.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PUBSPEC = ROOT / "pubspec.yaml"
RELEASE_DIR = ROOT / "build" / "windows" / "x64" / "runner" / "Release"
DIST_DIR = ROOT / "dist"


def read_pubspec_field(field: str) -> str:
    text = PUBSPEC.read_text(encoding="utf-8")
    match = re.search(
        rf"^{re.escape(field)}:\s*['\"]?([^'\"\r\n]+)['\"]?\s*$", text, re.MULTILINE
    )
    if not match:
        raise RuntimeError(f"Could not find '{field}:' in {PUBSPEC}")
    return match.group(1).strip()


def run_flutter(*args: str) -> None:
    flutter = shutil.which("flutter") or shutil.which("flutter.bat")
    if not flutter:
        raise RuntimeError("Flutter was not found on PATH")

    print(f"\n$ flutter {' '.join(args)}", flush=True)
    if os.name == "nt":
        cmd = ["cmd", "/c", "flutter", *args]
    else:
        cmd = [flutter, *args]
    subprocess.run(cmd, cwd=ROOT, check=True)


def assert_windows_release_exe_not_running() -> None:
    """Fail early if the old release exe is running and likely locking the build."""
    if os.name != "nt":
        return

    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        return

    command = (
        "Get-CimInstance Win32_Process -Filter \"Name='clankpad.exe'\" "
        "| Select-Object ProcessId,ExecutablePath "
        "| ConvertTo-Json -Compress"
    )
    result = subprocess.run(
        [powershell, "-NoProfile", "-Command", command],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout.strip()
    if not output:
        return

    try:
        processes = json.loads(output)
    except json.JSONDecodeError:
        return
    if isinstance(processes, dict):
        processes = [processes]

    release_exe = (RELEASE_DIR / "clankpad.exe").resolve()
    blockers: list[str] = []
    for process in processes:
        exe_path = process.get("ExecutablePath")
        pid = process.get("ProcessId")
        if not exe_path:
            continue
        try:
            if Path(exe_path).resolve() == release_exe:
                blockers.append(f"PID {pid}: {exe_path}")
        except OSError:
            continue

    if blockers:
        raise RuntimeError(
            "clankpad.exe is currently running from the release output and will lock the build. "
            "Close it first, then rerun this script.\n" + "\n".join(blockers)
        )


def copy_required_bundle_files(stage_dir: Path) -> None:
    required_files = [
        "clankpad.exe",
        "flutter_windows.dll",
        "file_selector_windows_plugin.dll",
    ]
    required_dirs = ["data"]

    missing = [
        name
        for name in required_files + required_dirs
        if not (RELEASE_DIR / name).exists()
    ]
    if missing:
        raise RuntimeError(
            "Release build is missing required bundle entries: " + ", ".join(missing)
        )

    for name in required_files:
        shutil.copy2(RELEASE_DIR / name, stage_dir / name)

    for name in required_dirs:
        shutil.copytree(RELEASE_DIR / name, stage_dir / name)


def write_release_readme(stage_dir: Path, app_name: str, version: str) -> None:
    (stage_dir / "README.txt").write_text(
        f"""{app_name} {version} - Windows x64 portable release

How to run:
1. Extract this zip to a folder.
2. Run clankpad.exe.

Optional AI features:
- Pi provider: install Node.js, then run:
  npm install -g @earendil-works/pi-coding-agent
  pi /login
- Claude Code provider: install Claude Code so 'claude' is available on PATH.

Notes:
- This portable build does not require an installer.
- The executable is unsigned, so Windows SmartScreen may show a warning.
""",
        encoding="utf-8",
    )


def zip_directory(source_dir: Path, zip_path: Path) -> None:
    if zip_path.exists():
        zip_path.unlink()

    with zipfile.ZipFile(
        zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as zf:
        for path in sorted(source_dir.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(source_dir.parent).as_posix())


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build and zip the Clankpad Windows release."
    )
    parser.add_argument(
        "--no-clean",
        action="store_true",
        help="Skip 'flutter clean' before building. Not recommended for release packaging.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Package the existing build output without running Flutter. Intended for debugging only.",
    )
    args = parser.parse_args()

    app_name = read_pubspec_field("name")
    full_version = read_pubspec_field("version")
    release_version = full_version.split("+", 1)[0]
    package_name = f"{app_name}-{release_version}-windows-x64"
    stage_dir = DIST_DIR / package_name
    zip_path = DIST_DIR / f"{package_name}.zip"

    try:
        if not args.skip_build:
            assert_windows_release_exe_not_running()
            if not args.no_clean:
                run_flutter("clean")
            run_flutter("pub", "get")
            run_flutter("build", "windows", "--release")

        DIST_DIR.mkdir(exist_ok=True)
        if stage_dir.exists():
            shutil.rmtree(stage_dir)
        stage_dir.mkdir(parents=True)

        copy_required_bundle_files(stage_dir)
        write_release_readme(stage_dir, app_name, release_version)
        zip_directory(stage_dir, zip_path)

        print("\nDONE")
        print(f"Staged release: {stage_dir.relative_to(ROOT)}")
        print(f"Zip package:    {zip_path.relative_to(ROOT)}")
        print(f"Zip size:       {zip_path.stat().st_size / (1024 * 1024):.1f} MB")
        return 0
    except Exception as exc:  # noqa: BLE001 - top-level CLI error reporting
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Clean Docker containers and data folders for DVLS Docker setup."""

import os
import shutil
import stat
import subprocess
from pathlib import Path


def _force_remove(path: Path) -> None:
    """Remove a directory tree, clearing read-only flags on Windows if needed."""
    def _on_exc(func, fpath, exc):
        # Clear read-only bit and retry (common with SQL Server .mdf/.ldf files)
        os.chmod(fpath, stat.S_IWRITE)
        func(fpath)

    shutil.rmtree(path, onexc=_on_exc)


def run(script_dir: Path) -> None:
    print("🧹 Cleaning Docker containers and data folders...")

    print("\n🐳 Stopping and removing Docker containers...")
    result = subprocess.run(["docker", "compose", "down", "-v"], cwd=script_dir)
    if result.returncode == 0:
        print("   ✅ Docker containers stopped and removed")
    else:
        print(f"   ⚠️  Docker compose down completed with warnings (exit code: {result.returncode})")

    print("\n🧹 Cleaning data folders...")
    for folder in ("data-sql", "data-dvls"):
        p = script_dir / folder
        if p.exists():
            _force_remove(p)
            print(f"   ✅ Removed {folder}/")

    for folder in ("data-sql", "data-dvls"):
        p = script_dir / folder
        p.mkdir(parents=True, exist_ok=True)
        (p / ".gitkeep").touch()
    print("   ✅ Recreated data folders with .gitkeep files")

    print("\n✅ Data folders cleaned successfully")


if __name__ == "__main__":
    run(Path(__file__).parent.resolve())

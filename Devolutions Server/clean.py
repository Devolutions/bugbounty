#!/usr/bin/env python3
"""Clean Docker containers and data folders for DVLS Docker setup."""

import shutil
import subprocess
import sys
from pathlib import Path


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
            shutil.rmtree(p)
            print(f"   ✅ Removed {folder}/")

    for folder in ("data-sql", "data-dvls"):
        p = script_dir / folder
        p.mkdir(parents=True, exist_ok=True)
        (p / ".gitkeep").touch()
    print("   ✅ Recreated data folders with .gitkeep files")

    print("\n✅ Data folders cleaned successfully")


if __name__ == "__main__":
    run(Path(__file__).parent.resolve())
